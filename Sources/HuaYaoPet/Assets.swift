import AppKit

// MARK: - 一张立绘

final class PetPose {
    let id: String            // D01 / H01 / S01
    let title: String         // 抚颊对望
    let kind: PetKind
    let image: NSImage
    let cgImage: CGImage
    private var alphaMask: [UInt8]?

    init(id: String, title: String, kind: PetKind, image: NSImage, cgImage: CGImage) {
        self.id = id
        self.title = title
        self.kind = kind
        self.image = image
        self.cgImage = cgImage
    }

    var pixelSize: NSSize { NSSize(width: cgImage.width, height: cgImage.height) }

    lazy var menuThumbnail: NSImage = {
        let image = self.image
        let imageSize = pixelSize
        return NSImage(size: NSSize(width: 26, height: 24), flipped: false) { bounds in
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let size = imageSize.scaled(by: scale)
            let frame = NSRect(x: bounds.midX - size.width / 2,
                               y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
            image.draw(in: frame)
            return true
        }
    }()

    /// 该像素是否不透明（用于点击穿透判定）。坐标原点在左下。
    func isOpaque(atNormalized p: NSPoint) -> Bool {
        let mask = alphaMask ?? Self.buildMask(cgImage)
        alphaMask = mask
        let w = cgImage.width, h = cgImage.height
        let x = Int((p.x * CGFloat(w)).rounded(.down))
        let y = Int(((1 - p.y) * CGFloat(h)).rounded(.down))
        guard x >= 0, x < w, y >= 0, y < h else { return false }
        return mask[y * w + x] > 24
    }

    private static func buildMask(_ cg: CGImage) -> [UInt8] {
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: w * 4, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var out = [UInt8](repeating: 0, count: w * h)
        var i = 3
        var j = 0
        while j < out.count {
            out[j] = rgba[i]
            i += 4
            j += 1
        }
        return out
    }
}

enum PetKind {
    case duo, hua, sheng
}

// MARK: - 素材库

final class Assets {
    static let shared = Assets()

    private(set) var duo: [PetPose] = []
    private(set) var hua: [PetPose] = []
    private(set) var sheng: [PetPose] = []
    private(set) var loaded = false

    private static let duoTitles: [String: String] = [
        "D01": "依怀小憩", "D02": "相依倚榻", "D03": "抚颊对望", "D04": "并肩低语",
        "D05": "双人相拥", "D06": "背靠相携", "D07": "倚肩相依", "D08": "相拥斜卧",
        "D09": "执手对望", "D10": "携手回眸", "D11": "背向相守", "D12": "近身凝望",
        "D13": "相拥入梦", "D14": "双人卧花", "D15": "倚榻双眠", "D16": "垂眸相依",
        "D17": "红袖偷笑", "D18": "袖里藏花",
        "D19": "花落谁头上", "D20": "红袖偷笑·贴近", "D21": "袖里藏花·惊讶",
    ]

    private static let huaTitles: [String: String] = [
        "H01": "侧身坐姿", "H02": "托腮正面", "H03": "掩袖回望", "H04": "展袖舒身",
        "H05": "闭目手势", "H06": "斜卧长袖", "H07": "抬袖仰望", "H08": "正面全身",
        "H09": "坐姿飞袖", "H10": "坐姿花枝", "H11": "纱罩捧灯", "H12": "侧身回眸",
        "H13": "花间舞袖",
    ]

    private static let shengTitles: [String: String] = [
        "S01": "青衣回眸", "S02": "青衣倚坐", "S03": "红衣敛袖", "S04": "红衣执扇",
    ]

    private func resourceRoot() -> URL? {
        if let r = Bundle.main.resourceURL {
            let p = r.appendingPathComponent("Pets")
            if FileManager.default.fileExists(atPath: p.path) { return p }
        }
        if let env = ProcessInfo.processInfo.environment["HUAYAO_RESOURCES"] {
            let p = URL(fileURLWithPath: env).appendingPathComponent("Pets")
            if FileManager.default.fileExists(atPath: p.path) { return p }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let p = cwd.appendingPathComponent("Resources/Pets")
        if FileManager.default.fileExists(atPath: p.path) { return p }
        return nil
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let root = resourceRoot() else {
            NSLog("[HuaYaoPet] 找不到 Pets 素材目录")
            return
        }

        func scan(prefix: String, kind: PetKind, titles: [String: String]) -> [PetPose] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            var out: [PetPose] = []
            for f in files where f.hasPrefix(prefix) && f.hasSuffix(".png") {
                let base = String(f.dropLast(4))
                let code = base.replacingOccurrences(of: prefix, with: "")
                guard let img = NSImage(contentsOf: root.appendingPathComponent(f)),
                      let cg = Self.cgImage(from: img) else { continue }
                let id = kind == .sheng ? "S" + code : code
                let title = titles[id] ?? id
                out.append(PetPose(id: id, title: title, kind: kind, image: img, cgImage: cg))
            }
            return out.sorted { $0.id < $1.id }
        }

        duo = scan(prefix: "duo_", kind: .duo, titles: Self.duoTitles)
        hua = scan(prefix: "hua_", kind: .hua, titles: Self.huaTitles)
        sheng = scan(prefix: "sheng_", kind: .sheng, titles: Self.shengTitles)

        NSLog("[HuaYaoPet] 载入立绘：双人 \(duo.count) 款，花旦 \(hua.count) 款，小生 \(sheng.count) 款")
    }


    /// 可靠地从 NSImage 取出 CGImage：优先用 TIFF 往返，保证尺寸与方向正确
    private static func cgImage(from img: NSImage) -> CGImage? {
        if let rep = img.representations.first as? NSBitmapImageRep,
           let cg = rep.cgImage {
            return cg
        }
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let cg = bmp.cgImage else { return nil }
        return cg
    }

    func poses(for mode: PetMode) -> [PetPose] {
        loadIfNeeded()
        switch mode {
        case .hua: return hua
        case .sheng: return sheng
        case .duo: return duo
        }
    }

    func selectedPose(for mode: PetMode) -> PetPose? {
        let poses = poses(for: mode)
        let preferredID = Prefs.poseID(for: mode) ?? mode.defaultPoseID
        return poses.first { $0.id == preferredID }
            ?? poses.first { $0.id == mode.defaultPoseID }
            ?? poses.first
    }
}
