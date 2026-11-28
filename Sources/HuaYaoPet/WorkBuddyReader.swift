import Foundation
import SQLite3

/// Observes the desktop client's persisted task status through a read-only SQLite connection.
final class WorkBuddyReader {
    private let databases: [URL]

    init(home: URL) {
        databases = [".workbuddy", ".ygsoftworkbuddy"].map {
            home.appendingPathComponent($0).appendingPathComponent("workbuddy.db")
        }
    }

    func refresh(now: Date = Date(), after cutoff: Date? = nil) -> AgentStatus {
        let paths = databases.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !paths.isEmpty else { return AgentStatus(connectionMessage: "暂无 WorkBuddy 本地任务") }
        let statuses = paths.compactMap { read($0, now: now, after: cutoff) }
        return preferredStatus(statuses) ?? AgentStatus(connectionMessage: "任务库暂时无法读取")
    }

    private func read(_ url: URL, now: Date, after cutoff: Date?) -> AgentStatus? {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(database, 150)
        let query = """
            SELECT status, updated_at, last_activity_at FROM sessions
            WHERE deleted_at IS NULL AND updated_at >= ?1
              AND (?2 IS NULL OR COALESCE(NULLIF(last_activity_at, 0), updated_at) > ?2)
            ORDER BY updated_at DESC LIMIT 64
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64((now.timeIntervalSince1970 - 1800) * 1000))
        if let cutoff {
            sqlite3_bind_double(statement, 2, cutoff.timeIntervalSince1970 * 1000)
        }
        var statuses: [AgentStatus] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                let raw = String(cString: text)
                let state: AgentState
                switch raw {
                case "pending", "awaiting_input", "waiting": state = .waiting
                case "planning", "thinking": state = .thinking
                case "working", "running", "active", "stopping", "in_progress": state = .working
                case "Completed", "completed": state = .done
                case "Terminated", "terminated", "cancelled": state = .cancelled
                case "error", "failed": state = .error
                default: state = .idle
                }
                let updated = sqlite3_column_int64(statement, 1)
                let activity = sqlite3_column_int64(statement, 2)
                // After a clear, use the activity clock so a metadata edit cannot revive a task.
                let timestamp = cutoff != nil && activity > 0 ? activity : max(updated, activity)
                let time = Date(timeIntervalSince1970: Double(timestamp) / 1000)
                let status = AgentStatus(state: state,
                                         toolDetail: state == .working ? "正在处理任务" : "",
                                         lastActivity: time,
                                         waitKind: raw == "awaiting_input" ? .question : nil)
                statuses.append(status.expiring(at: now, busy: 600, waiting: 1800))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { return nil }
        return preferredStatus(statuses) ?? AgentStatus(state: .idle)
    }
}
