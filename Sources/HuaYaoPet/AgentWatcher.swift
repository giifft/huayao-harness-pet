import Foundation

enum AgentState: String {
    case offline, idle, thinking, working, waiting, done, cancelled, error

    var title: String {
        switch self {
        case .offline: return "未连接"
        case .idle: return "空闲"
        case .thinking: return "思考中"
        case .working: return "干活中"
        case .waiting: return "待确认"
        case .done: return "完成"
        case .cancelled: return "已中止"
        case .error: return "出错"
        }
    }

    var isTerminal: Bool { self == .done || self == .cancelled || self == .error }

    var isBusy: Bool { self == .thinking || self == .working || self == .waiting }
}

struct AgentStatus: Equatable {
    var state: AgentState = .offline
    var toolDetail = ""
    var modelName = ""
    var connectionMessage = "暂无会话"
    var lastActivity: Date = .distantPast
    var sessionID: String?
    var projectName = ""
    var sessionTitle = ""
    var harnessUsage: HarnessUsageSummary?
    var waitKind: HarnessWaitKind?

    var detailLine: String {
        switch state {
        case .offline: return connectionMessage
        case .idle: return modelName.isEmpty ? "会话待命" : shortModel
        case .thinking: return modelName.isEmpty ? "正在推理" : shortModel
        case .working:
            if toolDetail == "在跑命令" { return "她在敲命令" }
            return toolDetail.hasPrefix("在") || toolDetail.hasPrefix("正在") ? "她" + toolDetail : toolDetail
        case .waiting: return waitKind == .question ? "等待你回答" : "等待你确认"
        case .done: return "刚忙完一轮"
        case .cancelled: return "本轮已中止"
        case .error: return "本轮遇到问题"
        }
    }

    private var shortModel: String {
        String(modelName.split(separator: "/").last ?? "")
    }
}

enum AgentPlatform: String, CaseIterable {
    case codex, harness, workBuddy, trae, antigravity, doubao

    var name: String {
        switch self {
        case .codex: return "Codex"
        case .harness: return "DeepSeek Harness"
        case .workBuddy: return "WorkBuddy"
        case .trae: return "TRAE"
        case .antigravity: return "Antigravity"
        case .doubao: return "豆包"
        }
    }

    var shortName: String { self == .harness ? "Harness" : name }
}

struct AgentActivity: Equatable {
    struct ID: Hashable {
        let platform: AgentPlatform
        let session: String?
    }

    let platform: AgentPlatform
    let status: AgentStatus

    var id: ID { ID(platform: platform, session: status.sessionID) }

    var displayName: String {
        var parts = [platform.shortName]
        if !status.projectName.isEmpty { parts.append(status.projectName) }
        if let id = status.sessionID {
            parts.append(status.sessionTitle.isEmpty ? "会话 \(id.prefix(8))" : status.sessionTitle)
        }
        return parts.joined(separator: " · ")
    }

    static func prioritized(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.status.state.priority != rhs.status.state.priority {
            return lhs.status.state.priority > rhs.status.state.priority
        }
        if lhs.status.lastActivity != rhs.status.lastActivity {
            return lhs.status.lastActivity > rhs.status.lastActivity
        }
        if lhs.platform != rhs.platform { return lhs.platform.rawValue < rhs.platform.rawValue }
        return (lhs.status.sessionID ?? "") < (rhs.status.sessionID ?? "")
    }
}

struct ActivityHistory {
    private let startedAt: Date
    private var previous: [AgentActivity.ID: AgentStatus] = [:]
    private(set) var clearedAt: Date?
    private(set) var recent: [AgentActivity] = []

    init(startedAt: Date = Date(), clearedAt: Date? = nil) {
        self.startedAt = startedAt
        self.clearedAt = clearedAt
    }

    mutating func clear(at time: Date) {
        clearedAt = time
        previous.removeAll()
        recent.removeAll()
    }

    mutating func update(_ activities: [AgentActivity], now: Date = Date()) -> [AgentActivity] {
        let visible = activities.filter { $0.status.isAfter(clearedAt) }
        var notices: [AgentActivity] = []
        for activity in visible {
            let status = activity.status
            if status.state.isTerminal {
                let seen = recent.contains {
                    $0.id == activity.id && $0.status.state == status.state &&
                    $0.status.lastActivity == status.lastActivity
                }
                let last = previous[activity.id]
                guard !seen, last?.state != status.state || last?.lastActivity != status.lastActivity else { continue }
                recent.append(activity)
                if status.lastActivity >= startedAt { notices.append(activity) }
            } else if status.state == .waiting, previous[activity.id]?.state != .waiting {
                notices.append(activity)
            }
        }
        recent = Array(recent.filter { now.timeIntervalSince($0.status.lastActivity) <= 1800 }
            .sorted { $0.status.lastActivity > $1.status.lastActivity }.prefix(32))
        previous = Dictionary(visible.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        return notices.sorted(by: AgentActivity.prioritized)
    }
}

func preferredStatus(_ statuses: [AgentStatus]) -> AgentStatus? {
    statuses.max {
        if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
        return $0.lastActivity < $1.lastActivity
    }
}

extension AgentState {
    var priority: Int {
        switch self {
        case .waiting: return 4
        case .thinking, .working: return 3
        case .done, .cancelled, .error: return 2
        case .idle: return 1
        case .offline: return 0
        }
    }
}

extension AgentStatus {
    func isAfter(_ cutoff: Date?) -> Bool {
        cutoff.map { lastActivity > $0 } ?? true
    }

    func expiring(at now: Date, busy: TimeInterval = 180, waiting: TimeInterval = 900) -> Self {
        let hold = state == .waiting ? waiting : state.isBusy ? busy : 14
        guard state.priority > AgentState.idle.priority, now.timeIntervalSince(lastActivity) > hold else {
            return self
        }
        var status = self
        status.state = .idle
        status.toolDetail = ""
        return status
    }
}

final class AgentWatcher {
    private final class Reader {
        let queue = DispatchQueue(label: "local.huayao.agent", qos: .utility)
        let refresh: (Date?) -> [AgentStatus]
        var inFlight = false

        init(_ refresh: @escaping (Date?) -> [AgentStatus]) { self.refresh = refresh }
    }

    var onChange: (([AgentPlatform: [AgentStatus]]) -> Void)?
    var activityClearedAt: Date?
    private var readers: [AgentPlatform: Reader] = [:]
    private(set) var statuses: [AgentPlatform: [AgentStatus]] = [:]
    private var timer: Timer?

    func start(platforms: Set<AgentPlatform>) {
        for platform in AgentPlatform.allCases {
            guard platforms.contains(platform) else {
                readers[platform] = nil
                statuses[platform] = nil
                continue
            }
            if readers[platform] == nil {
                readers[platform] = makeReader(for: platform)
                statuses[platform] = [AgentStatus(connectionMessage: "正在连接")]
            }
        }
        onChange?(statuses)
        if readers.isEmpty {
            stop()
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        readers.removeAll()
        statuses.removeAll()
    }

    private func tick() {
        let cutoff = activityClearedAt
        for (platform, reader) in readers where !reader.inFlight {
            reader.inFlight = true
            reader.queue.async { [weak self] in
                let status = reader.refresh(cutoff)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.readers[platform] === reader else { return }
                    reader.inFlight = false
                    guard self.activityClearedAt == cutoff else { return }
                    guard self.statuses[platform] != status else { return }
                    self.statuses[platform] = status
                    self.onChange?(self.statuses)
                }
            }
        }
    }

    private func makeReader(for platform: AgentPlatform) -> Reader {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        switch platform {
        case .codex:
            let root = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            let reader = CodexSessionReader(root: root.appendingPathComponent("sessions", isDirectory: true))
            return Reader { _ in reader.refreshSessions() }
        case .harness:
            let root = env["DSH_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".dsh")
            let reader = DSHSessionReader(root: root.appendingPathComponent("sessions", isDirectory: true))
            return Reader { _ in [reader.refresh()] }
        case .workBuddy:
            let reader = WorkBuddyReader(home: home)
            return Reader { cutoff in [reader.refresh(after: cutoff)] }
        case .trae:
            let reader = TraeBridge(home: home)
            return Reader { cutoff in [reader.refresh(after: cutoff)] }
        case .antigravity:
            let reader = AntigravityBridge(home: home)
            return Reader { _ in reader.refresh() }
        case .doubao:
            let reader = DoubaoReader()
            return Reader { _ in [reader.refresh()] }
        }
    }
}
