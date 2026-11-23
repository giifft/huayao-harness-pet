import AppKit
import QuartzCore

// MARK: - 透明置顶窗口

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }
}

// MARK: - 场景视图

final class PetSceneView: NSView {
    var pose: PetPose? { didSet { needsDisplay = true } }

    // 显示参数
    var spriteHeight: CGFloat = 190          // 单个立绘的高度（点）
    private let statusSpace: CGFloat = 30
    // 顶部留给气泡：需容纳 3 行中文（约 20pt/行）+ 名字 + 内边距 + 尖角
    private let bubbleSpace: CGFloat = 132

    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?
    private var didDrag = false
    private var idleTimer: Timer?
    private var breath: CGFloat = 0
    private var hop: CGFloat = 0
    private var hopTimer: Timer?

    var onClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var hitTestAlpha: Bool = true

    // MARK: 布局

    private var poseSize: NSSize {
        guard let pose else { return .zero }
        let height = spriteHeight * (pose.kind == .duo ? 1.28 : 1)
        let width = height * pose.pixelSize.width / pose.pixelSize.height
        return NSSize(width: width, height: height)
    }

    private var poseFrame: NSRect {
        let size = poseSize
        return NSRect(x: (bounds.width - size.width) / 2,
                      y: statusSpace + sin(breath) * 2.2 + hop,
                      width: size.width, height: size.height)
    }

    func desiredSize() -> NSSize {
        let size = poseSize
        return NSSize(width: max(size.width + 28, 240), height: size.height + bubbleSpace + statusSpace)
    }

    // MARK: 绘制

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        guard let pose else { return }
        let f = poseFrame
        // 地面阴影
        let shadowW = f.width * 0.62
        let shadowH: CGFloat = 9
        let sx = f.midX - shadowW / 2
        let sy = f.minY - 2
        ctx.saveGState()
        let colors = [NSColor.black.withAlphaComponent(0.16).cgColor,
                      NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.translateBy(x: sx + shadowW / 2, y: sy + shadowH / 2)
            ctx.scaleBy(x: 1, y: shadowH / shadowW * 2)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: shadowW / 2, options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()

        ctx.draw(pose.cgImage, in: f)
    }

    // MARK: 动画

    func startIdle() {
        stopIdle()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.breath += 0.055
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    func stopIdle() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// 开心地跳一下
    func hopOnce() {
        hopTimer?.invalidate()
        var t: CGFloat = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            t += 0.06
            if t >= 1 {
                self.hop = 0
                self.needsDisplay = true
                timer.invalidate()
                self.hopTimer = nil
                return
            }
            self.hop = sin(t * .pi) * 10
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        hopTimer = timer
    }

    // MARK: 命中测试（按像素透明度）

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point 在父视图坐标（此处即窗口内容坐标，因为本视图铺满）
        guard bounds.contains(point) else { return nil }
        guard hitTestAlpha else { return self }
        return containsOpaquePixel(at: point) ? self : nil
    }

    private func containsOpaquePixel(at point: NSPoint) -> Bool {
        let frame = poseFrame
        guard let pose, frame.contains(point) else { return false }
        return pose.isOpaque(atNormalized: NSPoint(x: (point.x - frame.minX) / frame.width,
                                                   y: (point.y - frame.minY) / frame.height))
    }

    // MARK: 拖拽与点击

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin, let wo = windowOrigin, let win = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !didDrag && hypot(dx, dy) > 3 {
            didDrag = true
        }
        guard didDrag else { return }
        win.setFrameOrigin(NSPoint(x: wo.x + dx, y: wo.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil; windowOrigin = nil }
        if didDrag {
            onDragEnded?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if containsOpaquePixel(at: point) { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 滚轮缩放

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        guard event.scrollingDeltaY != 0 else { return }
        onZoom?(event.scrollingDeltaY > 0 ? 0.04 : -0.04)
    }
}
