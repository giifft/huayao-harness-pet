import AppKit
import QuartzCore

// MARK: - 花瓣

struct Petal {
    var x: CGFloat          // 0…1 相对宽度
    var y: CGFloat          // 0…1 相对高度，向下飘落
    var vx: CGFloat
    var vy: CGFloat
    var size: CGFloat       // 直径
    var spin: CGFloat
    var spinSpeed: CGFloat
    var alpha: CGFloat
    var tone: CGFloat       // 0 深粉 1 浅粉
    var phase: CGFloat
}

/// 飘落花瓣层，垫在人物后面
final class PetalView: NSView {
    private var petals: [Petal] = []
    private var timer: Timer?
    private var last: CFTimeInterval = CACurrentMediaTime()
    var intensity: Double = 0.5 { didSet { spawnIfNeeded() } }
    var isEnabled: Bool = true { didSet { isHidden = !isEnabled } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        seed()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    private func seed() {
        petals = (0..<26).map { _ in makePetal(anywhere: true) }
    }

    private func makePetal(anywhere: Bool) -> Petal {
        Petal(
            x: CGFloat.random(in: -0.05...1.05),
            y: anywhere ? CGFloat.random(in: 0...1.15) : CGFloat.random(in: 1.02...1.20),
            vx: CGFloat.random(in: (-0.035)...0.045),
            vy: CGFloat.random(in: (-0.055)...(-0.018)),
            size: CGFloat.random(in: 5...13),
            spin: CGFloat.random(in: 0...(.pi * 2)),
            spinSpeed: CGFloat.random(in: -0.9...0.9),
            alpha: CGFloat.random(in: 0.35...0.85),
            tone: CGFloat.random(in: 0...1),
            phase: CGFloat.random(in: 0...(.pi * 2))
        )
    }

    private func spawnIfNeeded() {
        let target = Int(10 + intensity * 26)
        while petals.count < target { petals.append(makePetal(anywhere: false)) }
        while petals.count > target { petals.removeLast() }
    }

    private func tick() {
        guard !isHidden, window != nil else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.1)
        last = now

        let t = CGFloat(now)
        for i in petals.indices {
            var p = petals[i]
            p.x += p.vx * CGFloat(dt) + sin(t * 1.3 + p.phase) * 0.0016
            p.y += p.vy * CGFloat(dt)
            p.spin += p.spinSpeed * CGFloat(dt)
            if p.y < -0.1 || p.x < -0.15 || p.x > 1.15 {
                petals[i] = makePetal(anywhere: false)
            } else {
                petals[i] = p
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        ctx.setShouldAntialias(true)

        for p in petals {
            let cx = p.x * w
            let cy = p.y * h
            let s = p.size
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: p.spin)
            ctx.scaleBy(x: 1, y: 0.62)

            let top = NSColor(srgbRed: 0.98, green: 0.72 + 0.18 * p.tone, blue: 0.76 + 0.16 * p.tone, alpha: 1)
            let bottom = NSColor(srgbRed: 0.95, green: 0.56 + 0.20 * p.tone, blue: 0.62 + 0.18 * p.tone, alpha: 1)
            let path = CGMutablePath()
            // 一片花瓣：两个对称的弧
            path.move(to: CGPoint(x: 0, y: -s * 0.5))
            path.addCurve(to: CGPoint(x: 0, y: s * 0.5),
                          control1: CGPoint(x: s * 0.85, y: -s * 0.18),
                          control2: CGPoint(x: s * 0.62, y: s * 0.42))
            path.addCurve(to: CGPoint(x: 0, y: -s * 0.5),
                          control1: CGPoint(x: -s * 0.62, y: s * 0.42),
                          control2: CGPoint(x: -s * 0.85, y: -s * 0.18))
            ctx.addPath(path)
            ctx.clip()

            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s * 0.5),
                                       end: CGPoint(x: 0, y: -s * 0.5), options: [])
            }
            ctx.restoreGState()

            // 半透明柔化
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: p.spin)
            ctx.scaleBy(x: 1, y: 0.62)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(srgbRed: 1, green: 0.98, blue: 0.97, alpha: p.alpha * 0.18).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}

// MARK: - 对话气泡

final class BubbleView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let artwork = NSImageView()
    private let linkLabel = NSTextField(labelWithString: "打开链接 ↗")
    private var accent: NSColor = Palette.cinnabar

    var onHit: (() -> Void)?
    var imageAboveText = false { didSet { needsLayout = true } }
    var link: URL? { didSet { linkLabel.isHidden = link == nil; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        nameLabel.font = Fonts.kai(11)
        nameLabel.textColor = Palette.inkSoft
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        addSubview(nameLabel)

        label.font = Fonts.kai(14)
        label.textColor = Palette.ink
        label.isBordered = false
        label.drawsBackground = false
        // 中文按字符换行；不设行数上限，长台词必须完整显示
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 210
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        addSubview(label)
        artwork.imageScaling = .scaleProportionallyDown
        artwork.isHidden = true
        addSubview(artwork)
        linkLabel.isHidden = true
        linkLabel.textColor = Palette.jade
        linkLabel.font = Fonts.ui(11, .medium)
        addSubview(linkLabel)

        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    var image: NSImage? {
        get { artwork.image }
        set {
            artwork.image = newValue
            artwork.isHidden = newValue == nil
            needsLayout = true
        }
    }

    var speaker: String {
        get { nameLabel.stringValue }
        set {
            nameLabel.stringValue = newValue
            accent = newValue.contains("生") ? Palette.jade : Palette.cinnabar
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        let padX = BubbleLayout.padX
        let padTop = BubbleLayout.padTop
        let nameH = BubbleLayout.nameH
        nameLabel.frame = NSRect(x: padX, y: bounds.height - padTop - nameH,
                                 width: bounds.width - padX * 2, height: nameH)
        let textW = bounds.width - padX * 2
        let imageH = image == nil ? 0 : BubbleLayout.imageHeight + 4
        let linkH: CGFloat = link == nil ? 0 : 19
        let textH = max(bounds.height - BubbleLayout.totalVerticalPadding - imageH - linkH, 16)
        let bottom = BubbleLayout.bottomPad + linkH
        linkLabel.frame = NSRect(x: padX, y: BubbleLayout.bottomPad, width: textW, height: linkH)
        let imageY = bottom + (imageAboveText ? textH + 4 : 0)
        artwork.frame = NSRect(x: padX, y: imageY,
                               width: textW, height: imageH - (imageH > 0 ? 4 : 0))
        // 关键：测量与渲染使用完全相同的宽度
        label.preferredMaxLayoutWidth = textW
        label.frame = NSRect(x: padX, y: bottom + (imageAboveText ? 0 : imageH),
                             width: textW, height: textH)
    }

    /// 依据文字计算气泡尺寸。
    /// 关键：必须用一个「与渲染完全相同的 NSTextField」来测量。
    /// 之前用 CoreText 单独算高度，但 NSTextField 的 cell 有内边距、换行更保守，
    /// 同一宽度下它比 CoreText 多换一行，导致气泡高度不足、末尾文字被裁掉。
    static func measure(text: String, speaker: String, image: NSImage? = nil,
                        maxTextWidth: CGFloat = 246) -> NSSize {
        let font = BubbleLayout.font
        // 先按单行宽度估一个容器宽度（留出 cell 内边距余量）
        let needed = ceil(Self.singleLineWidth(text, font: font)) + 16
        let textW = min(max(needed, image == nil ? 96 : 125), maxTextWidth)
        let textH = Self.fieldHeight(text, width: textW, font: font)
        let w = textW + BubbleLayout.padX * 2
        let h = textH + BubbleLayout.totalVerticalPadding + (image == nil ? 0 : BubbleLayout.imageHeight + 4)
        return NSSize(width: w, height: max(h, 58))
    }

    /// 用与 label 同配置的 NSTextField 测量真实所需高度
    private static func fieldHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byCharWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.preferredMaxLayoutWidth = width
        let fit = field.sizeThatFits(NSSize(width: width, height: 10000))
        return ceil(fit.height) + 2
    }

    private static func singleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attrs).width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 8
        let body = bounds.insetBy(dx: inset, dy: inset)
        let r: CGFloat = 14
        let tailW: CGFloat = 11
        let tailH: CGFloat = 9

        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: r, cornerHeight: r)
        // 气泡尖角
        let tx = body.midX
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: tx - tailW, y: body.minY + 2))
        tail.addLine(to: CGPoint(x: tx + tailW * 0.2, y: body.minY + 2))
        tail.addLine(to: CGPoint(x: tx - tailW * 0.35, y: body.minY - tailH))
        tail.closeSubpath()
        path.addPath(tail)

        // 阴影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12,
                      color: Palette.shadow.cgColor)
        ctx.addPath(path)
        ctx.setFillColor(Palette.paper.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 描边
        ctx.addPath(path)
        ctx.setStrokeColor(Palette.paperEdge.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // 左上角一抹朱红点缀
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [accent.withAlphaComponent(0.14).cgColor,
                                       accent.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1])
        if let g = grad {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: body.minX, y: body.maxY),
                                   end: CGPoint(x: body.minX + body.width * 0.7, y: body.minY),
                                   options: [])
        }
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let link, linkLabel.frame.contains(point) { NSWorkspace.shared.open(link) }
        else { onHit?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.1, frame.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 气泡排版常量：measure 与 layout 共享，避免两处数值不一致
enum BubbleLayout {
    static let imageHeight: CGFloat = 55
    static let padX: CGFloat = 14
    static let padTop: CGFloat = 9
    static let nameH: CGFloat = 14
    static let bottomPad: CGFloat = 10
    static let gapAfterName: CGFloat = 10
    static var font: NSFont { Fonts.kai(14) }
    static var totalVerticalPadding: CGFloat { padTop + nameH + gapAfterName + bottomPad }
}
