import Foundation

final class CodexSessionReader {
    private struct Snapshot: Equatable {
        let modified: Date
        let size: Int
        let inode: Int

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int,
                  let inode = attributes[.systemFileNumber] as? Int else { return nil }
            self.modified = modified
            self.size = size
            self.inode = inode
        }
    }

    private let root: URL
    private var cache: [URL: (Snapshot, AgentStatus)] = [:]
    private var lastScan = Date.distantPast
    private var files: [URL] = []
    private let dates = ISO8601DateFormatter()
    private let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(root: URL) { self.root = root }

    func refresh(now: Date = Date()) -> AgentStatus {
        if now.timeIntervalSince(lastScan) >= 5 {
            lastScan = now
            let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            files = (entries?.allObjects as? [URL] ?? []).filter {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
            }
        }
        let candidates = files.compactMap { url in Snapshot(url).map { (url, $0) } }
            .sorted { $0.1.modified > $1.1.modified }
        guard !candidates.isEmpty else { return AgentStatus(connectionMessage: "暂无 Codex 本地会话") }
        var statuses: [AgentStatus] = []
        let activeWindow: TimeInterval = 15 * 60
        for (url, snapshot) in candidates.prefix(32) {
            if !statuses.isEmpty, now.timeIntervalSince(snapshot.modified) > activeWindow { break }
            if cache[url]?.0 != snapshot, let status = read(url, snapshot: snapshot) {
                cache[url] = (snapshot, status)
            }
            if let status = cache[url]?.1 {
                statuses.append(status.expiring(at: now))
            }
        }
        let retained = Set(candidates.prefix(32).map { $0.0 })
        cache = cache.filter { retained.contains($0.key) }
        return preferredStatus(statuses) ?? AgentStatus(connectionMessage: "会话暂时无法读取")
    }

    private func read(_ url: URL, snapshot: Snapshot) -> AgentStatus? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 1024 * 1024
        let offset = max(0, snapshot.size - limit)
        var status = AgentStatus(state: .idle)
        var toolCalls: Set<String> = []
        do {
            // Check the header before tailing long journals. Delegated sessions have their own logs.
            func isDelegated(_ data: Data) -> Bool {
                guard let line = data.split(separator: 10).first,
                      let item = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      item["type"] as? String == "session_meta",
                      let meta = item["payload"] as? [String: Any],
                      let source = meta["source"] as? [String: Any] else { return false }
                return source["subagent"] != nil || source["sub_agent"] != nil
            }
            if let header = try handle.read(upToCount: min(snapshot.size, 256 * 1024)),
               isDelegated(header) { return status }
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: min(snapshot.size, limit)), !data.isEmpty else {
                return status
            }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            let end = lines.count - 1 // A writer may still be appending the last record.
            for line in lines.prefix(end).dropFirst(offset == 0 ? 0 : 1) {
                guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let kind = record["type"] as? String,
                      let payload = record["payload"] as? [String: Any] else { continue }
                let event = payload["type"] as? String ?? ""
                if kind == "event_msg" {
                    switch event {
                    case "task_started", "turn_started", "user_message":
                        toolCalls.removeAll()
                        status.state = .thinking
                    case "task_complete", "turn_completed":
                        toolCalls.removeAll()
                        status.state = .done
                    case "turn_aborted":
                        toolCalls.removeAll()
                        status.state = .cancelled
                    case "error":
                        if payload["will_retry"] as? Bool == true { continue }
                        toolCalls.removeAll()
                        status.state = .error
                    case "token_count", "item_completed":
                        guard status.state.isBusy else { continue }
                    default: continue
                    }
                } else if kind == "response_item" {
                    switch event {
                    case "function_call", "custom_tool_call", "web_search_call":
                        let id = payload["call_id"] as? String ?? payload["id"] as? String
                        if let id { toolCalls.insert(id) }
                        status.state = .working
                    case "function_call_output", "custom_tool_call_output":
                        if let id = payload["call_id"] as? String { toolCalls.remove(id) }
                        status.state = toolCalls.isEmpty ? .thinking : .working
                    case "reasoning":
                        guard status.state == .idle || status.state.isBusy else { continue }
                        status.state = toolCalls.isEmpty ? .thinking : .working
                    default: continue
                    }
                } else {
                    continue
                }
                if let timestamp = record["timestamp"] as? String,
                   let time = fractionalDates.date(from: timestamp) ?? dates.date(from: timestamp) {
                    status.lastActivity = time
                }
                status.toolDetail = status.state == .working ? "在调用工具" : ""
            }
            return status
        } catch {
            return nil
        }
    }
}
