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
    private var currentFile: FileSnapshot?
    private var delegatedFiles: Set<URL> = []
    private var lastEvent: (sequence: Int, time: Date, type: String)?
    private var status = AgentStatus()
    private var toolCalls: [(id: String, detail: String)] = []
    private var approvals: Set<String> = []

    init(root: URL) {
        self.root = root
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
            let records = decoded.split(separator: 0x0A).compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
            }
            guard let header = records.first, header["type"] as? String == "session" else {
                return offline("无法识别会话格式")
            }
            if (header["delegationDepth"] as? Int ?? 0) > 0 || header["parentSession"] != nil && !(header["parentSession"] is NSNull) {
                delegatedFiles.insert(file.url)
                continue
            }
            let events = records.dropFirst().compactMap(Event.init)
            let cursor = currentFile?.url == file.url
                ? lastEvent.flatMap { marker in events.lastIndex(where: { $0.matches(marker) }) }
                : nil
            let replay = currentFile?.url != file.url || (lastEvent != nil && cursor == nil)
            if replay {
                reset()
                status.state = .idle
            }
            let firstNew = cursor.map { $0 + 1 } ?? 0
            for event in events.dropFirst(firstNew) { reduce(event) }
            // Historical completion and error states should not replay at startup or on session switch.
            if replay, !status.state.isBusy { status.state = .idle }
            currentFile = file
            lastEvent = events.last.map { ($0.sequence, $0.time, $0.type) }
            return displayStatus(at: now)
        }
        reset()
        currentFile = nil
        lastEvent = nil
        return offline("暂无会话")
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
        AgentStatus(connectionMessage: message)
    }

    private func displayStatus(at now: Date) -> AgentStatus {
        status.expiring(at: now)
    }

    private func reduce(_ event: Event) {
        let data = event.data
        switch event.type {
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
            let detail = Self.describeTool(name, args: data["arguments"] as? String ?? "")
            toolCalls.removeAll { $0.id == id }
            toolCalls.append((id, detail))
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
        default:
            return
        }
        status.lastActivity = event.time
    }

    private func updateActiveState() {
        status.toolDetail = toolCalls.last?.detail ?? ""
        if !approvals.isEmpty {
            status.state = .waiting
        } else {
            status.state = toolCalls.isEmpty ? .thinking : .working
        }
    }

    private static func decompress(_ url: URL) -> Data? {
        let process = Process()
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dsh-unzstd")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            process.executableURL = bundled
            process.arguments = [url.path]
        } else {
            let paths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:))
            process.executableURL = URL(fileURLWithPath: executable ?? "/usr/bin/env")
            process.arguments = (executable == nil ? ["zstd"] : []) + ["-dc", "--", url.path]
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private static func describeTool(_ name: String, args: String) -> String {
        let a = args.lowercased()
        switch name {
        case "bash":
            if a.contains("git ") { return "在翻 git 记录" }
            if a.contains("npm") || a.contains("pnpm") || a.contains("yarn") { return "在装依赖" }
            if a.contains("swiftc") || a.contains("xcodebuild") { return "在编译" }
            if a.contains("python") { return "在跑脚本" }
            if a.contains("curl") || a.contains("http") { return "在联网查资料" }
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
