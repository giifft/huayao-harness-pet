import Foundation
import Darwin

/// Observes the documented Antigravity hook events without opening transcripts.
final class AntigravityBridge {
    enum Hook: String, CaseIterable {
        case start = "SessionStart"
        case invocation = "PreInvocation"
        case beforeTool = "PreToolUse"
        case afterTool = "PostToolUse"
        case stop = "Stop"

        var response: String {
            switch self {
            case .beforeTool: return #"{"decision":"allow"}"#
            case .stop: return #"{"decision":"stop"}"#
            default: return "{}"
            }
        }
    }

    private struct Signal: Codable {
        let state: String
        let time: Date
        let project: String
        let tools: [Int: String]
        let background: Bool
    }

    private let fm = FileManager.default
    private let config: URL
    private let events: URL
    private let group = "huayao-desktop-pet-status"
    private var checkedAt = Date.distantPast
    private var configured = false
    private var hasObserved = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        config = home.appendingPathComponent(".gemini/config/hooks.json")
        events = home.appendingPathComponent("Library/Application Support/HuaYaoPet/Antigravity", isDirectory: true)
    }

    private func readConfig() throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: config)
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return document
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
    }

    private func writeConfig(_ document: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: config, options: .atomic)
    }

    private func owned(_ value: Any?) -> Bool {
        guard let group = value as? [String: Any],
              let handlers = group[Hook.invocation.rawValue] as? [[String: Any]],
              let command = handlers.first?["command"] as? String else { return false }
        return command.hasSuffix(" --antigravity-hook PreInvocation")
    }

    func install(executable: URL) throws {
        var document = try readConfig()
        if document[group] != nil && !owned(document[group]) {
            throw CocoaError(.fileWriteFileExists)
        }
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        var definition: [String: Any] = ["enabled": true]
        for hook in Hook.allCases {
            let handler: [String: Any] = [
                "type": "command", "command": "\(quoted) --antigravity-hook \(hook.rawValue)", "timeout": 3,
            ]
            switch hook {
            case .beforeTool, .afterTool:
                definition[hook.rawValue] = [["matcher": "*", "hooks": [handler]]]
            default:
                definition[hook.rawValue] = [handler]
            }
        }
        document[group] = definition
        try writeConfig(document)
    }

    func uninstall() throws {
        var document = try readConfig()
        guard owned(document[group]) else { return }
        document[group] = nil
        try writeConfig(document)
    }

    func refresh(now: Date = Date()) -> [AgentStatus] {
        if now.timeIntervalSince(checkedAt) >= 5 {
            checkedAt = now
            let definition = (try? readConfig())?[group] as? [String: Any]
            configured = owned(definition) && definition?["enabled"] as? Bool != false
        }
        guard configured else { return [AgentStatus(connectionMessage: "请先配置 Antigravity 联动")] }

        let observed = signalFiles().sorted { $0.time > $1.time }.prefix(64)
        let statuses = observed.compactMap { entry -> AgentStatus? in
            let id = entry.url.deletingPathExtension().lastPathComponent
            guard now.timeIntervalSince(entry.time) <= 1800, UUID(uuidString: id) != nil,
                  let signal = readSignal(entry.url),
                  let state = AgentState(rawValue: signal.state) else { return nil }
            let detail = state == .working
                ? signal.tools.max(by: { $0.key < $1.key })?.value ?? (signal.background ? "后台任务运行中" : "在调用工具")
                : ""
            return AgentStatus(state: state, toolDetail: detail, lastActivity: signal.time,
                               sessionID: id, projectName: signal.project).expiring(at: now)
        }
        hasObserved = hasObserved || !statuses.isEmpty
        if !statuses.isEmpty { return statuses }
        return [hasObserved ? AgentStatus(state: .idle) : AgentStatus(connectionMessage: "已配置，等待 Antigravity 任务")]
    }

    func receive(_ hook: Hook, input: Data, now: Date = Date()) throws {
        guard let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let id = (payload["conversationId"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        try fm.createDirectory(at: events, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let lock = open(events.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(lock, LOCK_UN) }

        let file = events.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
        let previous = readSignal(file)
        if let previous, previous.time > now { return }
        let workspace = (payload["workspacePaths"] as? [String])?.first { $0.hasPrefix("/") }
        let project = workspace.map {
            String(URL(fileURLWithPath: $0).lastPathComponent.prefix(120).split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").prefix(48))
        } ?? previous?.project ?? ""
        var tools = previous?.tools ?? [:]
        var background = previous?.background == true
        let state: AgentState
        let tool = (payload["toolCall"] as? [String: Any])?["name"] as? String
        let step = payload["stepIdx"] as? Int
        switch hook {
        case .start:
            tools.removeAll()
            background = false
            state = .idle
        case .invocation:
            state = tools.isEmpty && !background ? .thinking : .working
        case .beforeTool:
            if let step, tools.count < 64 { tools[step] = Self.toolLabel(tool) }
            state = .working
        case .afterTool:
            if let step { tools[step] = nil }
            if let previous, AgentState(rawValue: previous.state)?.isTerminal == true { return }
            state = tools.isEmpty && !background ? .thinking : .working
        case .stop:
            tools.removeAll()
            background = payload["fullyIdle"] as? Bool == false
            state = background ? .working : Self.stoppedState(payload)
            if previous?.state == state.rawValue, state.isTerminal { return }
        }

        let signal = Signal(state: state.rawValue, time: now, project: project,
                            tools: tools, background: background)
        try JSONEncoder().encode(signal).write(to: file, options: .atomic)
        if previous == nil {
            for old in signalFiles() where now.timeIntervalSince(old.time) > 86400 {
                try? fm.removeItem(at: old.url)
            }
        }
    }

    private func signalFiles() -> [(url: URL, time: Date)] {
        let entries = (try? fm.contentsOfDirectory(at: events,
            includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return entries.compactMap { file in
            guard file.pathExtension == "json",
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let time = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return (file, time)
        }
    }

    private func readSignal(_ url: URL) -> Signal? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 16 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Signal.self, from: data)
    }

    private static func toolLabel(_ name: String?) -> String {
        switch name {
        case "run_command", "command_status": return "在敲命令"
        case "view_file", "view_file_outline", "list_dir": return "在读文件"
        case "write_to_file", "edit_file", "replace_file_content", "multi_replace_file_content":
            return "在修改文件"
        case "search_web", "read_url_content": return "在查资料"
        case "grep_search", "find_by_name": return "在找文件"
        case "browser_subagent": return "在操作浏览器"
        default: return "在调用工具"
        }
    }

    private static func stoppedState(_ payload: [String: Any]) -> AgentState {
        if let error = payload["error"] as? String, !error.isEmpty { return .error }
        switch payload["terminationReason"] as? String {
        case "model_stop": return .done
        case "error", "max_steps_exceeded": return .error
        case "cancelled", "canceled", "aborted", "user_cancelled": return .cancelled
        default: return .idle
        }
    }
}
