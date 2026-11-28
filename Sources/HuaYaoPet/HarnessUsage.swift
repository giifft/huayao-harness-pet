import Foundation
import CoreFoundation

enum HarnessWaitKind: Equatable {
    case question, approval
}

enum HarnessPricingPeriod: String {
    case peak, offPeak, unknown

    var label: String {
        switch self {
        case .peak: return "高峰时段"
        case .offPeak: return "空闲时段"
        case .unknown: return "时段待核实"
        }
    }
}

struct HarnessUsageRound: Equatable {
    let id: String
    let completedAt: Date
    let models: [String]
    let tokens: Int64
    let estimatedCost: Decimal?
    let knownCost: Decimal
    fileprivate let usageByDay: [String: HarnessUsageSlice]
}

private struct HarnessUsageSlice: Equatable {
    var tokens: Int64 = 0
    var knownCost: Decimal = 0
    var unpriced = false

    mutating func add(tokens: Int64, cost: Decimal?) {
        self.tokens += tokens
        knownCost += cost ?? 0
        unpriced = unpriced || cost == nil
    }
}

struct HarnessUsageDay: Equatable {
    let day: String
    var tokens: Int64 = 0
    var roundCount = 0
    var knownCost: Decimal = 0
    var unpricedRoundCount = 0

    fileprivate mutating func add(_ slice: HarnessUsageSlice) {
        tokens += slice.tokens
        knownCost += slice.knownCost
        if slice.unpriced { unpricedRoundCount += 1 }
    }
}

struct HarnessUsageSummary: Equatable {
    let day: String
    let todayTokens: Int64
    let todayRoundCount: Int
    let todayKnownCost: Decimal
    let todayUnpricedRoundCount: Int
    let latestRound: HarnessUsageRound?
    let pricingPeriod: HarnessPricingPeriod
    let nextPricingChange: Date?
    let history: [HarnessUsageDay]
    let recentRounds: [HarnessUsageRound]
    let scanPending: Bool
}

struct HarnessPricing: Decodable {
    private struct Tariff: Decodable {
        let from: String
        let models: [String]
        let offPeak: [Decimal]
        let peak: [Decimal]
    }

    private let calendarThrough: String
    private let weekendOffPeakFrom: String
    private let holidayOffPeakFrom: String
    private let peakHours: [[Int]]
    private let holidayRanges: [[String]]
    private let providers: [String]
    private let tariffs: [Tariff]

    static let beijing = TimeZone(secondsFromGMT: 8 * 3600)!
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        return calendar
    }()

    static let bundled: HarnessPricing? = {
        guard let url = Bundle.main.url(forResource: "HarnessPricing", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HarnessPricing.self, from: data)
    }()

    static let isoFormatter = ISO8601DateFormatter()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = beijing
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ time: Date) -> String { dayFormatter.string(from: time) }

    func period(at time: Date) -> HarnessPricingPeriod {
        let day = Self.day(time)
        guard day >= "2026-08-17", day <= calendarThrough else { return .unknown }
        let weekday = Self.calendar.component(.weekday, from: time)
        if day >= weekendOffPeakFrom, weekday == 1 || weekday == 7 { return .offPeak }
        if day >= holidayOffPeakFrom, holidayRanges.contains(where: {
            $0.count == 2 && day >= $0[0] && day <= $0[1]
        }) { return .offPeak }
        let hour = Self.calendar.component(.hour, from: time)
        return peakHours.contains { $0.count == 2 && hour >= $0[0] && hour < $0[1] } ? .peak : .offPeak
    }

    func nextChange(after time: Date) -> Date? {
        let current = period(at: time)
        guard current != .unknown else { return nil }
        let start = Self.calendar.startOfDay(for: time)
        let hours = Set(peakHours.flatMap { $0 }).sorted()
        for offset in 0...14 {
            guard let day = Self.calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            for hour in hours {
                let candidate = day.addingTimeInterval(Double(hour) * 3600)
                guard candidate > time else { continue }
                let period = period(at: candidate)
                if period == .unknown { return nil }
                if period != current { return candidate }
            }
        }
        return nil
    }

    func cost(model: String, provider: String, at time: Date, cached: Int64, input: Int64, output: Int64) -> Decimal? {
        guard providers.contains(provider.lowercased()), let name = model.lowercased().split(separator: "/").last,
              let tariff = tariffs.reversed().first(where: {
                  $0.models.contains(String(name)) && (Self.isoFormatter.date(from: $0.from) ?? .distantFuture) <= time
              }) else { return nil }
        let phase = period(at: time)
        guard phase != .unknown else { return nil }
        let rate = phase == .peak ? tariff.peak : tariff.offPeak
        guard rate.count == 3 else { return nil }
        return (Decimal(cached) * rate[0] + Decimal(input) * rate[1] + Decimal(output) * rate[2]) / 1_000_000
    }
}

/// Folds only usage metadata. Message bodies and tool arguments never enter the ledger.
struct HarnessUsageFold {
    private struct Turn {
        var messageIDs: Set<String> = []
        var models: Set<String> = []
        var usageByDay: [String: HarnessUsageSlice] = [:]
    }

    private let sessionID: String
    private let pricing: HarnessPricing?
    private var turns: [Int: Turn] = [:]
    private(set) var rounds: [HarnessUsageRound] = []

    init(sessionID: String, pricing: HarnessPricing?) {
        self.sessionID = sessionID
        self.pricing = pricing
    }

    mutating func accept(type: String, data: [String: Any], sequence: Int, time: Date) {
        guard let turnID = data["turn"] as? Int, turnID >= 0,
              time.timeIntervalSince1970 >= 0, time.timeIntervalSince1970 <= 253_402_271_999 else { return }
        if type == "turn/end" {
            guard let turn = turns.removeValue(forKey: turnID), !turn.messageIDs.isEmpty else { return }
            let slices = turn.usageByDay.values
            let knownCost = slices.reduce(Decimal.zero) { $0 + $1.knownCost }
            rounds.append(HarnessUsageRound(id: "\(sessionID):\(turnID)", completedAt: time,
                                            models: turn.models.sorted(), tokens: slices.reduce(0) { $0 + $1.tokens },
                                            estimatedCost: slices.contains(where: \.unpriced) ? nil : knownCost,
                                            knownCost: knownCost, usageByDay: turn.usageByDay))
            return
        }
        guard type == "assistant/message", let usage = data["usage"] as? [String: Any],
              let message = data["message"] as? [String: Any],
              let input = Self.counter(usage, "inputTokens", required: true),
              let output = Self.counter(usage, "outputTokens", required: true),
              let cached = Self.counter(usage, "cacheReadTokens"),
              let cacheWrite = Self.counter(usage, "cacheWriteTokens"),
              let reasoning = Self.counter(usage, "reasoningTokens"), reasoning <= output else { return }

        let source = message["source"] as? [String: Any]
        let model = (source?["model"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(128)) } ?? "未知"
        let provider = (source?["provider"] as? String) ?? ""
        let messageID = (message["id"] as? String).flatMap { $0.isEmpty ? nil : "id:\($0)" } ?? "seq:\(sequence)"
        var turn = turns.removeValue(forKey: turnID) ?? Turn()
        if turn.messageIDs.insert(messageID).inserted {
            turn.models.insert(model)
            // Harness excludes cache reads and writes from input and includes reasoning in output.
            let cost = pricing?.cost(model: model, provider: provider, at: time, cached: cached,
                                     input: input + cacheWrite, output: output)
            turn.usageByDay[HarnessPricing.day(time), default: HarnessUsageSlice()]
                .add(tokens: input + output + cached + cacheWrite, cost: cost)
        }
        turns[turnID] = turn
    }

    private static func counter(_ usage: [String: Any], _ key: String, required: Bool = false) -> Int64? {
        guard let value = usage[key] else { return required ? nil : 0 }
        guard let numeric = value as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID(),
              let number = value as? Int64, number >= 0, number <= 1_000_000_000 else { return nil }
        return number
    }
}

extension HarnessUsageSummary {
    static func make(rounds: [HarnessUsageRound], now: Date, pricing: HarnessPricing?, pending: Bool) -> Self {
        var days: [String: HarnessUsageDay] = [:]
        var seen: Set<String> = []
        var recent: [HarnessUsageRound] = []
        for round in rounds where round.completedAt <= now && seen.insert(round.id).inserted {
            let day = HarnessPricing.day(round.completedAt)
            days[day, default: HarnessUsageDay(day: day)].roundCount += 1
            for (usageDay, slice) in round.usageByDay {
                days[usageDay, default: HarnessUsageDay(day: usageDay)].add(slice)
            }
            recent.append(round)
        }
        recent.sort { $0.completedAt == $1.completedAt ? $0.id > $1.id : $0.completedAt > $1.completedAt }
        let today = HarnessPricing.day(now)
        let day = days[today] ?? HarnessUsageDay(day: today)
        return Self(day: today, todayTokens: day.tokens, todayRoundCount: day.roundCount,
                    todayKnownCost: day.knownCost, todayUnpricedRoundCount: day.unpricedRoundCount,
                    latestRound: recent.first, pricingPeriod: pricing?.period(at: now) ?? .unknown,
                    nextPricingChange: pricing?.nextChange(after: now),
                    history: days.values.sorted { $0.day > $1.day }, recentRounds: Array(recent.prefix(30)), scanPending: pending)
    }
}
