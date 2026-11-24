import AppKit

// MARK: - 一句台词

struct Line {
    let speaker: Speaker
    let text: String
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
        guard let url = Bundle.main.url(forResource: "ThemeLyrics", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }()

    static func idleLines(for speaker: Speaker) -> [String] {
        (idleSolo[speaker] ?? []) + themeLyrics
    }

    /// 双人小剧场：两人一来一往
    static let idleDuos: [[Line]] = [
        [Line(speaker: .hua, text: "你看那水袖，风一吹就开了。"),
         Line(speaker: .sheng, text: "开的不是袖，是你的心思。")],
        [Line(speaker: .sheng, text: "今日台下的灯，亮得很。"),
         Line(speaker: .hua, text: "灯再亮，也不及你回眸那一下。")],
        [Line(speaker: .hua, text: "我唱到「花妖」那一句，总想多停半拍。"),
         Line(speaker: .sheng, text: "那我就多等半拍，正好接上。")],
        [Line(speaker: .sheng, text: "你袖上的花，绣得真细。"),
         Line(speaker: .hua, text: "细的是针脚，粗的是我这个人。")],
        [Line(speaker: .hua, text: "要是有一日不唱了，你做什么？"),
         Line(speaker: .sheng, text: "在你窗下种一棵花树，年年开给你看。")],
        [Line(speaker: .hua, text: "方才走位，你又踩到我裙子了。"),
         Line(speaker: .sheng, text: "……我那是想离你近些。")],
        [Line(speaker: .sheng, text: "这段念白，我总觉得少了口气。"),
         Line(speaker: .hua, text: "少的那口气，我替你续上。")],
        [Line(speaker: .hua, text: "台下有位小姑娘，看哭了。"),
         Line(speaker: .sheng, text: "那咱们更得唱好，别辜负了眼泪。")],
        [Line(speaker: .sheng, text: "你今日的妆，比昨日淡一点。"),
         Line(speaker: .hua, text: "淡些好，近看才不吓着你。")],
        [Line(speaker: .hua, text: "戏散了，人走了，台子还热着。"),
         Line(speaker: .sheng, text: "那我们就再站一会儿。")],
        [Line(speaker: .sheng, text: "你听，外头下雨了。"),
         Line(speaker: .hua, text: "正好，雨声比锣鼓更像心事。")],
        [Line(speaker: .hua, text: "这身红衣，是借来的。"),
         Line(speaker: .sheng, text: "衣裳是借的，站在这儿的人不是。")],
    ] + stride(from: 0, to: max(0, themeLyrics.count - 1), by: 2).map { index in
        [Line(speaker: .hua, text: themeLyrics[index]),
         Line(speaker: .sheng, text: themeLyrics[index + 1])]
    }

    /// 单人闲话
    static let idleSolo: [Speaker: [String]] = [
        .hua: [
            "水袖一甩，半台都是风。",
            "今日的胭脂，调得正好。",
            "戏还没开，先吊一吊嗓子。",
            "你且坐着，我理理这裙摆。",
            "花钿有些歪了……算了，歪着也好看。",
            "台上一分钟，台下十年功，这话不假。",
            "若有人问起，就说我在等一场花开。",
        ],
        .sheng: [
            "折扇一展，便是半个江南。",
            "我这一身青，衬不衬今日的天？",
            "唱念做打，先站稳了再说。",
            "别急，好戏都在后头。",
            "她方才那一眼，我记了一整天。",
            "台下静些，容我把这句念完。",
            "少年人唱老戏，也唱得出新意。",
        ],
    ]

    // MARK: 平台联动台词

    static func thinking(_ s: AgentStatus) -> [[Line]] {
        let model = s.detailLine
        return [
            [Line(speaker: .hua, text: "那边正琢磨着呢，\(model)。"),
             Line(speaker: .sheng, text: "那就别吵，等他想明白。")],
            [Line(speaker: .sheng, text: "咦，那边不出声了，是在琢磨？"),
             Line(speaker: .hua, text: "嗯，眉毛都皱起来了。")],
            [Line(speaker: .hua, text: "想得久了些，怕是遇上难题。"),
             Line(speaker: .sheng, text: "难题才配得上他。")],
        ]
    }

    static func working(_ s: AgentStatus) -> [[Line]] {
        let what = s.toolDetail.isEmpty ? "忙" : s.toolDetail
        return [
            [Line(speaker: .sheng, text: "听，键盘响个不停，他\(what)。"),
             Line(speaker: .hua, text: "手脚麻利，倒像个角儿。")],
            [Line(speaker: .hua, text: "他\(what)，咱们递杯茶去？"),
             Line(speaker: .sheng, text: "人家忙着呢，别添乱。")],
            [Line(speaker: .sheng, text: "\(what)——这活儿不轻。"),
             Line(speaker: .hua, text: "不轻才好，轻了没意思。")],
        ]
    }

    static func done(_ s: AgentStatus) -> [[Line]] {
        return [
            [Line(speaker: .hua, text: "哎，那边安静了，是忙完了。"),
             Line(speaker: .sheng, text: "那便歇一歇，喝口茶。")],
            [Line(speaker: .sheng, text: "活儿收尾了，漂亮。"),
             Line(speaker: .hua, text: "给他鼓个掌罢。")],
            [Line(speaker: .hua, text: "一场下来，也算圆满。"),
             Line(speaker: .sheng, text: "散场了，咱们也该谢幕。")],
        ]
    }

    static func error(_ s: AgentStatus) -> [[Line]] {
        return [
            [Line(speaker: .sheng, text: "糟了，那边好像出了岔子。"),
             Line(speaker: .hua, text: "别慌，戏台上摔一跤也是常事。")],
            [Line(speaker: .hua, text: "他卡住了，要不要过去看看？"),
             Line(speaker: .sheng, text: "先等等，他自己能起来。")],
        ]
    }

    // MARK: 点击回应

    static let tapHua: [String] = [
        "别戳啦，妆要花了。",
        "哎哟，袖子都被你拽歪了。",
        "看戏便看戏，动手做什么。",
        "再点我，我可要开腔了。",
        "你这人，比台下的小孩还闹。",
        "摸摸头可以，掐脸不行。",
    ]

    static let tapSheng: [String] = [
        "这位看官，扇子可是我的兵器。",
        "拍我肩膀做什么？上台了上台了。",
        "再敲，折扇可要合上了。",
        "你这手劲儿，比锣鼓还响。",
        "我站得稳稳的，你推不动。",
        "别闹，正走神呢。",
    ]

    static let tapDuo: [String] = [
        "两个人一起戳，也不怕把我们戳散。",
        "看归看，可别把我们拆开。",
        "这一对儿，可不是摆设。",
    ]

    /// 单人模式：一个人在台上，念着另一个人
    static let soloHua: [String] = [
        "他今日没来，我先替他把台子暖着。",
        "水袖甩了两遍，总觉得少个接的人。",
        "「花妖」这句，本该是两个人唱的。",
        "你若见着他，替我说一声：戏还等着呢。",
        "一个人站这儿，风都显得大了些。",
        "妆是照着两个人的戏上的。",
        "我且唱着，他听见了自会接上。",
    ]

    static let soloSheng: [String] = [
        "她今日没来，这折扇也懒得展开了。",
        "台子空了一半，站哪儿都不对。",
        "念白到那句，总习惯停半拍等她。",
        "你若见着她，就说我在原处候着。",
        "一个人的戏，锣鼓都敲得轻了。",
        "我把位置留着，左边那半。",
        "先吊一吊嗓子，等人齐了再唱。",
    ]

    /// 切换模式时的开场白
    static func modeIntro(_ mode: PetMode) -> String {
        switch mode {
        case .hua:   return "且坐片刻，容我理一理水袖。"
        case .sheng: return "折扇才展开，锣鼓还未响呢。"
        case .duo:   return "两个人都在了，这戏才齐整。"
        }
    }
}

// MARK: - 剧场导演

final class Director {
    var onSay: ((Line) -> Void)?

    var mode: PetMode = .duo {
        didSet { if mode != oldValue { clearDialogue() } }
    }

    private var pending: [Line] = []
    private var speechTimer: Timer?
    private var lastActivity: AgentActivity?
    private var idleTimer: Timer?
    private var lastIdleLine: Date = .distantPast
    private var stateCooldown: [AgentState: Date] = [:]

    func start() {
        stop()
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

    func clearDialogue() {
        speechTimer?.invalidate()
        speechTimer = nil
        pending.removeAll()
        lastIdleLine = Date()
    }

    func showWelcome() {
        switch mode {
        case .hua: enqueue([Line(speaker: .hua, text: "台子搭好了，容我理一理水袖。")])
        case .sheng: enqueue([Line(speaker: .sheng, text: "台前灯亮了，我把折扇备好。")])
        case .duo: enqueue([Line(speaker: .hua, text: "今日台子搭好了，你且坐。"),
                            Line(speaker: .sheng, text: "有事便唤我们，无事就看戏。")])
        }
    }

    // MARK: 对外事件

    func tapped() {
        clearDialogue()
        let speaker: Speaker
        let pool: [String]
        switch mode {
        case .hua:
            speaker = .hua
            pool = Script.tapHua
        case .sheng:
            speaker = .sheng
            pool = Script.tapSheng
        case .duo:
            speaker = .hua
            pool = Script.tapDuo
        }
        enqueue([Line(speaker: speaker, text: pool.randomElement() ?? "嗯？")])
    }

    /// The displayed platform drives the pet's reactions.
    func activityChanged(_ activity: AgentActivity?) {
        let previous = lastActivity
        lastActivity = activity
        guard let activity else { return }
        let s = activity.status
        let st = s.state
        if st == .idle || st == .offline { return }
        let isTerminal = st == .done || st == .error || st == .cancelled
        guard activity.platform != previous?.platform || st != previous?.status.state || (isTerminal && s.lastActivity != previous?.status.lastActivity) else { return }
        let isPriority = st == .waiting || isTerminal
        if !isPriority {
            guard speechTimer == nil else { return }
            if let last = stateCooldown[st], Date().timeIntervalSince(last) < 25 { return }
        }

        var lines: [Line] = []
        switch st {
        case .thinking:
            if previous?.platform != activity.platform || previous?.status.state != .working { lines = Script.thinking(s).randomElement() ?? [] }
        case .working:
            lines = Script.working(s).randomElement() ?? []
        case .done:
            lines = Script.done(s).randomElement() ?? []
        case .error:
            lines = Script.error(s).randomElement() ?? []
        case .waiting:
            lines = [Line(speaker: .hua, text: "那边等你点头呢，回 \(activity.platform.shortName) 看一眼罢。")]
        case .cancelled:
            lines = [Line(speaker: .sheng, text: "这一场先停在这儿，歇一歇罢。")]
        case .idle, .offline:
            break
        }
        guard !lines.isEmpty else { return }
        stateCooldown[st] = Date()
        if isPriority { clearDialogue() }

        switch mode {
        case .hua, .sheng:
            // 单人模式：只取其中一句，改由场上的人念出来，居中
            let who: Speaker = mode == .hua ? .hua : .sheng
            let pick = lines.first(where: { $0.speaker == who }) ?? lines[0]
            enqueue([Line(speaker: who, text: pick.text)])
        case .duo:
            enqueue(lines)
        }
    }

    // MARK: 排队说话

    private func enqueue(_ items: [Line]) {
        pending.append(contentsOf: items)
        pump()
    }

    private func pump() {
        guard speechTimer == nil, !pending.isEmpty else { return }
        let line = pending.removeFirst()
        lastIdleLine = Date()
        onSay?(line)
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
        guard Prefs.autoChat, lastActivity?.status.state.isBusy != true else { return }
        let quiet = Date().timeIntervalSince(lastIdleLine)
        guard quiet > 26, speechTimer == nil, pending.isEmpty else { return }
        lastIdleLine = Date()

        switch mode {
        case .hua, .sheng:
            // 单人：自言自语，气泡居中
            let who: Speaker = mode == .hua ? .hua : .sheng
            let solo = who == .hua ? Script.soloHua : Script.soloSheng
            let pool = Bool.random() ? solo : Script.idleLines(for: who)
            enqueue([Line(speaker: who, text: pool.randomElement() ?? "……")])

        case .duo:
            if Bool.random() {
                // 双人小剧场
                enqueue(Script.idleDuos.randomElement() ?? [])
            } else {
                let who: Speaker = Bool.random() ? .hua : .sheng
                let pool = Script.idleLines(for: who)
                enqueue([Line(speaker: who, text: pool.randomElement() ?? "……")])
            }
        }
    }
}
