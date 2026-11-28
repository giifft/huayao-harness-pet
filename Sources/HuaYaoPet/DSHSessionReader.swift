import Foundation

/// Reads persisted DSH events without treating the presence of a log as a running process.
final class DSHSessionReader {
    private struct FileSnapshot: Equatable {
        let url: URL
        let modified: Date
        let size: UInt64
        let inode: UInt64

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? UInt64,
                  let inode = attributes[.systemFileNumber] as? UInt64 else { return nil }
            self.url = url
            self.modified = modified
            self.size = size
            self.inode = inode
        }
    }

    private struct Event {
        let sequence: Int
        let time: Date
        let type: String
        let data: [String: Any]

        init?(_ object: [String: Any]) {
            guard let sequence = object["seq"] as? Int,
                  let time = object["time"] as? Double,
                  let type = object["type"] as? String else { return nil }
            self.sequence = sequence
            self.time = Date(timeIntervalSince1970: time / 1000)
            self.type = type
            data = object["data"] as? [String: Any] ?? [:]
        }

        func matches(_ other: (sequence: Int, time: Date, type: String)) -> Bool {
            sequence == other.sequence && time == other.time && type == other.type
        }
    }

    private let root: URL
    private let pricing: HarnessPricing?
    private var currentFile: FileSnapshot?
    private var delegatedFiles: Set<URL> = []
    private var lastEvent: (sequence: Int, time: Date, type: String)?
    private var status = AgentStatus()
    private var toolCalls: [(id: String, detail: String, isQuestion: Bool)] = []
    private var approvals: Set<String> = []
    private var usageFiles: [URL: (snapshot: FileSnapshot, rounds: [HarnessUsageRound])] = [:]
    private var usageRetry: [URL: (snapshot: FileSnapshot, after: Date)] = [:]
    private var usageSummary: HarnessUsageSummary?

    init(root: URL, pricing: HarnessPricing? = HarnessPricing.bundled) {
        self.root = root
        self.pricing = pricing
    }

    func refresh(now: Date = Date()) -> AgentStatus {
        let fm = FileManager.default
        let files = directories(in: root).flatMap { workspace in
            [workspace] + directories(in: workspace)
        }.compactMap { session in
            FileSnapshot(session.appendingPathComponent("session.v4.jsonl.zstd"))
                ?? FileSnapshot(session.appendingPathComponent("session.v3.jsonl.zstd"))
        }.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.path < $1.url.path
        }
        delegatedFiles.formIntersection(files.map(\.url))
        refreshUsage(files: files, now: now)

        for file in files where !delegatedFiles.contains(file.url) {
            if currentFile == file { return displayStatus(at: now) }
            guard let decoded = Self.decompress(file.url),
                  FileSnapshot(file.url) == file else {
                // Keep the last good state while the writer is replacing this file. Retry next poll.
                if let previous = currentFile, fm.fileExists(atPath: previous.url.path) {
                    return displayStatus(at: now)
                }
                return offline("会话暂时无法读取")
            }
            let maxRecords = 50_000
            let lines = decoded.split(separator: 0x0A, maxSplits: maxRecords)
            guard lines.count <= maxRecords, let first = lines.first,
                  let header = Self.record(first), header["type"] as? String == "session" else {
                return currentFile == nil ? offline("无法识别会话格式") : displayStatus(at: now)
            }
            if (header["delegationDepth"] as? Int ?? 0) > 0 || header["parentSession"] != nil && !(header["parentSession"] is NSNull) {
                delegatedFiles.insert(file.url)
                continue
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var cursor: Int?
            if currentFile?.url == file.url, let marker = lastEvent {
                for index in lines.indices.dropFirst().reversed() {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return displayStatus(at: now) }
                    if autoreleasepool(invoking: { Self.event(lines[index])?.matches(marker) == true }) {
                        cursor = index
                        break
                    }
                }
            }

            let previousState = status
            let previousTools = toolCalls
            let previousApprovals = approvals
            let replay = currentFile?.url != file.url || (lastEvent != nil && cursor == nil)
            if replay {
                reset()
                status.state = .idle
            }
            status.sessionID = header["id"] as? String ?? file.url.deletingLastPathComponent().lastPathComponent
            if let cwd = header["cwd"] as? String {
                status.projectName = URL(fileURLWithPath: cwd).lastPathComponent
            }
            var newest = replay ? nil : lastEvent
            for line in lines.dropFirst((cursor ?? 0) + 1) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    status = previousState
                    toolCalls = previousTools
                    approvals = previousApprovals
                    return currentFile == nil ? offline("会话读取超时") : displayStatus(at: now)
                }
                autoreleasepool {
                    guard let event = Self.event(line) else { return }
                    reduce(event)
                    newest = (event.sequence, event.time, event.type)
                }
            }
            // Historical completion and error states should not replay at startup or on session switch.
            if replay, !status.state.isBusy { status.state = .idle }
            currentFile = file
            lastEvent = newest
            return displayStatus(at: now)
        }
        reset()
        currentFile = nil
        lastEvent = nil
        return offline("暂无会话")
    }

    private static func record(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func event(_ line: Data) -> Event? {
        record(line).flatMap(Event.init)
    }

    private func refreshUsage(files: [FileSnapshot], now: Date) {
        // Cap per-poll work so a large archive does not stall the task monitor on startup.
        let candidates = files.prefix(512)
        let paths = Set(candidates.map(\.url))
        usageFiles = usageFiles.filter { paths.contains($0.key) }
        usageRetry = usageRetry.filter { paths.contains($0.key) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        var budget = 4
        for file in candidates where usageFiles[file.url]?.snapshot != file {
            guard budget > 0, ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let retry = usageRetry[file.url], retry.snapshot == file, retry.after > now { continue }
            budget -= 1
            if let rounds = usageRounds(in: file) {
                usageFiles[file.url] = (file, rounds)
                usageRetry[file.url] = nil
            } else {
                usageRetry[file.url] = (file, now.addingTimeInterval(30))
            }
        }
        let pending = candidates.count < files.count || candidates.contains { usageFiles[$0.url]?.snapshot != $0 }
        // Newest copies win if the same session appears in more than one workspace.
        let rounds = candidates.flatMap { usageFiles[$0.url]?.rounds ?? [] }
        usageSummary = .make(rounds: rounds, now: now, pricing: pricing, pending: pending)
    }

    private func usageRounds(in file: FileSnapshot) -> [HarnessUsageRound]? {
        guard let decoded = Self.decompress(file.url), FileSnapshot(file.url) == file else { return nil }
        let lines = decoded.split(separator: 0x0A, maxSplits: 50_000)
        guard lines.count <= 50_000, let first = lines.first,
              let header = Self.record(first), header["type"] as? String == "session" else { return nil }
        let id = header["id"] as? String ?? file.url.deletingLastPathComponent().path
        var fold = HarnessUsageFold(sessionID: id, pricing: pricing)
        for line in lines.dropFirst() {
            let valid = autoreleasepool {
                guard let object = Self.record(line) else { return false }
                guard let event = Event(object) else { return true }
                fold.accept(type: event.type, data: event.data, sequence: event.sequence, time: event.time)
                return true
            }
            guard valid else { return nil }
        }
        return fold.rounds
    }

    private func directories(in url: URL) -> [URL] {
        let entries = try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        return (entries ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private func reset() {
        status = AgentStatus()
        toolCalls.removeAll()
        approvals.removeAll()
    }

    private func offline(_ message: String) -> AgentStatus {
        AgentStatus(connectionMessage: message, harnessUsage: usageSummary)
    }

    private func displayStatus(at now: Date) -> AgentStatus {
        var snapshot = status.expiring(at: now)
        snapshot.harnessUsage = usageSummary
        if snapshot.state != .waiting { snapshot.waitKind = nil }
        return snapshot
    }

    private func reduce(_ event: Event) {
        let data = event.data
        switch event.type {
        case "session/title":
            if let title = data["title"] as? String { status.sessionTitle = title }
            return
        case "model/selection", "request/context":
            if let model = data["model"] as? String { status.modelName = model }
            return
        case "turn/start":
            toolCalls.removeAll()
            approvals.removeAll()
            updateActiveState()
        case "step/start", "assistant/attempt":
            updateActiveState()
        case "assistant/message":
            let message = data["message"] as? [String: Any]
            let source = message?["source"] as? [String: Any]
            if let model = source?["model"] as? String { status.modelName = model }
            updateActiveState()
        case "tool/call":
            let name = data["name"] as? String ?? ""
            let id = data["callId"] as? String ?? String(event.sequence)
            let detail = Self.describeTool(name)
            toolCalls.removeAll { $0.id == id }
            toolCalls.append((id, detail, name.lowercased() == "ask_user_question"))
            updateActiveState()
        case "tool/result":
            let message = data["message"] as? [String: Any]
            if let id = message?["toolCallId"] as? String {
                toolCalls.removeAll { $0.id == id }
            } else if !toolCalls.isEmpty {
                toolCalls.removeFirst()
            }
            updateActiveState()
        case "approval/asked":
            approvals.insert(data["id"] as? String ?? "")
            updateActiveState()
        case "approval/decided":
            approvals.remove(data["id"] as? String ?? "")
            updateActiveState()
        case "turn/end":
            let reason = data["reason"] as? [String: Any]
            switch reason?["kind"] as? String {
            case "error": status.state = .error
            case "aborted", "cancelled": status.state = .cancelled
            default: status.state = .done
            }
            toolCalls.removeAll()
            approvals.removeAll()
            status.toolDetail = ""
            status.waitKind = nil
        default:
            return
        }
        status.lastActivity = event.time
    }

    private func updateActiveState() {
        status.toolDetail = toolCalls.last?.detail ?? ""
        status.waitKind = !approvals.isEmpty ? .approval : toolCalls.contains(where: \.isQuestion) ? .question : nil
        if status.waitKind != nil {
            status.state = .waiting
        } else {
            status.state = toolCalls.isEmpty ? .thinking : .working
        }
    }

    private static func decompress(_ url: URL) -> Data? {
        let process = Process()
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dsh-unzstd")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else { return nil }
        process.executableURL = bundled
        process.arguments = [url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let maxBytes = 32 * 1024 * 1024
            var data = Data()
            let handle = output.fileHandleForReading
            do {
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    guard chunk.count <= maxBytes - data.count else {
                        if process.isRunning { process.terminate() }
                        try? handle.close()
                        process.waitUntilExit()
                        return nil
                    }
                    data.append(chunk)
                }
            } catch {
                if process.isRunning { process.terminate() }
                try? handle.close()
                process.waitUntilExit()
                return nil
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private static func describeTool(_ name: String) -> String {
        switch name {
        case "bash", "exec_command":
            return "在敲命令"
        case "read":      return "在翻文件"
        case "write":     return "在写字"
        case "edit":      return "在改稿子"
        case "glob":      return "在找东西"
        case "grep":      return "在翻查字句"
        case "web_search": return "在上网查"
        case "web_fetch": return "在打开网页"
        case "subagent", "subagent_fork", "subagent_codex": return "在叫人帮忙"
        case "workflow":  return "在调度分身"
        case "todo_write": return "在列清单"
        case "ask_user_question": return "在问你话"
        case "create_goal": return "在立目标"
        default:
            return "在调用工具"
        }
    }
}
