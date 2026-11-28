import AppKit

@main
enum PortraitLayout {
    static func main() {
        let assets = Assets.shared
        let poses = [PetMode.duo, .hua, .sheng].flatMap { assets.poses(for: $0) }
        precondition(poses.count == 38)
        let scene = PetSceneView(frame: .zero)

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
                scene.feedbackPose = poses[(index + 1) % poses.count]
                precondition(scene.desiredSize() == windowSize && scene.poseFrame == expected,
                             "\(pose.id) feedback changed the stage at \(scale)")
            }
        }
        print("All 38 macOS poses retain a fixed frame at each checked zoom.")
    }
}
