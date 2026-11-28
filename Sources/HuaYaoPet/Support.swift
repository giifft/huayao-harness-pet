import AppKit

// MARK: - 配色（取自《花妖》的朱红、青绿与宣纸）

enum Palette {
    static let ink        = NSColor(srgbRed: 0.129, green: 0.110, blue: 0.098, alpha: 1)
    static let inkSoft    = NSColor(srgbRed: 0.360, green: 0.320, blue: 0.290, alpha: 1)
    static let paper      = NSColor(srgbRed: 0.984, green: 0.965, blue: 0.925, alpha: 0.97)
    static let paperEdge  = NSColor(srgbRed: 0.820, green: 0.760, blue: 0.650, alpha: 0.55)
    static let cinnabar   = NSColor(srgbRed: 0.780, green: 0.160, blue: 0.200, alpha: 1)
    static let jade       = NSColor(srgbRed: 0.180, green: 0.420, blue: 0.370, alpha: 1)
    static let gold       = NSColor(srgbRed: 0.780, green: 0.620, blue: 0.240, alpha: 1)
    static let petalA     = NSColor(srgbRed: 0.960, green: 0.620, blue: 0.640, alpha: 1)
    static let petalB     = NSColor(srgbRed: 0.980, green: 0.820, blue: 0.820, alpha: 1)
    static let shadow     = NSColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 0.16)
}

// MARK: - 字体

enum Fonts {
    static func kai(_ size: CGFloat) -> NSFont {
        for name in ["Kaiti SC", "STKaiti", "Kaiti", "Songti SC", "PingFang SC"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .systemFont(ofSize: size)
    }

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - 小工具

extension NSRect {
    func scaled(by s: CGFloat) -> NSRect {
        NSRect(x: origin.x * s, y: origin.y * s, width: width * s, height: height * s)
    }
}

extension NSSize {
    func scaled(by s: CGFloat) -> NSSize {
        NSSize(width: width * s, height: height * s)
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}

/// 柔和缓动
func easeInOut(_ t: Double) -> Double {
    (1 - cos(t * .pi)) / 2
}

// MARK: - 桌宠模式

enum PetMode: String, CaseIterable {
    case hua   = "花旦单人"
    case sheng = "小生单人"
    case duo   = "双人"

    var defaultPoseID: String {
        switch self {
        case .hua: return "H08"
        case .sheng: return "S03"
        case .duo: return "D09"
        }
    }
}

// MARK: - 偏好设置

enum Prefs {
    private static let d = UserDefaults.standard

    static var scale: Double {
        get {
            let scale = d.double(forKey: "scale")
            return scale.isFinite && scale > 0 ? scale : 0.7
        }
        set { d.set(newValue, forKey: "scale") }
    }

    static func poseID(for mode: PetMode) -> String? {
        d.string(forKey: "pose.\(mode.rawValue)")
    }

    static func setPoseID(_ id: String, for mode: PetMode) {
        d.set(id, forKey: "pose.\(mode.rawValue)")
    }

    static var mode: PetMode {
        get {
            guard let s = d.string(forKey: "petMode"), let m = PetMode(rawValue: s) else { return .duo }
            return m
        }
        set { d.set(newValue.rawValue, forKey: "petMode") }
    }

    static var autoChat: Bool {
        get { d.object(forKey: "autoChat") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoChat") }
    }

    static var activityClearedAt: Date? {
        get { d.object(forKey: "activityClearedAt") as? Date }
        set { d.set(newValue, forKey: "activityClearedAt") }
    }

    static var standardLinkedPlatforms: Set<AgentPlatform> {
        Set(AgentPlatform.allCases).subtracting([.doubao])
    }

    static var linkedPlatforms: Set<AgentPlatform> {
        get {
            if let values = d.stringArray(forKey: "linkedPlatforms") {
                return Set(values.compactMap(AgentPlatform.init(rawValue:)))
            }
            // Carry forward the old Harness switch, including the standalone mode.
            return (d.object(forKey: "dshLink") as? Bool ?? true)
                ? standardLinkedPlatforms : []
        }
        set { d.set(AgentPlatform.allCases.filter(newValue.contains).map(\.rawValue), forKey: "linkedPlatforms") }
    }

    static var clickThrough: Bool {
        get { d.object(forKey: "clickThrough") as? Bool ?? true }
        set { d.set(newValue, forKey: "clickThrough") }
    }

    static var windowOrigin: NSPoint? {
        get {
            guard let s = d.string(forKey: "windowOrigin") else { return nil }
            return NSPointFromString(s)
        }
        set {
            if let p = newValue { d.set(NSStringFromPoint(p), forKey: "windowOrigin") }
        }
    }
}
