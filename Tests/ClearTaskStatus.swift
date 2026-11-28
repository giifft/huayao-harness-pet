import Foundation
import SQLite3

/// Compile with the application sources except main.swift, then run the resulting executable.
@main
struct ClearTaskStatus {
    static func main() throws {
        let cutoff = Date()
        checkHistory(cutoff)
        checkDialogue(cutoff)
        checkWorkingDialogue()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try checkWorkBuddy(home, cutoff)
        try checkTrae(home, cutoff)
        print("Task status clear, restart, and new events passed")
    }

    private static func checkHistory(_ cutoff: Date) {
        let before = cutoff.addingTimeInterval(-2)
        let after = cutoff.addingTimeInterval(2)
        let running = AgentStatus(state: .working, lastActivity: before, sessionID: "running")
        let waiting = AgentStatus(state: .waiting, lastActivity: before, sessionID: "waiting")
        let finished = AgentStatus(state: .done, lastActivity: before, sessionID: "finished")
        func activities(_ statuses: AgentStatus...) -> [AgentActivity] {
            statuses.map { AgentActivity(platform: .codex, status: $0) }
        }

        var history = ActivityHistory(startedAt: before.addingTimeInterval(-1))
        let old = activities(running, waiting, finished)
        assert(history.update(old, now: before).count == 2)
        assert(history.recent.count == 1)
        history.clear(at: cutoff)
        assert(history.recent.isEmpty)
        assert(history.update(old, now: after).isEmpty && history.recent.isEmpty)

        let suite = "HuaYaoPet.clear-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(history.clearedAt, forKey: "activityClearedAt")
        let saved = UserDefaults(suiteName: suite)?.object(forKey: "activityClearedAt") as? Date
        assert(saved == cutoff)
        var reopened = ActivityHistory(startedAt: cutoff.addingTimeInterval(1), clearedAt: saved)

        var expired = running.expiring(at: cutoff.addingTimeInterval(181))
        expired.sessionTitle = "新标题"
        assert(!expired.isAfter(saved))
        assert(!AgentStatus(state: .done, lastActivity: cutoff).isAfter(saved))
        assert(reopened.update(old, now: after).isEmpty && reopened.recent.isEmpty)

        var completed = running
        completed.state = .done
        completed.lastActivity = after
        let new = activities(completed, waiting, expired)
        assert(completed.isAfter(saved))
        assert(reopened.update(new, now: after).map(\.status) == [completed])
        assert(reopened.update(new, now: after).isEmpty && reopened.recent.count == 1)

        var newRequest = waiting
        newRequest.lastActivity = after
        assert(reopened.update(activities(completed, newRequest), now: after).map(\.status) == [newRequest])
    }

    private static func checkDialogue(_ cutoff: Date) {
        let director = Director()
        let before = cutoff.addingTimeInterval(-1)
        let after = cutoff.addingTimeInterval(1)
        let old = AgentActivity(platform: .codex, status: AgentStatus(state: .waiting, lastActivity: before))
        let new = AgentActivity(platform: .antigravity, status: AgentStatus(state: .done, lastActivity: after))
        var spoken: [(String, Bool)] = []
        director.onSay = { spoken.append(($0.text, $1)) }
        director.activityChanged(old, notices: [old, old])
        assert(spoken.count == 1 && spoken[0].1)
        director.clearTaskDialogue()
        director.activityChanged(nil, notices: [new])
        RunLoop.main.run(until: Date().addingTimeInterval(3.9))
        assert(spoken.count == 2 && spoken[1].0 == "完成 · Antigravity" && spoken[1].1)
        director.stop()
    }

    private static func checkWorkBuddy(_ home: URL, _ cutoff: Date) throws {
        let directory = home.appendingPathComponent(".workbuddy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let result = sqlite3_open(directory.appendingPathComponent("workbuddy.db").path, &db)
        defer { sqlite3_close(db) }
        precondition(result == SQLITE_OK)
        let old = Int64(cutoff.addingTimeInterval(-2).timeIntervalSince1970 * 1000)
        let new = Int64(cutoff.addingTimeInterval(2).timeIntervalSince1970 * 1000)
        let sql = """
            CREATE TABLE sessions (status TEXT, updated_at INTEGER, last_activity_at INTEGER, deleted_at INTEGER);
            INSERT INTO sessions VALUES ('waiting', \(new), \(old), NULL);
            INSERT INTO sessions VALUES ('completed', \(new), \(new), NULL);
            """
        let inserted = sqlite3_exec(db, sql, nil, nil, nil)
        precondition(inserted == SQLITE_OK)
        let reader = WorkBuddyReader(home: home)
        let now = cutoff.addingTimeInterval(3)
        assert(reader.refresh(now: now).state == .waiting)
        assert(reader.refresh(now: now, after: cutoff).state == .done)
    }

    private static func checkWorkingDialogue() {
        let command = AgentStatus(state: .working, toolDetail: "在敲命令")
        let legacyCommand = AgentStatus(state: .working, toolDetail: "在跑命令")
        assert(command.detailLine == "她在敲命令" && legacyCommand.detailLine == command.detailLine)
        for speaker in [Speaker.hua, .sheng] {
            assert(Script.soloActivity(command, speaker: speaker)?.text.contains("她在敲命令") == true)
        }
        assert(Script.working(command).allSatisfy { $0.first?.text.contains("她在敲命令") == true })
        assert(Script.thinking(AgentStatus(state: .thinking))[0][1].text == "那就别吵，等她想明白。")
    }

    private static func checkTrae(_ home: URL, _ cutoff: Date) throws {
        let bridge = TraeBridge(home: home)
        try bridge.install(executable: URL(fileURLWithPath: "/usr/bin/true"))
        try bridge.setEnabled(true)
        let waiting = Data(#"{"session_id":"old","hook_event_name":"Notification","notification_type":"permission_prompt"}"#.utf8)
        let completed = Data(#"{"session_id":"new","hook_event_name":"Stop"}"#.utf8)
        try bridge.receive(waiting, now: cutoff.addingTimeInterval(-2))
        try bridge.receive(completed, now: cutoff.addingTimeInterval(2))
        let now = cutoff.addingTimeInterval(3)
        assert(bridge.refresh(now: now).state == .waiting)
        assert(bridge.refresh(now: now, after: cutoff).state == .done)
    }
}
