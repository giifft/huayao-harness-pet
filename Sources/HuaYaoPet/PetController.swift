import AppKit
import QuartzCore

// MARK: - 控制器

final class PetController: NSObject, NSApplicationDelegate {
    private var window: PetWindow!
    private var scene: PetSceneView!
    private var petals: PetalView!
    private var bubble: BubbleView!
    private var statusPill: StatusPill!
    private var director = Director()
    private let watcher = AgentWatcher()
    private let traeBridge = TraeBridge(home: FileManager.default.homeDirectoryForCurrentUser)
    private var statusItem: NSStatusItem!
    private var bubbleTimer: Timer?
    private var currentScale: CGFloat = 1
    private var menu: NSMenu!
    private let linkMenu = NSMenu(title: "AI 联动")
    private var linkItem: NSMenuItem!
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

        scene.startIdle()
        director.start()
        watcher.onChange = { [weak self] s in
            self?.applyActivity(s)
        }
        do {
            if let executable = Bundle.main.executableURL {
                try traeBridge.updateInstalledHelper(from: executable)
            }
            try traeBridge.setEnabled(Prefs.linkedPlatforms.contains(.trae))
        } catch {
            showTraeError("无法更新 TRAE 联动", error: error)
        }
        watcher.start(platforms: Prefs.linkedPlatforms)
        director.showWelcome()

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
        director.stop()
        watcher.stop()
        scene.stopIdle()
        if let o = window?.frame.origin { Prefs.windowOrigin = o }
    }

    // MARK: 构建界面

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 420, height: 320)
        window = PetWindow(contentRect: rect)

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
        root.addSubview(bubble)

        statusPill = StatusPill(frame: NSRect(x: 8, y: 4, width: 120, height: 20))
        root.addSubview(statusPill)

        scene.onClick = { [weak self] in
            self?.scene.hopOnce()
            self?.director.tapped()
        }
        scene.onDragEnded = { [weak self] in
            guard let self, let screen = self.window.screen else { return }
            let frame = self.fitted(self.window.frame, to: screen.visibleFrame)
            self.window.setFrameOrigin(frame.origin)
            Prefs.windowOrigin = frame.origin
        }
        scene.onZoom = { [weak self] delta in
            guard let self else { return }
            self.applyScale(self.currentScale + delta)
        }

        window.orderFrontRegardless()
    }

    private func buildMenu() {
        let m = NSMenu()
        linkItem = NSMenuItem(title: "AI 联动", action: nil, keyEquivalent: "")
        linkItem.submenu = linkMenu
        m.addItem(linkItem)
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
        top.state = .on
        m.addItem(top)

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
        director.onSay = { [weak self] line in
            self?.say(line.speaker, line.text)
        }
    }

    // MARK: 尺寸与位置

    private func applyScale(_ scale: CGFloat) {
        currentScale = scale.clamped(0.7, 1.6)
        Prefs.scale = Double(currentScale)
        relayout(keepOnScreen: true)
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
            frame = fitted(frame, to: screen.visibleFrame)
        }
        window.setFrame(frame, display: true)
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
                                      maxTextWidth: maxTextW)
        let w = min(size.width, cw - 8)
        let h = size.height
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
    }

    private func overlap(_ frame: NSRect, _ screen: NSRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        return intersection.width * intersection.height
    }

    private func fitted(_ frame: NSRect, to screen: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = frame.minX.clamped(screen.minX, max(screen.minX, screen.maxX - frame.width))
        frame.origin.y = frame.minY.clamped(screen.minY, max(screen.minY, screen.maxY - frame.height))
        return frame
    }

    // MARK: 说话

    private func say(_ who: Speaker, _ text: String) {
        guard let bubble else { return }
        bubble.speaker = who.name
        bubble.text = text
        layoutBubble()
        bubble.animator().alphaValue = 1

        bubbleTimer?.invalidate()
        let t = Timer(timeInterval: 3.2, repeats: false) { [weak self] _ in
            self?.bubble.animator().alphaValue = 0
        }
        RunLoop.main.add(t, forMode: .common)
        bubbleTimer = t
    }

    // MARK: AI 联动

    private func applyActivity(_ statuses: [AgentPlatform: AgentStatus]) {
        let platforms = Prefs.linkedPlatforms
        let activities = AgentPlatform.allCases.compactMap { platform in
            statuses[platform].map { AgentActivity(platform: platform, status: $0) }
        }
        for platform in AgentPlatform.allCases {
            let item = platformItems[platform]
            let status = statuses[platform]
            let text = status.map { $0.state == .offline ? $0.detailLine : $0.state.title } ?? "已关闭"
            item?.title = "\(platform.name) · \(text)"
            item?.state = platforms.contains(platform) ? .on : .off
            item?.toolTip = status?.detailLine
        }
        linkMenu.items.last?.title = platforms.isEmpty ? "开启常规联动" : "关闭全部联动"

        let selected = activities.filter { $0.status.state != .offline }.max {
            let lhs = $0.status
            let rhs = $1.status
            if lhs.state.priority != rhs.state.priority { return lhs.state.priority < rhs.state.priority }
            return lhs.lastActivity < rhs.lastActivity
        }
        let summary: String
        if let selected {
            summary = "\(selected.platform.shortName) · \(selected.status.state.title)"
        } else {
            summary = platforms.isEmpty ? "AI 联动已关闭" : "AI 联动 · 等待会话"
        }
        linkItem.title = "AI 联动  ·  \(activities.filter { $0.status.state != .offline }.count)/\(AgentPlatform.allCases.count)"
        statusItem.button?.toolTip = summary
        statusPill.update(selected?.status ?? AgentStatus(), summary: summary)
        director.activityChanged(selected)
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
        relayout()
        updateModeMenuState()
        scene.hopOnce()

        if announce {
            let who: Speaker = newMode == .sheng ? .sheng : .hua
            say(who, Script.modeIntro(newMode))
        }
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
        let who: Speaker
        let pool: [String]
        switch mode {
        case .hua:
            who = .hua
            pool = Bool.random() ? Script.soloHua : Script.idleLines(for: .hua)
        case .sheng:
            who = .sheng
            pool = Bool.random() ? Script.soloSheng : Script.idleLines(for: .sheng)
        case .duo:
            who = Bool.random() ? .hua : .sheng
            pool = Script.idleLines(for: who)
        }
        say(who, pool.randomElement() ?? "……")
        scene.hopOnce()
    }

    @objc private func toggleAutoChat() {
        Prefs.autoChat.toggle()
        menu.item(withTitle: "自动闲聊")?.state = Prefs.autoChat ? .on : .off
        director.clearDialogue()
        sayInCurrentMode(Prefs.autoChat ? "好，我们接着说。" : "那我们安静些。", preferred: .hua)
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
            showTraeError("无法更新 TRAE 联动", error: error)
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
            showTraeError("无法移除 TRAE 联动", error: error)
        }
    }

    private func showTraeError(_ title: String, error: Error) {
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
        Prefs.windowOrigin = window.frame.origin
    }

    @objc private func toggleAlwaysOnTop() {
        guard let window else { return }
        if window.level == .floating {
            window.level = .normal
            menu.item(withTitle: "始终置顶")?.state = .off
        } else {
            window.level = .floating
            menu.item(withTitle: "始终置顶")?.state = .on
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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

    func update(_ s: AgentStatus, summary: String) {
        let detail = s.toolDetail.isEmpty ? summary : "\(summary) · \(s.toolDetail)"
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
