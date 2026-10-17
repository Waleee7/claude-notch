import AppKit

@main
enum ClaudeNotchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let dir = Self.value(after: "--snapshot", in: args) {
            Snapshotter.renderAll(to: URL(fileURLWithPath: dir))
            exit(0)
        }
        if let dir = Self.value(after: "--iconset", in: args) {
            Snapshotter.renderIconset(to: URL(fileURLWithPath: dir))
            exit(0)
        }
        if Self.anotherInstanceIsRunning() { exit(0) }

        let controller = NotchController(demo: args.contains("--demo"))
        controller.start()
        self.controller = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The login agent keeps the notch alive no matter how it exits, so Quit unloads the
    /// agent first. It loads again at the next login; scripts/uninstall.sh removes it for good.
    static func quit() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/com.joshdare.claudenotch"]
        if (try? task.run()) != nil { task.waitUntilExit() }
        NSApp.terminate(nil)
    }

    /// The login agent and a manual launch must never stack two notches. A copy that's
    /// already shutting down (reinstall, relaunch) gets a moment to finish first.
    private static func anotherInstanceIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<15 {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != me && !$0.isTerminated }
            if others.isEmpty { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}
