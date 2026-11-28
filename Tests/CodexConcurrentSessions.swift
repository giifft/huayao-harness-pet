import Foundation

/// Run from the repository root:
/// swiftc -parse-as-library $(find Sources/HuaYaoPet -name "*.swift" ! -name main.swift) Tests/CodexConcurrentSessions.swift -o /tmp/huayao-codex-test
/// /tmp/huayao-codex-test
@main
struct CodexConcurrentSessions {
    static func main() throws {
        let fs = FileManager.default
        let root = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try fs.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: root) }

        let started = Date()
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func journal(_ id: String, cwd: String, delegated: Bool = false) throws -> URL {
            let url = sessions.appendingPathComponent("rollout-\(id).jsonl")
            let meta: [String: Any] = [
                "id": id, "cwd": cwd, "source": delegated ? ["subagent": "spawn"] as Any : "cli",
            ]
            try row("session_meta", meta, at: started, into: url, append: false)
            return url
        }
        func row(_ type: String, _ payload: [String: Any], at date: Date, into url: URL, append: Bool = true) throws {
            var data = try JSONSerialization.data(withJSONObject: [
                "type": type, "timestamp": dates.string(from: date), "payload": payload,
            ])
            data.append(10)
            if append {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        }

        let a = try journal("task-a", cwd: "/work/演出物料")
        let b = try journal("task-b", cwd: "/work/演出物料")
        let c = try journal("task-c", cwd: "/work/花妖桌宠")
        _ = try journal("delegated", cwd: "/work/花妖桌宠", delegated: true)
        try Data("{\"id\":\"task-a\",\"thread_name\":\"修改海报\"}\n{\"id\":\"task-b\",\"thread_name\":\"检查文案\"}\n".utf8)
            .write(to: root.appendingPathComponent("session_index.jsonl"))
        try row("response_item", ["type": "function_call", "name": "exec_command", "call_id": "same"], at: started, into: a)
        try row("response_item", ["type": "function_call", "name": "request_user_input", "call_id": "same"], at: started, into: b)
        try row("event_msg", ["type": "task_started"], at: started, into: c)

        let reader = CodexSessionReader(root: sessions)
        var history = ActivityHistory(startedAt: started.addingTimeInterval(-1))
        func activities(at now: Date) -> [AgentActivity] {
            reader.refreshSessions(now: now).map { AgentActivity(platform: .codex, status: $0) }
        }
        let first = activities(at: started)
        assert(first.count == 3)
        assert(first.first { $0.status.sessionID == "task-a" }?.status.detailLine == "她在敲命令")
        assert(first.first { $0.status.sessionID == "task-b" }?.displayName == "Codex · 演出物料 · 检查文案")
        assert(first.first { $0.status.sessionID == "task-c" }?.status.projectName == "花妖桌宠")
        assert(history.update(first, now: started).map(\.id.session) == ["task-b"])

        let second = started.addingTimeInterval(1)
        try row("event_msg", ["type": "task_complete"], at: second, into: a)
        try row("event_msg", ["type": "turn_aborted"], at: second, into: c)
        try row("response_item", ["type": "function_call_output", "call_id": "same"], at: second, into: a)
        let finished = activities(at: second)
        assert(finished.sorted(by: AgentActivity.prioritized).first?.status.sessionID == "task-b")
        let notices = history.update(finished, now: second)
        assert(Set(notices.compactMap(\.id.session)) == ["task-a", "task-c"])
        assert(Set(notices.map(\.status.state)) == [.done, .cancelled])
        assert(history.update(finished, now: second).isEmpty)

        let third = started.addingTimeInterval(20)
        try row("response_item", ["type": "function_call_output", "call_id": "same"], at: third, into: b)
        let settled = activities(at: third)
        assert(settled.first { $0.status.sessionID == "task-b" }?.status.state == .thinking)
        assert(settled.first { $0.status.sessionID == "task-a" }?.status.state == .idle)
        assert(history.update(settled, now: third).isEmpty && history.recent.count == 2)
        var reopened = ActivityHistory(startedAt: second.addingTimeInterval(1))
        assert(reopened.update(finished, now: second.addingTimeInterval(1)).map(\.id.session) == ["task-b"])
        print("Codex concurrent sessions passed")
    }
}
