import CryptoKit
import Darwin
import Foundation

final class TraeBridge {
    private enum Hook: String, CaseIterable {
        case start = "SessionStart"
        case prompt = "UserPromptSubmit"
        case beforeTool = "PreToolUse"
        case afterTool = "PostToolUse"
        case stop = "Stop"
        case notification = "Notification"
    }

    private struct Signal: Codable {
        let state: String
        let time: Date
        let question: Bool?
    }

    private let bridge: URL
    private let config: URL
    private let fm = FileManager.default
    private var hasReceivedSignal = false
    private var lastConfigCheck = Date.distantPast
    private var configured = false

    private var helper: URL { bridge.appendingPathComponent("huayao-trae-hook") }
    private var enabledMarker: URL { bridge.appendingPathComponent(".trae-enabled") }
    var isEnabled: Bool { fm.fileExists(atPath: enabledMarker.path) }
    private var events: URL { bridge.appendingPathComponent("TRAE", isDirectory: true) }
    private var command: String {
        "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "' --trae-hook"
    }

    init(home: URL, bridgeDirectory: URL? = nil) {
        bridge = bridgeDirectory ?? home.appendingPathComponent("Library/Application Support/HuaYaoPet", isDirectory: true)
        config = home.appendingPathComponent(".trae-cn/hooks.json")
    }

    private func readConfig() throws -> [String: Any] {
        guard fm.fileExists(atPath: config.path) else { return [:] }
        let data = try Data(contentsOf: config)
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              document["hooks"] == nil || document["hooks"] is [String: Any],
              document["version"] == nil || document["version"] as? Int == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    private func containsBridge(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command } == true
    }

    func install(executable: URL) throws {
        var document = try readConfig()
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        for hook in Hook.allCases {
            let key = hook.rawValue
            var groups = hooks[key] as? [[String: Any]] ?? []
            guard hooks[key] == nil || hooks[key] is [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            if !groups.contains(where: containsBridge) {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5, "description": "花妖桌宠同步任务状态"]]]
                if [.beforeTool, .afterTool, .notification].contains(hook) { group["matcher"] = "*" }
                groups.append(group)
            }
            hooks[key] = groups
        }
        document["hooks"] = hooks
        if document["version"] == nil { document["version"] = 1 }

        try fm.createDirectory(at: bridge, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeHelper(executable)
        try writeConfig(document)
    }

    private func writeConfig(_ document: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: config, options: .atomic)
    }

    private func writeHelper(_ executable: URL) throws {
        let binary = try Data(contentsOf: executable)
        try binary.write(to: helper, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }

    func updateInstalledHelper(from executable: URL) throws {
        guard fm.fileExists(atPath: helper.path) else { return }
        let hooks = try readConfig()["hooks"] as? [String: Any] ?? [:]
        guard Hook.allCases.contains(where: { hook in
            (hooks[hook.rawValue] as? [[String: Any]])?.contains(where: containsBridge) == true
        }) else { return }
        let current = try Data(contentsOf: executable)
        if !fm.isExecutableFile(atPath: helper.path) || (try? Data(contentsOf: helper)) != current {
            try writeHelper(executable)
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled && fm.isExecutableFile(atPath: helper.path) {
            if !isEnabled { try Data().write(to: enabledMarker, options: .atomic) }
        } else if isEnabled {
            try fm.removeItem(at: enabledMarker)
        }
    }

    func uninstall() throws {
        try setEnabled(false)
        var document = try readConfig()
        if var hooks = document["hooks"] as? [String: Any] {
            var changed = false
            for hook in Hook.allCases {
                let key = hook.rawValue
                guard let groups = hooks[key] as? [[String: Any]], groups.contains(where: containsBridge) else { continue }
                let remainingGroups = groups.compactMap { group -> [String: Any]? in
                    guard let commands = group["hooks"] as? [[String: Any]], containsBridge(group) else { return group }
                    let remainingCommands = commands.filter { $0["command"] as? String != command }
                    guard !remainingCommands.isEmpty else { return nil }
                    var updated = group
                    updated["hooks"] = remainingCommands
                    return updated
                }
                hooks[key] = remainingGroups.isEmpty ? nil : remainingGroups
                changed = true
            }
            if changed {
                document["hooks"] = hooks
                try writeConfig(document)
            }
        }
        if fm.fileExists(atPath: helper.path) { try fm.removeItem(at: helper) }
    }

    func refresh(now: Date = Date(), after cutoff: Date? = nil) -> AgentStatus {
        if now.timeIntervalSince(lastConfigCheck) >= 5 {
            lastConfigCheck = now
            let hooks = (try? readConfig())?["hooks"] as? [String: Any] ?? [:]
            configured = fm.isExecutableFile(atPath: helper.path) && Hook.allCases.allSatisfy {
                (hooks[$0.rawValue] as? [[String: Any]])?.contains(where: containsBridge) == true
            }
        }
        guard configured else { return AgentStatus(connectionMessage: "请先配置 TRAE 联动") }
        let entries = (try? fm.contentsOfDirectory(at: events, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        var statuses: [AgentStatus] = []
        for url in entries where url.pathExtension == "json" {
            guard let modification = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            hasReceivedSignal = true
            guard now.timeIntervalSince(modification) < 1800,
                  let data = try? Data(contentsOf: url),
                  let signal = try? JSONDecoder().decode(Signal.self, from: data),
                  let state = AgentState(rawValue: signal.state) else { continue }
            let status = AgentStatus(state: state,
                                     toolDetail: state == .working ? "在调用工具" : "",
                                     lastActivity: signal.time,
                                     waitKind: signal.question == true ? .question : nil)
            if status.isAfter(cutoff) { statuses.append(status.expiring(at: now)) }
        }
        if let status = preferredStatus(statuses) { return status }
        if hasReceivedSignal { return AgentStatus(state: .idle) }
        return AgentStatus(connectionMessage: "已配置，等待 TRAE 任务")
    }

    func receive(_ input: Data, now: Date = Date()) throws {
        guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let session = payload["session_id"] as? String, !session.isEmpty,
              let name = payload["hook_event_name"] as? String, let hook = Hook(rawValue: name) else { return }
        let state: AgentState
        switch hook {
        case .start: state = .idle
        case .prompt, .afterTool: state = .thinking
        case .beforeTool: state = .working
        case .stop: state = .done
        case .notification:
            switch payload["notification_type"] as? String {
            case "idle_prompt": state = .done
            case "permission_prompt", "ask_user_question", "document_review", "browser_interaction":
                state = .waiting
            default: return
            }
        }

        try fm.createDirectory(at: events, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Hooks from different tools can arrive concurrently.
        let lock = open(events.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(lock, LOCK_UN) }
        guard isEnabled else { return }
        let key = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = events.appendingPathComponent(key).appendingPathExtension("json")
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Signal.self, from: $0) }
        if let previous {
            if previous.time > now { return }
            if previous.state == AgentState.done.rawValue, hook == .notification { return }
        }
        let question = (payload["notification_type"] as? String) == "ask_user_question"
        let data = try JSONEncoder().encode(Signal(state: state.rawValue, time: now, question: question ? true : nil))
        try data.write(to: file, options: .atomic)

        // Remove old signal files only when a new session first reports in.
        if previous == nil {
            let entries = (try? fm.contentsOfDirectory(at: events, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in entries where url.pathExtension == "json" {
                if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   now.timeIntervalSince(modified) > 7 * 86400 {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }
}
