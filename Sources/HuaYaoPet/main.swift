import AppKit

// MARK: - 入口

@main
struct AppMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--trae-hook" {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            guard executable.lastPathComponent == "huayao-trae-hook" else { return }
            let now = Date()
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let bridge = TraeBridge(home: FileManager.default.homeDirectoryForCurrentUser,
                                   bridgeDirectory: executable.deletingLastPathComponent())
            try? bridge.receive(input, now: now)
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
