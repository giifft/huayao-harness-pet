import AppKit
import QuartzCore

// MARK: - 控制器

final class PetController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: PetWindow!
    private var scene: PetSceneView!
    private var petals: PetalView!
    private var bubble: BubbleView!
    private var statusPill: StatusPill!
    private var director = Director()
    private let watcher = AgentWatcher()
    private let billing = PetBilling()
    private let traeBridge = TraeBridge(home: FileManager.default.homeDirectoryForCurrentUser)
    private var statusItem: NSStatusItem!
    private var bubbleTimer: Timer?
    private var interaction = PetInteractionSettings.load()
    private let soundPlayer = PetSoundPlayer()
    @MainActor private lazy var interactionDialogs = PetInteractionDialogs(soundPlayer: soundPlayer)
    private var tapLineIndex = 0
    private var lowBalanceText = ""
    private var balanceNoticePending = false
    private var isTaskBubble = false
    private var currentScale: CGFloat = 1
    private var menu: NSMenu!
    private let linkMenu = NSMenu(title: "AI 联动")
    private var linkItem: NSMenuItem!
    private let taskMenu = NSMenu(title: "项目与任务")
    private var taskItem: NSMenuItem!
    private var activityHistory = ActivityHistory(clearedAt: Prefs.activityClearedAt)
    private var currentTasks: [AgentActivity] = []
    private var platformItems: [AgentPlatform: NSMenuItem] = [:]
    private let poseMenu = NSMenu(title: "选择立绘")
    private var modeMenuItems: [PetMode: NSMenuItem] = [:]
    private var mode: PetMode = .duo
    private let baseSpriteHeight: CGFloat = 196

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Assets.shared.loadIfNeeded()
        // 自检用：HUAYAO_MODE=hua|sheng|duo 可强制指定启动模式
        switch ProcessInfo.processInfo.environment["HUAYAO_MODE"] {
        case "hua":   mode = .hua
        case "sheng": mode = .sheng
        case "duo":   mode = .duo
        default:      mode = Prefs.mode
        }
        director.mode = mode

        currentScale = CGFloat(Prefs.scale).clamped(0.7, 1.6)
        buildWindow()
        scene.pose = Assets.shared.selectedPose(for: mode)
        buildMenu()
        buildStatusItem()
        wireDirector()
        updateModeMenuState()
        placeWindow()

        director.start()
        watcher.activityClearedAt = activityHistory.clearedAt
        watcher.onChange = { [weak self] s in
            self?.applyActivity(s)
        }
        do {
            if let executable = Bundle.main.executableURL {
                try traeBridge.updateInstalledHelper(from: executable)
            }
            try traeBridge.setEnabled(Prefs.linkedPlatforms.contains(.trae))
        } catch {
            showLinkError("无法更新 TRAE 联动", error: error)
        }
        billing.roundCompleted = { [weak self] cost, model in self?.showTurnCost(cost, model: model) }
        billing.balanceWarning = { [weak self] low, balance in self?.setBalanceWarning(low, balance: balance) }
        billing.budgetWarning = { [weak self] amount in self?.showBudgetWarning(amount) }
        billing.start()
        watcher.start(platforms: Prefs.linkedPlatforms)
        director.speakLyrics()

        if let snap = ProcessInfo.processInfo.environment["HUAYAO_SNAPSHOT"] {
            let forced = ProcessInfo.processInfo.environment["HUAYAO_TEXT"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if let t = forced { self?.sayInCurrentMode(t, preferred: .sheng) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.debugSnapshot(to: snap)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        billing.stop()
        director.stop()
        watcher.stop()
        if let o = window?.frame.origin { Prefs.windowOrigin = o }
    }

    // MARK: 构建界面

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 420, height: 320)
        window = PetWindow(contentRect: rect)
        window.level = interaction.alwaysOnTop ? .floating : .normal

        let root = NSView(frame: rect)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = root

        petals = PetalView(frame: rect)
        petals.autoresizingMask = [.width, .height]
        root.addSubview(petals)

        scene = PetSceneView(frame: rect)
        scene.autoresizingMask = [.width, .height]
        root.addSubview(scene)

        bubble = BubbleView(frame: NSRect(x: 0, y: rect.height - 88, width: 220, height: 66))
        bubble.autoresizingMask = []
        bubble.onHit = { [weak self] in self?.handleBubbleTap() }
        root.addSubview(bubble)

        statusPill = StatusPill(frame: NSRect(x: 8, y: 4, width: 120, height: 20))
        root.addSubview(statusPill)
        statusPill.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showTaskMenu)))

        scene.onClick = { [weak self] in self?.handlePetTap() }
        scene.onDragEnded = { [weak self] in
            guard let self, let screen = self.window.screen ?? NSScreen.main else { return }
            let frame = self.interaction.docking.place(self.window.frame, on: screen.visibleFrame, snap: true)
            self.window.setFrameOrigin(frame.origin)
            self.updateMirroring(on: screen.visibleFrame)
            Prefs.windowOrigin = frame.origin
            self.playPetSound(.land)
        }
        scene.onZoom = { [weak self] delta in
            guard let self else { return }
            self.applyScale(self.currentScale + delta)
        }

        window.orderFrontRegardless()
    }

    private func buildMenu() {
        let m = NSMenu()
        taskItem = NSMenuItem(title: "项目与任务", action: nil, keyEquivalent: "")
        taskItem.submenu = taskMenu
        taskMenu.addItem(withTitle: "暂无任务活动", action: nil, keyEquivalent: "")
        taskMenu.delegate = self
        m.addItem(taskItem)
        linkItem = NSMenuItem(title: "AI 联动", action: nil, keyEquivalent: "")
        linkItem.submenu = linkMenu
        m.addItem(linkItem)
        let billingItem = NSMenuItem(title: "用量与余额…", action: #selector(openBilling), keyEquivalent: "")
        billingItem.target = self
        m.addItem(billingItem)
        for (index, platform) in AgentPlatform.allCases.enumerated() {
            let item = NSMenuItem(title: platform.name, action: #selector(togglePlatform(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            platformItems[platform] = item
            linkMenu.addItem(item)
        }
        linkMenu.addItem(.separator())
        let setup = NSMenuItem(title: "配置 TRAE 联动…", action: #selector(configureTrae), keyEquivalent: "")
        setup.target = self
        linkMenu.addItem(setup)
        let remove = NSMenuItem(title: "移除 TRAE 联动…", action: #selector(removeTrae), keyEquivalent: "")
        remove.target = self
        linkMenu.addItem(remove)
        let configureAntigravity = NSMenuItem(title: "配置 Antigravity 联动…",
                                              action: #selector(configureAntigravityLink), keyEquivalent: "")
        configureAntigravity.target = self
        linkMenu.addItem(configureAntigravity)
        let removeAntigravity = NSMenuItem(title: "移除 Antigravity 联动",
                                           action: #selector(removeAntigravityLink), keyEquivalent: "")
        removeAntigravity.target = self
        linkMenu.addItem(removeAntigravity)
        let toggle = NSMenuItem(title: "开启或关闭全部联动", action: #selector(toggleAllPlatforms), keyEquivalent: "")
        toggle.target = self
        linkMenu.addItem(toggle)
        m.addItem(.separator())

        // 三个模式
        for (i, pm) in PetMode.allCases.enumerated() {
            let item = NSMenuItem(title: pm.rawValue,
                                  action: #selector(selectMode(_:)),
                                  keyEquivalent: ["1", "2", "3"][i])
            item.target = self
            item.tag = i
            item.toolTip = "切换到\(pm.rawValue)模式"
            m.addItem(item)
            modeMenuItems[pm] = item
        }

        m.addItem(.separator())

        let choosePose = NSMenuItem(title: "选择立绘", action: nil, keyEquivalent: "")
        choosePose.submenu = poseMenu
        m.addItem(choosePose)

        let randomPose = NSMenuItem(title: "换一张立绘", action: #selector(showRandomPose), keyEquivalent: "d")
        randomPose.target = self
        m.addItem(randomPose)

        let talk = NSMenuItem(title: "说点什么", action: #selector(speakNow), keyEquivalent: "t")
        talk.target = self
        m.addItem(talk)

        m.addItem(.separator())

        let chat = NSMenuItem(title: "自动闲聊", action: #selector(toggleAutoChat), keyEquivalent: "")
        chat.target = self
        chat.state = Prefs.autoChat ? .on : .off
        m.addItem(chat)

        let petalsItem = NSMenuItem(title: "花瓣飘落", action: #selector(togglePetals), keyEquivalent: "")
        petalsItem.target = self
        petalsItem.state = petals?.isEnabled == true ? .on : .off
        m.addItem(petalsItem)

        m.addItem(.separator())

        let bigger = NSMenuItem(title: "放大", action: #selector(zoomIn), keyEquivalent: "+")
        bigger.target = self
        m.addItem(bigger)
        let smaller = NSMenuItem(title: "缩小", action: #selector(zoomOut), keyEquivalent: "-")
        smaller.target = self
        m.addItem(smaller)
        let reset = NSMenuItem(title: "还原大小", action: #selector(zoomReset), keyEquivalent: "0")
        reset.target = self
        m.addItem(reset)

        m.addItem(.separator())

        let corner = NSMenuItem(title: "挪到屏幕右下角", action: #selector(moveToCorner), keyEquivalent: "")
        corner.target = self
        m.addItem(corner)

        let top = NSMenuItem(title: "始终置顶", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        top.target = self
        top.state = interaction.alwaysOnTop ? .on : .off
        m.addItem(top)

        appendInteractionMenu(to: m)
        m.addItem(.separator())

        let quit = NSMenuItem(title: "退出桌宠", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)

        menu = m
        scene.menu = m
        window.contentView?.menu = m
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "theatermasks.fill", accessibilityDescription: "花妖桌宠")
            b.image?.isTemplate = true
            b.toolTip = "花妖 · 桌宠（右键切换花旦／小生／双人）"
        }
        statusItem.menu = menu
    }

    private func wireDirector() {
        director.canAutoChat = { [weak self] in
            guard let self else { return false }
            return self.window.isVisible && !self.isTaskBubble
        }
        director.onSay = { [weak self] line, isTask in
            guard let self, self.window.isVisible else { return }
            if let notice = line.taskNotice, notice.status.state == .waiting {
                let event = self.waitEvent(for: notice.status)
                let values = ["task": String(notice.displayName.prefix(40))]
                self.sayBubble(event, values: values, fallback: line.text, isTask: true)
            } else {
                self.say(line.speaker, line.text, role: line.role, isTask: isTask)
            }
        }
        director.customIdle = { [weak self] in
            guard let self, self.window.isVisible else { return false }
            return self.sayBubble(.idle)
        }
    }

    // MARK: 尺寸与位置

    private func applyScale(_ scale: CGFloat) {
        currentScale = scale.clamped(0.7, 1.6)
        Prefs.scale = Double(currentScale)
        relayout(keepOnScreen: true)
        if let window { Prefs.windowOrigin = window.frame.origin }
    }

    private func relayout(keepOnScreen: Bool = true) {
        guard let window, let scene else { return }
        scene.spriteHeight = baseSpriteHeight * currentScale
        let size = scene.desiredSize()
        var frame = window.frame
        // 以底边中心为锚点缩放，桌宠不会乱跳
        let anchorX = frame.midX
        let bottom = frame.minY
        let newW = size.width
        let newH = max(size.height, 160)
        frame = NSRect(x: anchorX - newW / 2, y: bottom, width: newW, height: newH)
        if keepOnScreen, let screen = window.screen {
            let area = screen.visibleFrame
            let old = window.frame
            if abs(old.minX - area.minX) < 0.5 { frame.origin.x = area.minX }
            if abs(old.maxX - area.maxX) < 0.5 { frame.origin.x = area.maxX - newW }
            if abs(old.maxY - area.maxY) < 0.5 { frame.origin.y = area.maxY - newH }
            frame = fitted(frame, to: area)
        }
        window.setFrame(frame, display: true)
        if let screen = window.screen { updateMirroring(on: screen.visibleFrame) }
        window.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        scene.frame = window.contentView!.bounds
        petals.frame = window.contentView!.bounds
        layoutBubble()
        let pillWidth = min(210, newW - 16)
        statusPill.frame = NSRect(x: (newW - pillWidth) / 2, y: 3, width: pillWidth, height: 20)
    }

    private func layoutBubble() {
        guard let bubble, let content = window.contentView else { return }
        let cw = content.bounds.width
        let maxTextW = max(80, min(210, cw - 56))
        let size = BubbleView.measure(text: bubble.text.isEmpty ? "测" : bubble.text,
                                      speaker: bubble.speaker,
                                      image: bubble.image,
                                      maxTextWidth: maxTextW)
        let w = min(size.width, cw - 8)
        let h = size.height + (bubble.link == nil ? 0 : 19)
        let bx = (cw - w) / 2
        let by = content.bounds.height - h - 2
        bubble.frame = NSRect(x: bx, y: by, width: w, height: h)
    }

    private func placeWindow() {
        guard let window else { return }
        relayout(keepOnScreen: false)
        let saved = Prefs.windowOrigin
        let screens = NSScreen.screens
        let savedFrame = saved.map { NSRect(origin: $0, size: window.frame.size) }
        let matching = savedFrame.flatMap { frame in
            screens.max { overlap(frame, $0.visibleFrame) < overlap(frame, $1.visibleFrame) }
        }.flatMap { screen in
            savedFrame.map { overlap($0, screen.visibleFrame) > 0 } == true ? screen : nil
        }
        let screen = (matching ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let corner = NSPoint(x: screen.maxX - size.width - 40, y: screen.minY + 30)
        let frame = NSRect(origin: matching == nil ? corner : (saved ?? corner), size: size)
        window.setFrameOrigin(fitted(frame, to: screen).origin)
        updateMirroring(on: screen)
    }

    private func overlap(_ frame: NSRect, _ screen: NSRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        return intersection.width * intersection.height
    }

    private func fitted(_ frame: NSRect, to screen: NSRect) -> NSRect {
        interaction.docking.place(frame, on: screen, snap: false)
    }

    // MARK: 说话

    private func say(_ who: Speaker, _ text: String, role: String? = nil, isTask: Bool = false,
                     image: NSImage? = nil, duration: TimeInterval = 3.2, link: URL? = nil) {
        guard let bubble else { return }
        isTaskBubble = isTask
        bubble.speaker = role ?? who.name
        bubble.text = text
        bubble.image = image
        bubble.link = link
        bubble.imageAboveText = interaction.bubbles.imageAboveText == true
        layoutBubble()
        bubble.animator().alphaValue = 1

        bubbleTimer?.invalidate()
        bubbleTimer = nil
        guard duration > 0 else { return }
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isTaskBubble = false
            self.bubble.animator().alphaValue = 0
            self.showPendingBalanceWarning()
        }
        RunLoop.main.add(t, forMode: .common)
        bubbleTimer = t
    }

    private func handleBubbleTap() {
        if isTaskBubble || bubbleTimer == nil {
            bubbleTimer?.invalidate()
            bubbleTimer = nil
            isTaskBubble = false
            bubble.animator().alphaValue = 0
            return
        }
        handlePetTap()
    }

    // MARK: AI 联动

    @objc private func openBilling() { billing.open() }

    private func applyActivity(_ statuses: [AgentPlatform: [AgentStatus]]) {
        let platforms = Prefs.linkedPlatforms
        let observed = AgentPlatform.allCases.flatMap { platform in
            (statuses[platform] ?? []).map { AgentActivity(platform: platform, status: $0) }
        }.filter { $0.status.state != .offline }
        let cutoff = activityHistory.clearedAt
        let activities = observed.filter { $0.status.isAfter(cutoff) }.sorted(by: AgentActivity.prioritized)
        let notices = activityHistory.update(observed)
        let connected = Set(observed.map(\.platform)).count
        for platform in AgentPlatform.allCases {
            let item = platformItems[platform]
            let source = statuses[platform]
            let status = source.flatMap { values in
                preferredStatus(values.filter { $0.state == .offline || $0.isAfter(cutoff) })
            }
            let text = status.map { $0.state == .offline ? $0.detailLine : $0.state.title }
                ?? (source == nil ? "已关闭" : "等待新任务活动")
            item?.title = "\(platform.name) · \(text)"
            item?.state = platforms.contains(platform) ? .on : .off
            item?.toolTip = status?.detailLine
        }
        linkMenu.items.last?.title = platforms.isEmpty ? "开启常规联动" : "关闭全部联动"

        let selected = activities.first
        let waiting = activities.filter { $0.status.state == .waiting }.count
        let running = activities.filter { $0.status.state == .thinking || $0.status.state == .working }.count
        let activeCounts = [running > 0 ? "\(running) 项进行中" : nil, waiting > 0 ? "\(waiting) 项待确认" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let summary: String
        if !activeCounts.isEmpty {
            summary = activeCounts
        } else if let selected {
            summary = "\(selected.platform.shortName) · \(selected.status.state.title)"
        } else {
            if platforms.isEmpty { summary = "AI 联动已关闭" }
            else { summary = cutoff == nil ? "AI 联动 · 等待会话" : "等待新任务活动" }
        }
        currentTasks = activities.filter { $0.status.state.isBusy || ($0.status.sessionID != nil && !$0.status.state.isTerminal) }
        taskItem.title = activeCounts.isEmpty ? "项目与任务" : "项目与任务 · \(activeCounts)"
        linkItem.title = "AI 联动  ·  \(connected)/\(AgentPlatform.allCases.count)"
        statusItem.button?.toolTip = summary
        let pillStatus = activeCounts.isEmpty
            ? selected?.status ?? AgentStatus(state: connected > 0 ? .idle : .offline)
            : AgentStatus(state: selected?.status.state ?? .idle)
        statusPill.update(pillStatus, summary: summary)
        scene.activity = selected?.status.state ?? .idle
        updateFeedbackPose()
        for notice in notices where notice.status.state == .waiting {
            playPetSound(waitEvent(for: notice.status) == .question ? .question : .approval)
        }
        director.activityChanged(selected, notices: notices)
        billing.observe(statuses[.harness]?.compactMap(\.harnessUsage).first)
        showPendingBalanceWarning()
    }

    @objc private func showTaskMenu() {
        taskMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: statusPill.bounds.height), in: statusPill)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === taskMenu else { return }
        menu.removeAllItems()
        let now = Date()
        let recent = activityHistory.recent.filter {
            Prefs.linkedPlatforms.contains($0.platform) && now.timeIntervalSince($0.status.lastActivity) <= 1800
        }
        let sections = [("会话", currentTasks), ("最近结果", recent)]
        let duplicates = Dictionary(grouping: currentTasks + recent, by: \.displayName).filter {
            Set($0.value.map(\.id)).count > 1
        }
        for (title, items) in sections where !items.isEmpty {
            if !taskMenu.items.isEmpty { taskMenu.addItem(.separator()) }
            taskMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            for item in items {
                let status = item.status
                let display = item.displayName
                let suffix = duplicates[display] != nil ? status.sessionID.map { " (\($0.prefix(8)))" } ?? "" : ""
                let name = "\(status.state.title) · \(display)\(suffix)"
                let detail = status.state == .working && !status.detailLine.isEmpty ? " · \(status.detailLine)" : ""
                let row = taskMenu.addItem(withTitle: name + detail, action: nil, keyEquivalent: "")
                let time = status.lastActivity == .distantPast ? "" : status.lastActivity.formatted(date: .omitted, time: .shortened)
                row.toolTip = [status.detailLine, time].filter { !$0.isEmpty }.joined(separator: " · ")
            }
        }
        if taskMenu.items.isEmpty {
            taskMenu.addItem(withTitle: "暂无任务活动", action: nil, keyEquivalent: "")
        }
        taskMenu.addItem(.separator())
        let hasTasks = !currentTasks.isEmpty || !recent.isEmpty
        let clear = taskMenu.addItem(withTitle: "清空任务状态",
                                     action: hasTasks ? #selector(clearTaskStatus) : nil, keyEquivalent: "")
        clear.target = self
        clear.isEnabled = hasTasks
        clear.toolTip = "清空桌宠中各平台的任务显示和提醒，继续监听新活动。"
    }

    @objc private func clearTaskStatus() {
        let now = Date()
        Prefs.activityClearedAt = now
        activityHistory.clear(at: now)
        watcher.activityClearedAt = now
        director.clearTaskDialogue()
        if isTaskBubble {
            bubbleTimer?.invalidate()
            bubbleTimer = nil
            isTaskBubble = false
            bubble.animator().alphaValue = 0
        }
        applyActivity(watcher.statuses)
    }

    /// 自检：把当前窗口内容渲染成 PNG
    func debugSnapshot(to path: String) {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
            NSLog("[HuaYaoPet] snapshot -> \(path)")
        }
    }

    // MARK: 菜单动作

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < PetMode.allCases.count else { return }
        setMode(PetMode.allCases[sender.tag], announce: true)
    }

    private func setMode(_ newMode: PetMode, announce: Bool) {
        mode = newMode
        Prefs.mode = newMode
        director.mode = newMode

        scene.pose = Assets.shared.selectedPose(for: mode)
        tapLineIndex = 0
        updateFeedbackPose()
        relayout()
        updateModeMenuState()

        if announce { speakNow() }
    }

    private func updateModeMenuState() {
        for (pm, item) in modeMenuItems {
            item.state = (pm == mode) ? .on : .off
        }
        rebuildPoseMenu()
    }

    private func rebuildPoseMenu() {
        poseMenu.removeAllItems()
        for pose in Assets.shared.poses(for: mode) {
            let item = NSMenuItem(title: pose.title, action: #selector(selectPose(_:)), keyEquivalent: "")
            item.target = self
            item.image = pose.menuThumbnail
            item.representedObject = pose
            item.state = pose.id == scene.pose?.id ? .on : .off
            poseMenu.addItem(item)
        }
    }

    @objc private func selectPose(_ item: NSMenuItem) {
        guard let pose = item.representedObject as? PetPose else { return }
        setPose(pose)
    }

    @objc private func showRandomPose() {
        let otherPoses = Assets.shared.poses(for: mode).filter { $0.id != scene.pose?.id }
        guard let pose = otherPoses.randomElement() else { return }
        setPose(pose)
    }

    private func setPose(_ pose: PetPose) {
        scene.pose = pose
        Prefs.setPoseID(pose.id, for: mode)
        relayout()
        for item in poseMenu.items {
            item.state = (item.representedObject as? PetPose)?.id == pose.id ? .on : .off
        }
    }

    @objc private func speakNow() {
        director.clearDialogue()
        director.speakLyrics()
    }

    @objc private func toggleAutoChat() {
        Prefs.autoChat.toggle()
        menu.item(withTitle: "自动闲聊")?.state = Prefs.autoChat ? .on : .off
        director.clearDialogue(restartOpera: Prefs.autoChat)
        sayInCurrentMode(Script.autoChatLine(enabled: Prefs.autoChat, mode: mode), preferred: .hua)
    }

    @objc private func togglePlatform(_ sender: NSMenuItem) {
        let cases = AgentPlatform.allCases
        guard cases.indices.contains(sender.tag) else { return }
        let platform = cases[sender.tag]
        var platforms = Prefs.linkedPlatforms
        if platforms.remove(platform) == nil {
            if platform == .doubao && !confirmDoubaoLink() { return }
            platforms.insert(platform)
        }
        setLinkedPlatforms(platforms)
    }

    @objc private func toggleAllPlatforms() {
        setLinkedPlatforms(Prefs.linkedPlatforms.isEmpty ? Prefs.standardLinkedPlatforms : [])
    }

    private func setLinkedPlatforms(_ platforms: Set<AgentPlatform>) {
        do {
            if Prefs.linkedPlatforms.contains(.trae) != platforms.contains(.trae) {
                try traeBridge.setEnabled(platforms.contains(.trae))
            }
        } catch {
            showLinkError("无法更新 TRAE 联动", error: error)
            return
        }
        Prefs.linkedPlatforms = platforms
        director.clearDialogue()
        watcher.start(platforms: platforms)
    }

    @objc private func configureTrae() {
        guard let executable = Bundle.main.executableURL else { return }
        let alert = NSAlert()
        alert.messageText = "配置 TRAE 联动"
        alert.informativeText = "这会在 TRAE 国内版配置中添加本地 Hooks，并安装辅助程序。桌宠开启联动时，辅助程序会把会话状态写入本机。可在此菜单移除联动。"
        alert.addButton(withTitle: "配置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = NSAlert()
        do {
            try traeBridge.install(executable: executable)
            try traeBridge.setEnabled(true)
            setLinkedPlatforms(Prefs.linkedPlatforms.union([.trae]))
            result.messageText = "TRAE 联动已配置"
            result.informativeText = "请在 TRAE「设置 → Hooks」启用相关 Hooks，再发送一条消息。"
        } catch {
            result.messageText = "配置 TRAE 联动失败"
            result.informativeText = "请检查 ~/.trae-cn/hooks.json 的 JSON 格式和访问权限。\n\(error.localizedDescription)"
        }
        result.runModal()
    }

    @objc private func removeTrae() {
        let alert = NSAlert()
        alert.messageText = "移除 TRAE 联动"
        alert.informativeText = "从 TRAE 配置移除花妖桌宠添加的 Hooks，并删除桌宠的辅助程序。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try traeBridge.uninstall()
            setLinkedPlatforms(Prefs.linkedPlatforms.subtracting([.trae]))
        } catch {
            showLinkError("无法移除 TRAE 联动", error: error)
        }
    }

    @objc private func configureAntigravityLink() {
        guard let executable = Bundle.main.executableURL else { return }
        let alert = NSAlert()
        alert.messageText = "配置 Antigravity 联动"
        alert.informativeText = "在 Antigravity 的全局配置中添加花妖 Hooks，在本机显示工作区和各会话的进度。"
        alert.addButton(withTitle: "配置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AntigravityBridge().install(executable: executable)
            setLinkedPlatforms(Prefs.linkedPlatforms.union([.antigravity]))
            sayInCurrentMode("Antigravity 已配置，等它开始处理任务。", preferred: .hua)
        } catch {
            showLinkError("无法配置 Antigravity 联动", error: error)
        }
    }

    @objc private func removeAntigravityLink() {
        do {
            try AntigravityBridge().uninstall()
            setLinkedPlatforms(Prefs.linkedPlatforms.subtracting([.antigravity]))
        } catch {
            showLinkError("无法移除 Antigravity 联动", error: error)
        }
    }

    private func showLinkError(_ title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func confirmDoubaoLink() -> Bool {
        let alert = NSAlert()
        alert.messageText = "开启豆包联动"
        alert.informativeText = "桌宠需要 macOS 辅助功能权限。豆包在前台时，桌宠会读取当前普通对话的可访问文本，在本机内存中比较变化来判断是否正在回复。你可以随时关闭联动，并在系统设置中撤销权限。"
        alert.addButton(withTitle: "开启联动")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func sayInCurrentMode(_ text: String, preferred: Speaker) {
        switch mode {
        case .hua: say(.hua, text)
        case .sheng: say(.sheng, text)
        case .duo: say(preferred, text)
        }
    }

    @objc private func togglePetals() {
        guard let petals else { return }
        petals.isEnabled.toggle()
        menu.item(withTitle: "花瓣飘落")?.state = petals.isEnabled ? .on : .off
    }

    @objc private func zoomIn() { applyScale(currentScale + 0.1) }
    @objc private func zoomOut() { applyScale(currentScale - 0.1) }
    @objc private func zoomReset() { applyScale(1.0) }

    @objc private func moveToCorner() {
        guard let window, let screen = NSScreen.main?.visibleFrame else { return }
        let s = window.frame.size
        window.setFrameOrigin(NSPoint(x: screen.maxX - s.width - 40, y: screen.minY + 30))
        updateMirroring(on: screen)
        Prefs.windowOrigin = window.frame.origin
    }

    @objc private func toggleAlwaysOnTop() {
        guard let window else { return }
        interaction.alwaysOnTop.toggle()
        interaction.save()
        window.level = interaction.alwaysOnTop ? .floating : .normal
        menu.item(withTitle: "始终置顶")?.state = interaction.alwaysOnTop ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: 桌宠交互

extension PetController {
    private func appendInteractionMenu(to menu: NSMenu) {
        let item = NSMenuItem(title: "互动设置", action: nil, keyEquivalent: "")
        let settings = NSMenu()
        item.submenu = settings
        func add(_ title: String, _ action: Selector, to targetMenu: NSMenu) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            targetMenu.addItem(entry)
            return entry
        }
        _ = add("拖动与吸边…", #selector(editDocking), to: settings)
        _ = add("提示音…", #selector(editSounds), to: settings)
        let poseToggle = add("随状态切换姿态", #selector(toggleStatusPoses(_:)), to: settings)
        poseToggle.state = interaction.statusPoses ? .on : .off

        let bubbleEntry = NSMenuItem(title: "气泡设置", action: nil, keyEquivalent: "")
        let bubbleMenu = NSMenu()
        bubbleEntry.submenu = bubbleMenu
        settings.addItem(bubbleEntry)
        for event in PetBubbleEvent.allCases {
            let entry = add("\(event.title)…", #selector(editBubble(_:)), to: bubbleMenu)
            entry.representedObject = event.rawValue
        }
        menu.addItem(item)
        _ = add("隐藏桌宠", #selector(togglePetVisibility(_:)), to: menu)
    }

    @objc private func togglePetVisibility(_ item: NSMenuItem) {
        if window.isVisible {
            Prefs.windowOrigin = window.frame.origin
            director.clearDialogue()
            bubbleTimer?.invalidate()
            bubble.alphaValue = 0
            isTaskBubble = false
            window.orderOut(nil)
            item.title = "显示桌宠"
        } else {
            placeWindow()
            window.orderFrontRegardless()
            item.title = "隐藏桌宠"
            showPendingBalanceWarning()
        }
    }

    @MainActor @objc private func editDocking() {
        guard let settings = interactionDialogs.editDocking(interaction.docking) else { return }
        interaction.docking = settings
        interaction.save()
        guard let screen = window.screen?.visibleFrame else { return }
        updateMirroring(on: screen)
    }

    @MainActor @objc private func editSounds() {
        guard let settings = interactionDialogs.editAudio(interaction) else { return }
        interaction.sounds = settings
        interaction.save()
    }

    @objc private func toggleStatusPoses(_ item: NSMenuItem) {
        interaction.statusPoses.toggle()
        interaction.save()
        item.state = interaction.statusPoses ? .on : .off
        updateFeedbackPose()
    }

    @MainActor @objc private func editBubble(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String, let event = PetBubbleEvent(rawValue: key),
              let settings = interactionDialogs.editBubble(event, current: interaction.bubbles) else { return }
        interaction.bubbles = settings
        interaction.save()
        if event == .tap { tapLineIndex = 0 }
    }

    private func updateMirroring(on screen: NSRect) {
        let nearLeft = abs(window.frame.minX - screen.minX) <= max(1, interaction.docking.distance(for: .left))
        scene.mirrored = interaction.docking.mirrorOnLeft && nearLeft
    }

    private func playPetSound(_ event: PetSound) {
        guard window.isVisible else { return }
        soundPlayer.play(event, settings: interaction.sound(event))
    }

    private func handlePetTap() {
        billing.refreshFromPet()
        playPetSound(.tap)

        let settings = interaction.bubbles
        let lines = settings.lines[PetBubbleEvent.tap.rawValue] ?? []
        let image = settings.image(for: .tap)
        let link = settings.link(for: .tap)
        if lines.isEmpty, image == nil, link == nil {
            director.tapped()
            return
        }
        director.clearDialogue()
        var text = ""
        if !lines.isEmpty {
            text = settings.randomTap ? lines.randomElement() ?? "" : lines[tapLineIndex % lines.count]
            tapLineIndex = (tapLineIndex + 1) % lines.count
        }
        say(mode == .sheng ? .sheng : .hua, text, image: image, duration: Double(settings.duration(for: .tap)), link: link)
    }

    private func updateFeedbackPose() {
        guard interaction.statusPoses else {
            if scene.feedbackPose != nil { scene.feedbackPose = nil }
            return
        }
        let ids: (String, String, String)?
        switch scene.activity {
        case .thinking: ids = ("D02", "H02", "S02")
        case .working: ids = ("D10", "H04", "S03")
        case .waiting: ids = ("D11", "H09", "S04")
        case .done: ids = ("D01", "H12", "S01")
        case .error: ids = ("D16", "H06", "S02")
        case .offline, .idle, .cancelled:
            ids = scene.lowBalance ? ("D16", "H06", "S02") : nil
        }
        let id = ids.map { mode == .duo ? $0.0 : mode == .hua ? $0.1 : $0.2 }
        let pose = id.flatMap { wanted in Assets.shared.poses(for: mode).first { $0.id == wanted } }
        if scene.feedbackPose?.id != pose?.id { scene.feedbackPose = pose }
    }

    private func waitEvent(for status: AgentStatus) -> PetBubbleEvent {
        status.waitKind == .question ? .question : .approval
    }

    @discardableResult
    private func sayBubble(_ event: PetBubbleEvent, values: [String: String] = [:], fallback: String? = nil,
                           isTask: Bool = false) -> Bool {
        let text = interaction.bubbles.text(for: event, values: values) ?? fallback
        let image = interaction.bubbles.image(for: event)
        let link = interaction.bubbles.link(for: event)
        guard text != nil || image != nil || link != nil else { return false }
        say(mode == .sheng ? .sheng : .hua, text ?? "", isTask: isTask, image: image,
            duration: Double(interaction.bubbles.duration(for: event)), link: link)
        return true
    }

    func showTurnCost(_ cost: String, model: String = "") {
        guard window.isVisible else { return }
        playPetSound(.cost)
        guard scene.activity != .waiting else { return }
        sayBubble(.cost, values: ["cost": cost, "model": model], fallback: "本轮消耗 \(cost)", isTask: true)
    }

    func showBudgetWarning(_ amount: String) {
        guard window.isVisible, scene.activity != .waiting else { return }
        sayBubble(.budget, values: ["amount": amount], fallback: "今日用量已达预算 \(amount)。", isTask: true)
    }

    func setBalanceWarning(_ isLow: Bool, balance: String = "") {
        if isLow && !scene.lowBalance { balanceNoticePending = true }
        if !isLow { balanceNoticePending = false }
        scene.lowBalance = isLow
        lowBalanceText = balance
        updateFeedbackPose()
        showPendingBalanceWarning()
    }

    private func showPendingBalanceWarning() {
        guard balanceNoticePending, window.isVisible, !scene.activity.isBusy, !isTaskBubble else { return }
        balanceNoticePending = false
        let message = lowBalanceText.isEmpty ? "账户余额低于预警线。" : "账户余额偏低 · \(lowBalanceText)"
        sayBubble(.warning, values: ["balance": lowBalanceText], fallback: message, isTask: true)
    }
}

// MARK: - 状态药丸

final class StatusPill: NSView {
    private let dot = NSView()
    private var label: NSTextField!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: 0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(srgbRed: 0.82, green: 0.76, blue: 0.65, alpha: 0.5).cgColor

        dot.frame = NSRect(x: 7, y: 6, width: 8, height: 8)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        addSubview(dot)

        label = NSTextField(labelWithString: "离线")
        label.font = Fonts.ui(10, .medium)
        label.textColor = Palette.inkSoft
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 20, y: 3, width: frame.width - 26, height: 14)
        addSubview(label)
        update(AgentStatus(), summary: "AI 联动 · 等待会话")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ s: AgentStatus, summary: String) {
        let detail = s.state == .working && !s.detailLine.isEmpty ? "\(summary) · \(s.detailLine)" : summary
        let color: NSColor
        switch s.state {
        case .thinking: color = Palette.gold
        case .working:  color = Palette.cinnabar
        case .waiting:  color = Palette.gold
        case .done:     color = NSColor(srgbRed: 0.25, green: 0.62, blue: 0.35, alpha: 1)
        case .cancelled: color = Palette.inkSoft
        case .error:    color = NSColor(srgbRed: 0.82, green: 0.30, blue: 0.22, alpha: 1)
        case .idle:     color = Palette.jade
        case .offline:  color = NSColor(srgbRed: 0.55, green: 0.52, blue: 0.48, alpha: 1)
        }
        dot.layer?.backgroundColor = color.cgColor
        label.stringValue = detail
        label.toolTip = detail
        if !s.state.isBusy {
            dot.layer?.removeAnimation(forKey: "pulse")
        } else if dot.layer?.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = 0.25
            a.duration = 0.9
            a.autoreverses = true
            a.repeatCount = .infinity
            dot.layer?.add(a, forKey: "pulse")
        }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 20, y: (bounds.height - 14) / 2, width: bounds.width - 26, height: 14)
        dot.frame = NSRect(x: 7, y: (bounds.height - 8) / 2, width: 8, height: 8)
    }
}
