import AppKit

// MARK: - 一句台词

struct Line {
    let speaker: Speaker
    let text: String
    var role: String? = nil
    var taskNotice: AgentActivity? = nil
}

enum Speaker {
    case hua   // 花旦
    case sheng // 小生

    var name: String {
        switch self {
        case .hua:   return "花旦"
        case .sheng: return "小生"
        }
    }

}

// MARK: - 台词库

enum Script {
    static let themeLyrics: [String] = {
        resourceLines("ThemeLyrics")
    }()

    static let operaScene: [Line] = resourceLines("OperaScene").compactMap { row in
        let parts = row.components(separatedBy: " · ")
        guard parts.count == 2 else { return nil }
        let role = parts[0]
        return Line(speaker: role == "黄生" ? .sheng : .hua, text: parts[1], role: role)
    }

    private static func resourceLines(_ name: String) -> [String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    static let themeCouplets: [[Line]] = stride(from: 0, to: max(0, themeLyrics.count - 1), by: 2).map { index in
        [Line(speaker: .hua, text: themeLyrics[index]),
         Line(speaker: .sheng, text: themeLyrics[index + 1])]
    }

    static func lyricExchanges(in mode: PetMode) -> [[Line]] {
        if mode == .duo, !themeCouplets.isEmpty { return themeCouplets }
        let speaker: Speaker = mode == .sheng ? .sheng : .hua
        return themeLyrics.map { [Line(speaker: speaker, text: $0)] }
    }

    static func tapLyrics(in mode: PetMode) -> [Line] {
        let theme = themeLyrics.enumerated().map { index, text in
            let speaker: Speaker = mode == .sheng || (mode == .duo && index % 2 == 1) ? .sheng : .hua
            return Line(speaker: speaker, text: text)
        }
        if mode == .duo { return theme + operaScene }
        let speaker: Speaker = mode == .sheng ? .sheng : .hua
        return theme + operaScene.filter { $0.speaker == speaker && $0.role?.contains("/") != true }
    }

    // MARK: 平台联动台词

    static func soloActivity(_ status: AgentStatus, speaker: Speaker) -> Line? {
        let text: String
        switch (status.state, speaker) {
        case (.thinking, .hua): text = "她正琢磨着呢，我且等一等。"
        case (.thinking, .sheng): text = "且容她把这道题想明白。"
        case (.working, .hua): text = "\(sayingWork(status))，我先把水袖理好。"
        case (.working, .sheng): text = "听，键盘响个不停，\(sayingWork(status))。"
        default: return nil
        }
        return Line(speaker: speaker, text: text)
    }

    static func thinking(_ s: AgentStatus) -> [[Line]] {
        let model = s.detailLine
        return [
            [Line(speaker: .hua, text: "她正琢磨着呢，\(model)。"),
             Line(speaker: .sheng, text: "那就别吵，等她想明白。")],
            [Line(speaker: .sheng, text: "咦，她不出声了，是在琢磨？"),
             Line(speaker: .hua, text: "嗯，眉毛都皱起来了。")],
            [Line(speaker: .hua, text: "想得久了些，怕是遇上难题。"),
             Line(speaker: .sheng, text: "难题才配得上她。")],
        ]
    }

    static func working(_ s: AgentStatus) -> [[Line]] {
        let what = sayingWork(s)
        return [
            [Line(speaker: .sheng, text: "听，键盘响个不停，\(what)。"),
             Line(speaker: .hua, text: "手脚麻利，倒像个角儿。")],
            [Line(speaker: .hua, text: "\(what)，咱们递杯茶去？"),
             Line(speaker: .sheng, text: "人家忙着呢，别添乱。")],
            [Line(speaker: .sheng, text: "\(what)——这活儿不轻。"),
             Line(speaker: .hua, text: "不轻才好，轻了没意思。")],
        ]
    }

    private static func sayingWork(_ status: AgentStatus) -> String {
        status.detailLine.isEmpty ? "她正忙着" : status.detailLine
    }

    static func autoChatLine(enabled: Bool, mode: PetMode) -> String {
        if mode == .duo { return enabled ? "好，我们接着说。" : "那我们安静些。" }
        return enabled ? "好，我接着说。" : "那我先静一静。"
    }
}

// MARK: - 剧场导演

final class Director {
    var onSay: ((Line, Bool) -> Void)?
    var customIdle: (() -> Bool)?
    var canAutoChat: (() -> Bool)?

    var mode: PetMode = .duo {
        didSet {
            guard mode != oldValue else { return }
            tapLyricIndex = 0
            clearDialogue(restartOpera: true)
        }
    }

    private var tapLyricIndex = 0
    private var pending: [(line: Line, isTask: Bool)] = []
    private var speechTimer: Timer?
    private var lastActivity: AgentActivity?
    private var idleTimer: Timer?
    private var lastIdleLine: Date = .distantPast
    private var operaNext = true
    private var hasPlayedOpera = false
    private var stateCooldown: [AgentState: Date] = [:]

    func start() {
        stop()
        operaNext = true
        hasPlayedOpera = false
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tickIdle() }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
        lastIdleLine = Date()
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        clearDialogue()
    }

    func clearDialogue(restartOpera: Bool = false) {
        speechTimer?.invalidate()
        speechTimer = nil
        pending.removeAll()
        lastIdleLine = Date()
        if restartOpera {
            operaNext = true
            hasPlayedOpera = false
        }
    }

    func clearTaskDialogue() {
        pending.removeAll { $0.isTask }
        stateCooldown.removeAll()
    }

    // MARK: 对外事件

    func tapped() {
        let lyrics = Script.tapLyrics(in: mode)
        guard !lyrics.isEmpty else { return }
        clearDialogue()
        let line = lyrics[tapLyricIndex]
        tapLyricIndex = (tapLyricIndex + 1) % lyrics.count
        enqueue([line])
    }

    func speakLyrics() {
        enqueue(Script.lyricExchanges(in: mode).randomElement() ?? [])
    }

    func activityChanged(_ activity: AgentActivity?, notices: [AgentActivity]) {
        let previous = lastActivity
        lastActivity = activity
        let state = activity?.status.state
        let enteredBusyState = state?.isBusy == true
            && (activity?.id != previous?.id || state != previous?.status.state)
        if enteredBusyState || !notices.isEmpty {
            if pending.contains(where: { $0.line.role != nil }) {
                operaNext = true
            }
            pending.removeAll { $0.line.role != nil }
        }
        if !notices.isEmpty {
            let lines = notices.map { notice in
                let status = notice.status
                let text = status.state == .waiting ? status.detailLine : status.state.title
                let name = notice.displayName
                // Keep the status visible in the bubble when a title is long.
                return Line(speaker: mode == .sheng ? .sheng : .hua,
                            text: "\(text) · \(String(name.prefix(40)))", taskNotice: notice)
            }
            enqueue(lines, isTask: true)
            return
        }
        guard let activity else { return }
        let s = activity.status
        let st = s.state
        guard st == .thinking || st == .working,
              activity.id != previous?.id || st != previous?.status.state,
              speechTimer == nil else { return }
        if let last = stateCooldown[st], Date().timeIntervalSince(last) < 25 { return }
        if st == .thinking && previous?.platform == activity.platform && previous?.status.state == .working { return }

        stateCooldown[st] = Date()
        switch mode {
        case .hua, .sheng:
            let who: Speaker = mode == .hua ? .hua : .sheng
            if let line = Script.soloActivity(s, speaker: who) { enqueue([line], isTask: true) }
        case .duo:
            let exchanges = st == .thinking ? Script.thinking(s) : Script.working(s)
            guard let lines = exchanges.randomElement() else { return }
            enqueue(lines, isTask: true)
        }
    }

    // MARK: 排队说话

    private func enqueue(_ items: [Line], isTask: Bool = false) {
        pending.append(contentsOf: items.map { ($0, isTask) })
        pump()
    }

    private func pump() {
        guard speechTimer == nil, !pending.isEmpty else { return }
        let (line, isTask) = pending.removeFirst()
        lastIdleLine = Date()
        onSay?(line, isTask)
        let timer = Timer(timeInterval: 3.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.speechTimer = nil
            self.pump()
        }
        RunLoop.main.add(timer, forMode: .common)
        speechTimer = timer
    }

    // MARK: 闲时自动开口

    private func tickIdle() {
        guard Prefs.autoChat, canAutoChat?() != false,
              lastActivity?.status.state != .waiting else { return }
        let quiet = Date().timeIntervalSince(lastIdleLine)
        guard quiet >= (hasPlayedOpera ? 26 : 6), speechTimer == nil, pending.isEmpty else { return }
        // A running task may last a long time. Give it priority for notifications
        // without keeping the opening scene offstage until the task ends.
        guard lastActivity?.status.state.isBusy != true || operaNext else { return }
        if operaNext {
            operaNext = false
            hasPlayedOpera = true
            let lines = idleOpera()
            if !lines.isEmpty {
                enqueue(lines)
                return
            }
        } else {
            operaNext = true
        }

        lastIdleLine = Date()
        if Bool.random(), customIdle?() == true { return }

        speakLyrics()
    }

    private func idleOpera() -> [Line] {
        if mode == .duo, !Script.operaScene.isEmpty {
            return Script.operaScene
        }
        guard let lyric = Script.themeLyrics.randomElement() else { return [] }
        return [Line(speaker: mode == .sheng ? .sheng : .hua, text: lyric)]
    }
}
