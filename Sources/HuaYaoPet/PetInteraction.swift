import AppKit
import ImageIO
import UniformTypeIdentifiers

enum PetSound: String, CaseIterable {
    case tap, cost, question, approval, land

    static let configurable: [PetSound] = [.tap, .cost, .question, .approval]

    var title: String {
        switch self {
        case .tap: return "点击和落地"
        case .cost: return "每轮结算"
        case .question: return "等待回答"
        case .approval: return "等待授权"
        case .land: return "落地"
        }
    }

    var preference: PetSound { self == .land ? .tap : self }
}

struct PetSoundSetting: Codable {
    var enabled = false
    var volume: Float = 0.45
}

enum PetEdge: String, CaseIterable {
    case left, right, top, bottom

    var title: String {
        switch self {
        case .left: return "左边"
        case .right: return "右边"
        case .top: return "上边"
        case .bottom: return "下边"
        }
    }
}

struct PetDockingSettings: Codable {
    var distances: [String: Int] = [:]
    var mirrorOnLeft = false

    func distance(for edge: PetEdge) -> CGFloat {
        CGFloat(max(0, min(120, distances[edge.rawValue] ?? 22)))
    }

    /// Clamp to the screen's usable area first, then independently snap each axis.
    func place(_ frame: NSRect, on screen: NSRect, snap: Bool) -> NSRect {
        let left = screen.minX
        let right = max(left, screen.maxX - frame.width)
        let bottom = screen.minY
        let top = max(bottom, screen.maxY - frame.height)
        var result = frame
        result.origin.x = frame.minX.clamped(left, right)
        result.origin.y = frame.minY.clamped(bottom, top)
        guard snap else { return result }

        func snapped(_ value: CGFloat, lower: CGFloat, upper: CGFloat,
                     lowerEdge: PetEdge, upperEdge: PetEdge) -> CGFloat {
            let lowDistance = value - lower
            let highDistance = upper - value
            let lowEnabled = distance(for: lowerEdge) > 0 && lowDistance <= distance(for: lowerEdge)
            let highEnabled = distance(for: upperEdge) > 0 && highDistance <= distance(for: upperEdge)
            if lowEnabled && (!highEnabled || lowDistance <= highDistance) { return lower }
            return highEnabled ? upper : value
        }

        result.origin.x = snapped(result.minX, lower: left, upper: right, lowerEdge: .left, upperEdge: .right)
        result.origin.y = snapped(result.minY, lower: bottom, upper: top, lowerEdge: .bottom, upperEdge: .top)
        return result
    }
}

enum PetBubbleEvent: String, CaseIterable {
    case tap, idle, question, approval, cost, warning, budget

    var title: String {
        switch self {
        case .tap: return "点击"
        case .idle: return "待机"
        case .question: return "等待回答"
        case .approval: return "等待授权"
        case .cost: return "每轮结算"
        case .warning: return "余额预警"
        case .budget: return "预算提醒"
        }
    }

    var placeholders: String {
        switch self {
        case .tap, .idle: return "每行一条，留空使用花妖内置台词。"
        case .question, .approval: return "可用 {task} 显示任务名称。每行一条。"
        case .cost: return "可用 {cost} 显示费用，{model} 显示模型。每行一条。"
        case .warning: return "可用 {balance} 显示余额。每行一条。"
        case .budget: return "可用 {amount} 显示今日金额。每行一条。"
        }
    }
}

struct PetBubbleSettings: Codable {
    var lines: [String: [String]] = [:]
    var images: [String: Data] = [:]
    var randomTap = false
    var imageAboveText: Bool?
    var seconds: [String: Int]?
    var links: [String: String]?

    func duration(for event: PetBubbleEvent) -> Int { seconds?[event.rawValue] ?? 4 }
    func link(for event: PetBubbleEvent) -> URL? { Self.webLink(links?[event.rawValue] ?? "") }

    static func webLink(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    func text(for event: PetBubbleEvent, values: [String: String] = [:]) -> String? {
        guard let template = lines[event.rawValue]?.randomElement() else { return nil }
        return render(template, values: values)
    }

    func render(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { text, entry in
            text.replacingOccurrences(of: "{\(entry.key)}", with: entry.value)
        }
    }

    func image(for event: PetBubbleEvent) -> NSImage? {
        images[event.rawValue].flatMap(NSImage.init(data:))
    }
}

struct PetInteractionSettings: Codable {
    var docking = PetDockingSettings()
    var sounds: [String: PetSoundSetting] = [:]
    var bubbles = PetBubbleSettings()
    var statusPoses = true
    var alwaysOnTop = true

    func sound(_ event: PetSound) -> PetSoundSetting {
        sounds[event.preference.rawValue] ?? PetSoundSetting()
    }

    static func load() -> Self {
        guard let bytes = UserDefaults.standard.data(forKey: "petInteraction.v1"),
              let values = try? JSONDecoder().decode(Self.self, from: bytes) else { return Self() }
        return values
    }

    func save() {
        if let bytes = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(bytes, forKey: "petInteraction.v1")
        }
    }
}

final class PetSoundPlayer {
    private var playing: [PetSound: NSSound] = [:]

    func play(_ event: PetSound, settings: PetSoundSetting) {
        guard settings.enabled, settings.volume > 0,
              let url = Bundle.main.url(forResource: event.rawValue, withExtension: "wav", subdirectory: "PetSounds"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        playing[event]?.stop()
        sound.volume = max(0, min(1, settings.volume))
        playing[event] = sound
        sound.play()
    }
}

@MainActor
final class PetInteractionDialogs: NSObject {
    private let soundPlayer: PetSoundPlayer
    private var soundSliders: [PetSound: NSSlider] = [:]

    init(soundPlayer: PetSoundPlayer) { self.soundPlayer = soundPlayer }

    func editDocking(_ current: PetDockingSettings) -> PetDockingSettings? {
        let alert = makeAlert("拖动与吸边", "数值为距屏幕工作区边缘的点数，填 0 可关闭该边吸附。")
        let fields = Dictionary(uniqueKeysWithValues: PetEdge.allCases.map { edge in
            let input = NSTextField(string: String(Int(current.distance(for: edge))))
            input.alignment = .right
            return (edge, input)
        })
        let mirror = NSButton(checkboxWithTitle: "靠左时镜像单人立绘", target: nil, action: nil)
        mirror.state = current.mirrorOnLeft ? .on : .off
        let rows = PetEdge.allCases.compactMap { edge -> [NSView]? in
            guard let input = fields[edge] else { return nil }
            return [NSTextField(labelWithString: edge.title), input]
        } + [[NSView(), mirror]]
        for field in fields.values { field.widthAnchor.constraint(equalToConstant: 62).isActive = true }
        alert.accessoryView = grid(rows)
        while alert.runModal() == .alertFirstButtonReturn {
            var new = current
            let valid = fields.compactMap { edge, field -> (String, Int)? in
                guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
                      (0...120).contains(value) else { return nil }
                return (edge.rawValue, value)
            }
            guard valid.count == fields.count else {
                alert.informativeText = "每个边的距离须为 0 到 120 之间的整数。"
                continue
            }
            new.distances = Dictionary(uniqueKeysWithValues: valid)
            new.mirrorOnLeft = mirror.state == .on
            return new
        }
        return nil
    }

    func editAudio(_ current: PetInteractionSettings) -> [String: PetSoundSetting]? {
        let alert = makeAlert("提示音", "分别设置每类事件的开关和音量。")
        var buttons: [PetSound: NSButton] = [:]
        let rows = PetSound.configurable.enumerated().map { index, event -> [NSView] in
            let setting = current.sound(event)
            let button = NSButton(checkboxWithTitle: event.title, target: nil, action: nil)
            button.state = setting.enabled ? .on : .off
            let slider = NSSlider(value: Double(setting.volume), minValue: 0, maxValue: 1, target: nil, action: nil)
            slider.widthAnchor.constraint(equalToConstant: 138).isActive = true
            slider.setAccessibilityLabel("\(event.title)音量")
            let preview = NSButton(title: "试听", target: self, action: #selector(previewAudio(_:)))
            preview.tag = index
            buttons[event] = button
            soundSliders[event] = slider
            return [button, slider, preview]
        }
        alert.accessoryView = grid(rows)
        defer { soundSliders.removeAll() }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Dictionary(uniqueKeysWithValues: PetSound.configurable.map { event in
            (event.rawValue, PetSoundSetting(enabled: buttons[event]?.state == .on,
                                             volume: soundSliders[event]?.floatValue ?? 0.45))
        })
    }

    @objc private func previewAudio(_ sender: NSButton) {
        let event = PetSound.configurable[sender.tag]
        soundPlayer.play(event, settings: PetSoundSetting(enabled: true, volume: soundSliders[event]?.floatValue ?? 0.45))
    }

    func editBubble(_ event: PetBubbleEvent, current: PetBubbleSettings) -> PetBubbleSettings? {
        let alert = makeAlert("\(event.title)气泡", event.placeholders)
        let editor = PetBubbleEditor(lines: current.lines[event.rawValue] ?? [],
                                     image: current.images[event.rawValue],
                                     imageAboveText: current.imageAboveText == true,
                                     showMode: event == .tap, random: current.randomTap,
                                     duration: current.duration(for: event),
                                     link: current.link(for: event)?.absoluteString ?? "")
        alert.accessoryView = editor
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let duration = Int(editor.duration.stringValue), (0...60).contains(duration) else {
            let warning = NSAlert()
            warning.messageText = "请输入 0 至 60 秒。"
            warning.runModal()
            return nil
        }
        let link = editor.link.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.isEmpty || PetBubbleSettings.webLink(link) != nil else {
            let warning = NSAlert()
            warning.messageText = "链接须使用 HTTPS。"
            warning.runModal()
            return nil
        }
        var settings = current
        settings.lines[event.rawValue] = editor.lines
        settings.images[event.rawValue] = editor.image
        settings.imageAboveText = editor.imageAboveText.state == .on
        var seconds = settings.seconds ?? [:]
        seconds[event.rawValue] = duration
        settings.seconds = seconds
        var links = settings.links ?? [:]
        links[event.rawValue] = link.isEmpty ? nil : link
        settings.links = links
        if event == .tap { settings.randomTap = editor.random.state == .on }
        return settings
    }

    private func makeAlert(_ title: String, _ detail: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert
    }

    private func grid(_ rows: [[NSView]]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        grid.xPlacement = .leading
        grid.frame.size = grid.fittingSize
        return grid
    }
}

@MainActor
private final class PetBubbleEditor: NSView {
    private let textView = NSTextView()
    private let imageLabel = NSTextField(labelWithString: "")
    let random = NSButton(checkboxWithTitle: "点击时随机抽取台词", target: nil, action: nil)
    let imageAboveText = NSButton(checkboxWithTitle: "所有气泡的图片置于文字上方", target: nil, action: nil)
    let duration = NSTextField(string: "")
    let link = NSTextField(string: "")
    private(set) var image: Data? {
        didSet { updateImageLabel() }
    }

    init(lines: [String], image: Data?, imageAboveText: Bool, showMode: Bool, random: Bool, duration: Int, link: String) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: showMode ? 233 : 207))
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = lines.joined(separator: "\n")
        textView.font = .systemFont(ofSize: 13)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 33, width: 320, height: 88))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.setFrameSize(scroll.contentSize)
        addSubview(scroll)

        let pick = NSButton(title: "选择图片…", target: self, action: #selector(chooseImage))
        let clear = NSButton(title: "移除图片", target: self, action: #selector(removeImage))
        pick.frame = NSRect(x: 0, y: 2, width: 89, height: 27)
        clear.frame = NSRect(x: 90, y: 2, width: 80, height: 27)
        imageLabel.frame = NSRect(x: 175, y: 8, width: 145, height: 17)
        addSubview(pick)
        addSubview(clear)
        addSubview(imageLabel)
        self.imageAboveText.state = imageAboveText ? .on : .off
        self.imageAboveText.frame = NSRect(x: 0, y: 126, width: 320, height: 20)
        addSubview(self.imageAboveText)
        let durationLabel = NSTextField(labelWithString: "关闭秒数（0 为手动）")
        durationLabel.frame = NSRect(x: 0, y: 153, width: 200, height: 19)
        self.duration.frame = NSRect(x: 204, y: 151, width: 60, height: 23)
        self.duration.stringValue = String(duration)
        addSubview(durationLabel)
        addSubview(self.duration)
        self.link.placeholderString = "可选 HTTPS 链接"
        self.link.stringValue = link
        self.link.frame = NSRect(x: 0, y: 180, width: 320, height: 23)
        addSubview(self.link)
        if showMode {
            self.random.state = random ? .on : .off
            self.random.frame = NSRect(x: 0, y: 209, width: 320, height: 20)
            addSubview(self.random)
        }
        updateImageLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    var lines: [String] {
        Array(textView.string.split(whereSeparator: \.isNewline)
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(120)) }
            .filter { !$0.isEmpty }.prefix(30))
    }

    @objc private func chooseImage() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .webP]
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = Self.thumbnail(url) else {
                self?.imageLabel.stringValue = "无法读取此图片"
                return
            }
            self?.image = data
        }
    }

    @objc private func removeImage() { image = nil }

    private func updateImageLabel() {
        imageLabel.stringValue = image == nil ? "未附加图片" : "已附加图片"
    }

    private static func thumbnail(_ url: URL) -> Data? {
        guard let metadata = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              metadata.isRegularFile == true, let size = metadata.fileSize, size <= 20_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 220
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:])
    }
}
