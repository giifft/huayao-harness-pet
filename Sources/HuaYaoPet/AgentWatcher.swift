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

    var isBusy: Bool { self == .thinking || self == .working || self == .waiting }
}

struct AgentStatus: Equatable {
    var state: AgentState = .offline
    var toolDetail = ""
    var modelName = ""
    var connectionMessage = "暂无会话"
    var lastActivity: Date = .distantPast

    var detailLine: String {
        switch state {
        case .offline: return connectionMessage
        case .idle: return modelName.isEmpty ? "会话待命" : shortModel
        case .thinking: return modelName.isEmpty ? "正在推理" : shortModel
        case .working: return toolDetail
        case .waiting: return "等待你确认"
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
    case codex, harness, workBuddy, trae, doubao

    var name: String {
        switch self {
        case .codex: return "Codex"
        case .harness: return "DeepSeek Harness"
        case .workBuddy: return "WorkBuddy"
        case .trae: return "TRAE"
        case .doubao: return "豆包"
        }
    }

    var shortName: String { self == .harness ? "Harness" : name }
}

struct AgentActivity: Equatable {
    let platform: AgentPlatform
    let status: AgentStatus
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
        let refresh: () -> AgentStatus
        var inFlight = false

        init(_ refresh: @escaping () -> AgentStatus) { self.refresh = refresh }
    }

    var onChange: (([AgentPlatform: AgentStatus]) -> Void)?
    private var readers: [AgentPlatform: Reader] = [:]
    private var statuses: [AgentPlatform: AgentStatus] = [:]
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
                statuses[platform] = AgentStatus(connectionMessage: "正在连接")
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
        for (platform, reader) in readers where !reader.inFlight {
            reader.inFlight = true
            reader.queue.async { [weak self] in
                let status = reader.refresh()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.readers[platform] === reader else { return }
                    reader.inFlight = false
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
            return Reader { reader.refresh() }
        case .harness:
            let root = env["DSH_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".dsh")
            let reader = DSHSessionReader(root: root.appendingPathComponent("sessions", isDirectory: true))
            return Reader { reader.refresh() }
        case .workBuddy:
            let reader = WorkBuddyReader(home: home)
            return Reader { reader.refresh() }
        case .trae:
            let reader = TraeBridge(home: home)
            return Reader { reader.refresh() }
        case .doubao:
            let reader = DoubaoReader()
            return Reader { reader.refresh() }
        }
    }
}
