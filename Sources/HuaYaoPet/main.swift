import AppKit

// MARK: - 入口

@main
struct AppMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--trae-hook" {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            guard executable.lastPathComponent == "huayao-trae-hook" else { return }
            let bridge = TraeBridge(home: FileManager.default.homeDirectoryForCurrentUser,
                                   bridgeDirectory: executable.deletingLastPathComponent())
            guard bridge.isEnabled,
                  NSRunningApplication.runningApplications(withBundleIdentifier: "local.huayao.desktoppet")
                    .contains(where: { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
            else { return }
            let now = Date()
            let input = FileHandle.standardInput
            var payload = Data()
            let limit = 2 * 1024 * 1024
            do {
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    guard chunk.count <= limit - payload.count else { return }
                    payload.append(chunk)
                }
                if bridge.isEnabled { try bridge.receive(payload, now: now) }
            } catch {
                // Status reporting should never block a TRAE action.
            }
            return
        }
        let app = NSApplication.shared
        let controller = PetController()
        let delegate = AppDelegateHolder(controller: controller)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegateHolder: NSObject, NSApplicationDelegate {
    let controller: PetController
    init(controller: PetController) { self.controller = controller }
    func applicationDidFinishLaunching(_ n: Notification) { controller.applicationDidFinishLaunching(n) }
    func applicationWillTerminate(_ n: Notification) { controller.applicationWillTerminate(n) }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}
