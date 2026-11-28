import Foundation

/// Run inside an app bundle containing HarnessPricing.json and dsh-unzstd.
/// Arguments are the shared JSON fixture and a path to the zstd CLI.
@main
struct HarnessUsageSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected fixture and zstd executable paths.") }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let zstd = URL(fileURLWithPath: CommandLine.arguments[2])
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let now = date(fixture["now"] as! String)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let mainRows = fixture["main"] as! [[String: Any]]
        let main = try write(mainRows, to: root.appendingPathComponent("workspace/main"), modified: now, zstd: zstd)
        _ = try write(fixture["child"] as! [[String: Any]], to: root.appendingPathComponent("workspace/branch"),
                      modified: now.addingTimeInterval(1), zstd: zstd)
        _ = try write(mainRows, to: root.appendingPathComponent("backup/main"),
                      modified: now.addingTimeInterval(-1), zstd: zstd)

        precondition(HarnessPricing.bundled != nil)
        let reader = DSHSessionReader(root: root)
        check(reader.refresh(now: now), now: now)
        check(reader.refresh(now: now.addingTimeInterval(1)), now: now)
        check(DSHSessionReader(root: root).refresh(now: now), now: now)

        try Data("incomplete frame".utf8).write(to: main)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(3)], ofItemAtPath: main.path)
        check(reader.refresh(now: now.addingTimeInterval(3)), now: now, pending: true)
        _ = try write(mainRows, to: main.deletingLastPathComponent(), modified: now.addingTimeInterval(4), zstd: zstd)
        check(reader.refresh(now: now.addingTimeInterval(4)), now: now)

        let weekend = reader.refresh(now: date("2026-11-28T10:00:00+08:00")).harnessUsage
        precondition(weekend?.pricingPeriod == .offPeak && weekend?.nextPricingChange == date("2026-11-30T09:00:00+08:00"))
        let holiday = reader.refresh(now: date("2027-06-09T10:00:00+08:00")).harnessUsage
        precondition(holiday?.pricingPeriod == .offPeak && holiday?.nextPricingChange == date("2027-06-10T09:00:00+08:00"))
        print("PASS Harness usage, duplicate and delegated sessions, restart, partial file, question, and peak calendar")
    }

    private static func check(_ status: AgentStatus, now: Date, pending: Bool = false) {
        let usage = status.harnessUsage!
        precondition(status.state == .waiting && status.waitKind == .question)
        precondition(status.sessionID == "main" && status.sessionTitle == "测试任务" && status.projectName == "花妖")
        precondition(usage.todayRoundCount == 3 && usage.todayTokens == 4571 && usage.todayUnpricedRoundCount == 1)
        precondition(usage.todayKnownCost == Decimal(string: "0.01041"))
        precondition(usage.latestRound?.id == "main:3" && usage.latestRound?.estimatedCost == nil && usage.latestRound?.tokens == 61)
        precondition(usage.history.count == 2 && usage.history[1].knownCost == Decimal(string: "0.00068"))
        precondition(usage.pricingPeriod == .peak && usage.nextPricingChange == date("2026-11-27T12:00:00+08:00"))
        precondition(usage.scanPending == pending)
    }

    private static func write(_ rows: [[String: Any]], to directory: URL, modified: Date, zstd: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonl = directory.appendingPathComponent("session.jsonl")
        let compressed = directory.appendingPathComponent("session.v4.jsonl.zstd")
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(0x0a)
        }
        try data.write(to: jsonl)
        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-q", "-f", jsonl.path, "-o", compressed.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: compressed.path)
        return compressed
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
