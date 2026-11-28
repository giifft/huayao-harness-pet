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
    private var titleSnapshot: Snapshot?
    private var titles: [String: String] = [:]
    private let titleIndex: URL
    private let dates = ISO8601DateFormatter()
    private let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(root: URL) {
        self.root = root
        titleIndex = root.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    func refresh(now: Date = Date()) -> AgentStatus {
        preferredStatus(refreshSessions(now: now)) ?? AgentStatus()
    }

    func refreshSessions(now: Date = Date()) -> [AgentStatus] {
        if now.timeIntervalSince(lastScan) >= 5 {
            lastScan = now
            let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            files = (entries?.allObjects as? [URL] ?? []).filter {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
            }
        }
        refreshTitles()
        let candidates = files.compactMap { url in Snapshot(url).map { (url, $0) } }
            .sorted {
                if $0.1.modified != $1.1.modified { return $0.1.modified > $1.1.modified }
                return $0.0.path < $1.0.path
            }
        guard !candidates.isEmpty else { return [AgentStatus(connectionMessage: "暂无 Codex 本地会话")] }
        var statuses: [AgentStatus] = []
        var added: Set<String> = []
        let activeWindow: TimeInterval = 15 * 60
        let inspected = candidates.prefix(64)
        for (url, snapshot) in inspected {
            if statuses.count == 32 || (!statuses.isEmpty && now.timeIntervalSince(snapshot.modified) > activeWindow) { break }
            if cache[url]?.0 != snapshot, let status = read(url, snapshot: snapshot) {
                cache[url] = (snapshot, status)
            }
            if var status = cache[url]?.1, let id = status.sessionID, added.insert(id).inserted {
                status.sessionTitle = titles[id] ?? ""
                statuses.append(status.expiring(at: now))
            }
        }
        let retained = Set(inspected.map { $0.0 })
        cache = cache.filter { retained.contains($0.key) }
        return statuses.isEmpty ? [AgentStatus(connectionMessage: "会话暂时无法读取")] : statuses
    }

    private func refreshTitles() {
        guard let snapshot = Snapshot(titleIndex) else {
            titleSnapshot = nil
            titles.removeAll()
            return
        }
        guard snapshot != titleSnapshot, let handle = try? FileHandle(forReadingFrom: titleIndex) else { return }
        defer { try? handle.close() }
        let limit = 512 * 1024
        let offset = max(0, snapshot.size - limit)
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: min(limit, snapshot.size)) ?? Data()
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            var updated: [String: String] = [:]
            for line in lines.dropLast().dropFirst(offset == 0 ? 0 : 1) {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let id = row["id"] as? String, let title = row["thread_name"] as? String else { continue }
                updated[id] = Self.label(title)
            }
            titles = updated
            titleSnapshot = snapshot
        } catch {
            return
        }
    }

    private static func label(_ value: String) -> String {
        String(value.prefix(120).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(48))
    }

    private static func toolLabel(_ name: String?) -> String {
        switch name {
        case "exec_command", "write_stdin", "shell", "shell_command": return "在敲命令"
        case "apply_patch", "write_file", "edit_file": return "在修改文件"
        case "read_file", "list_dir": return "在读文件"
        case "web_search", "web_fetch": return "在查资料"
        default: return "在调用工具"
        }
    }

    private func read(_ url: URL, snapshot: Snapshot) -> AgentStatus? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 1024 * 1024
        let offset = max(0, snapshot.size - limit)
        var status = AgentStatus(state: .idle)
        var toolCalls: [(id: String, label: String, needsInput: Bool)] = []
        func activeState() -> AgentState {
            if toolCalls.contains(where: { $0.needsInput }) { return .waiting }
            return toolCalls.isEmpty ? .thinking : .working
        }
        do {
            guard let header = try handle.read(upToCount: min(snapshot.size, 256 * 1024)),
                  let line = header.split(separator: 10).first,
                  let item = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  item["type"] as? String == "session_meta",
                  let meta = item["payload"] as? [String: Any] else { return nil }
            if let source = meta["source"] as? [String: Any],
               source["subagent"] != nil || source["sub_agent"] != nil { return status }
            let suffix = String(url.deletingPathExtension().lastPathComponent.suffix(36))
            status.sessionID = meta["id"] as? String ?? meta["session_id"] as? String ?? suffix
            if let cwd = meta["cwd"] as? String, !cwd.isEmpty {
                status.projectName = Self.label(URL(fileURLWithPath: cwd).lastPathComponent)
            }
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
                        let name = event == "web_search_call" ? "web_search" : payload["name"] as? String
                        if let id {
                            toolCalls.removeAll { $0.id == id }
                            toolCalls.append((id, Self.toolLabel(name), name == "request_user_input"))
                            status.state = activeState()
                        } else if status.state != .waiting {
                            status.state = .working
                        }
                    case "function_call_output", "custom_tool_call_output":
                        guard !status.state.isTerminal else { continue }
                        if let id = payload["call_id"] as? String { toolCalls.removeAll { $0.id == id } }
                        status.state = activeState()
                    case "reasoning":
                        guard status.state == .idle || status.state.isBusy else { continue }
                        status.state = activeState()
                    default: continue
                    }
                } else {
                    continue
                }
                if let timestamp = record["timestamp"] as? String,
                   let time = fractionalDates.date(from: timestamp) ?? dates.date(from: timestamp) {
                    status.lastActivity = time
                }
                status.toolDetail = status.state == .working ? toolCalls.last?.label ?? "在调用工具" : ""
                status.waitKind = status.state == .waiting ? .question : nil
            }
            return status
        } catch {
            return nil
        }
    }
}
