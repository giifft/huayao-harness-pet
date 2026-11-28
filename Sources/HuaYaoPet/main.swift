import AppKit

// MARK: - 入口

@main
struct AppMain {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--configure-antigravity", let executable = Bundle.main.executableURL {
            do {
                try AntigravityBridge().install(executable: executable)
                Prefs.linkedPlatforms.insert(.antigravity)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
            return
        }
        if arguments.first == "--antigravity-hook",
           let event = arguments.dropFirst().first, let hook = AntigravityBridge.Hook(rawValue: event) {
            defer { print(hook.response) }
            guard Prefs.linkedPlatforms.contains(.antigravity), petIsRunning,
                  let payload = readHookPayload() else { return }
            try? AntigravityBridge().receive(hook, input: payload)
            return
        }
        if arguments.first == "--trae-hook" {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            guard executable.lastPathComponent == "huayao-trae-hook" else { return }
            let bridge = TraeBridge(home: FileManager.default.homeDirectoryForCurrentUser,
                                   bridgeDirectory: executable.deletingLastPathComponent())
            guard bridge.isEnabled, petIsRunning else { return }
            let now = Date()
            if let payload = readHookPayload(), bridge.isEnabled {
                try? bridge.receive(payload, now: now)
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

    private static var petIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "local.huayao.desktoppet")
            .contains { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private static func readHookPayload() -> Data? {
        let input = FileHandle.standardInput
        var payload = Data()
        let limit = 2 * 1024 * 1024
        do {
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard chunk.count <= limit - payload.count else { return nil }
                payload.append(chunk)
            }
            return payload
        } catch {
            return nil
        }
    }
}

final class AppDelegateHolder: NSObject, NSApplicationDelegate {
    let controller: PetController
    init(controller: PetController) { self.controller = controller }
    func applicationDidFinishLaunching(_ n: Notification) { controller.applicationDidFinishLaunching(n) }
    func applicationWillTerminate(_ n: Notification) { controller.applicationWillTerminate(n) }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}
