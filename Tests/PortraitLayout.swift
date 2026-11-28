import AppKit

@main
enum PortraitLayout {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let visible_bounds_px: [CGFloat]
        }

        let files: [String: Entry]
    }

    static func main() throws {
        let path = ProcessInfo.processInfo.environment["HUAYAO_PORTRAIT_LAYOUT"]!
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let assets = Assets.shared
        let poses = [PetMode.duo, .hua, .sheng].flatMap { assets.poses(for: $0) }
        precondition(poses.count == 38)
        let scene = PetSceneView(frame: .zero)
        let shortLine = "花语迷濛巫山云。"
        let longLine = Array(repeating: shortLine, count: 10).joined()
        let artwork = NSImage(size: NSSize(width: 80, height: 55))
        let petals = PetalView(frame: .zero)
        let bubble = BubbleView(frame: .zero)
        scene.addSubview(petals)
        scene.addSubview(bubble)
        petals.bubble = bubble
        bubble.alphaValue = 1

        for scale: CGFloat in [0.7, 1, 1.6] {
            scene.portraitSide = 300 * scale
            scene.frame.size = scene.desiredSize()
            let expected = NSRect(x: (scene.bounds.width - scene.portraitSide) / 2,
                                  y: 30, width: scene.portraitSide, height: scene.portraitSide)
            let windowSize = scene.frame.size
            for (index, pose) in poses.enumerated() {
                precondition(pose.pixelSize == NSSize(width: 1728, height: 1728))
                scene.pose = pose
                scene.feedbackPose = nil
                precondition(scene.desiredSize() == windowSize && scene.poseFrame == expected,
                             "\(pose.id) changed the stage at \(scale)")
                assertOverlays(scene, pose, manifest, shortLine, longLine, artwork, petals, bubble)
                let feedback = poses[(index + 1) % poses.count]
                scene.feedbackPose = feedback
                precondition(scene.desiredSize() == windowSize && scene.poseFrame == expected,
                             "\(pose.id) feedback changed the stage at \(scale)")
                assertOverlays(scene, feedback, manifest, shortLine, longLine, artwork, petals, bubble)
            }
        }
        print("All 38 macOS poses retain a fixed stage and balanced bubble and petal geometry at three zoom levels.")
    }

    private static func assertOverlays(_ scene: PetSceneView, _ pose: PetPose, _ manifest: Manifest,
                                       _ shortLine: String, _ longLine: String, _ artwork: NSImage,
                                       _ petals: PetalView, _ bubble: BubbleView) {
        let filename: String = switch pose.kind {
        case .duo: "duo_\(pose.id).png"
        case .hua: "hua_\(pose.id).png"
        case .sheng: "sheng_\(pose.id.dropFirst()).png"
        }
        let bounds = manifest.files[filename]!.visible_bounds_px
        let contour = scene.visiblePortraitFrame!
        let side = scene.portraitSide
        let expectedTop = scene.poseFrame.minY + side * (1 - bounds[1] / 1728)
        let expectedBottom = scene.poseFrame.minY + side * (1 - bounds[3] / 1728)
        precondition(abs(contour.maxY - expectedTop) <= side * 0.006 &&
                     abs(contour.minY - expectedBottom) <= side * 0.006,
                     "\(pose.id) visible bounds differ from the asset audit")
        let short = BubbleLayout.frame(text: shortLine, speaker: "小生", image: nil, hasLink: false,
                                       portrait: contour, contentWidth: scene.bounds.width)
        let rich = BubbleLayout.frame(text: longLine, speaker: "小生", image: artwork, hasLink: true,
                                      portrait: contour, contentWidth: scene.bounds.width)
        precondition(abs(short.maxY - contour.maxY - 130) < 0.01 &&
                     rich.minY >= contour.maxY + 11.99 && rich.height > short.height + 70 &&
                     rich.minX >= 3.99 && rich.maxX <= scene.bounds.width - 3.99,
                     "\(pose.id) overlay does not match the original headroom, short \(short), long \(rich)")
        petals.frame = scene.petalFrame
        bubble.frame = short
        precondition(petals.frame.minY >= 30 &&
                     petals.frame.maxY <= contour.maxY + BubbleLayout.portraitHeadroom + 0.01)
        let insideBubble = petals.convert(NSPoint(x: short.midX, y: short.midY), from: scene)
        precondition(!petals.drawingRegion.contains(insideBubble, using: .evenOdd))
        let nearPortrait = petals.convert(NSPoint(x: contour.midX, y: contour.midY), from: scene)
        precondition(petals.drawingRegion.contains(nearPortrait, using: .evenOdd))
    }
}
