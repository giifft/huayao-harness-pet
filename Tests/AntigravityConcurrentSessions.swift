import Foundation

/// Compile with the application sources except main.swift, then run the resulting executable.
@main
struct AntigravityConcurrentSessions {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let config = home.appendingPathComponent(".gemini/config/hooks.json")
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let existing = Data(#"{"other":{"Stop":[{"command":"echo unrelated"}]}}"#.utf8)
        try existing.write(to: config)
        let bridge = AntigravityBridge(home: home)
        let executable = URL(fileURLWithPath: "/Applications/Hua Yao's Pet.app/Contents/MacOS/HuaYaoPet")

        func configDocument() throws -> NSDictionary {
            let data = try Data(contentsOf: config)
            return try JSONSerialization.jsonObject(with: data) as! NSDictionary
        }

        let original = try configDocument()
        try bridge.install(executable: executable)
        let installed = try configDocument()
        assert(installed.count == 2)
        let settings = installed["huayao-desktop-pet-status"] as! [String: Any]
        let invocation = (settings["PreInvocation"] as! [[String: Any]])[0]["command"] as! String
        assert(invocation.contains(#"Yao'"'"'s Pet.app"#))
        assert((settings["PreToolUse"] as! [[String: Any]])[0]["matcher"] as? String == "*")
        try bridge.install(executable: executable)
        let reinstalled = try configDocument()
        assert(reinstalled == installed)

        let a = UUID().uuidString.lowercased()
        let b = UUID().uuidString.lowercased()
        let started = Date()

        func emit(_ hook: AntigravityBridge.Hook, id: String, offset: Double, extras: [String: Any] = [:]) throws {
            let common: [String: Any] = [
                "conversationId": id,
                "workspacePaths": ["/private/workspace/两条任务"],
                "lastUserInput": "private prompt marker",
                "transcriptPath": "/private/transcript.jsonl",
            ]
            let payload = common.merging(extras) { _, new in new }
            try bridge.receive(hook, input: JSONSerialization.data(withJSONObject: payload),
                               now: started.addingTimeInterval(offset))
        }

        try emit(.invocation, id: a, offset: 0)
        try emit(.beforeTool, id: a, offset: 1, extras: [
            "stepIdx": 1, "toolCall": ["name": "run_command", "args": ["CommandLine": "private input marker"]],
        ])
        try emit(.beforeTool, id: a, offset: 2, extras: ["stepIdx": 2, "toolCall": ["name": "view_file"]])
        try emit(.afterTool, id: a, offset: 3, extras: ["stepIdx": 2])
        try emit(.invocation, id: b, offset: 4)
        try emit(.stop, id: b, offset: 5, extras: ["fullyIdle": false, "terminationReason": "model_stop"])

        let running = bridge.refresh(now: started.addingTimeInterval(6))
        assert(running.count == 2 && Set(running.map(\.state)) == [.working])
        assert(running.first { $0.sessionID == a }?.detailLine == "她在敲命令")
        assert(running.first { $0.sessionID == b }?.toolDetail == "后台任务运行中")
        assert(Set(running.map(\.projectName)) == ["两条任务"])

        try emit(.stop, id: b, offset: 7, extras: ["fullyIdle": true, "terminationReason": "model_stop"])
        try emit(.stop, id: b, offset: 8, extras: ["fullyIdle": true, "terminationReason": "model_stop"])
        try emit(.afterTool, id: b, offset: 9, extras: ["stepIdx": 4])
        let partial = bridge.refresh(now: started.addingTimeInterval(9))
        assert(partial.first { $0.sessionID == b }?.state == .done)
        assert(partial.first { $0.sessionID == b }?.lastActivity == started.addingTimeInterval(7))
        assert(partial.first { $0.sessionID == a }?.state == .working)

        try emit(.stop, id: a, offset: 10, extras: ["fullyIdle": true, "terminationReason": "error", "error": "private error marker"])
        try emit(.invocation, id: "../../bad", offset: 11)
        let completed = bridge.refresh(now: started.addingTimeInterval(11))
        assert(completed.count == 2 && completed.first { $0.sessionID == a }?.state == .error)
        let events = home.appendingPathComponent("Library/Application Support/HuaYaoPet/Antigravity")
        let files = try fm.contentsOfDirectory(at: events, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let stored = try String(contentsOf: file, encoding: .utf8)
            assert(!stored.contains("private"))
        }

        try bridge.uninstall()
        let restored = try configDocument()
        assert(restored == original)
        print("Antigravity hook installation, concurrent sessions, and cleanup passed")
    }
}
