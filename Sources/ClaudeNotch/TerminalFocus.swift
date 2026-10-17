import AppKit

/// Brings the session's terminal forward. In Terminal and iTerm2 it selects the
/// exact tab by TTY; anywhere else it activates the host app.
enum TerminalFocus {
    static func open(_ session: Session?) {
        guard let session else {
            launchClaude()
            return
        }
        let bundleID = hostBundleID(session) ?? "com.apple.Terminal"
        guard let tty = session.tty else {
            activate(bundleID)
            return
        }
        switch bundleID {
        case "com.apple.Terminal": run(terminalScript, tty: tty, fallback: bundleID)
        case "com.googlecode.iterm2": run(itermScript, tty: tty, fallback: bundleID)
        default: activate(bundleID)
        }
    }

    static func isFrontmost(_ session: Session) -> Bool {
        guard let id = hostBundleID(session) else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id
    }

    static func hostBundleID(_ session: Session) -> String? {
        if let app = session.app, !app.isEmpty { return app }
        switch session.term {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        default: return nil
        }
    }

    /// Nothing running: open a fresh Terminal window with Claude already started. Opening a
    /// .command file needs no Automation permission; dropping into a shell after Claude
    /// exits keeps the window usable.
    static func launchClaude() {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/mascot/open-claude.command")
        let body = "#!/bin/zsh -il\ncd \"$HOME\"\nclaude\nexec zsh -il\n"
        if (try? String(contentsOf: script, encoding: .utf8)) != body {
            try? body.write(to: script, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: config, completionHandler: nil)
    }

    static func activate(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    /// osascript off the main thread keeps the UI smooth; the TTY travels as an
    /// argument, never spliced into the script.
    private static func run(_ script: String, tty: String, fallback: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script, tty]
            let output = Pipe()
            task.standardOutput = output
            task.standardError = Pipe()
            var focused = false
            if (try? task.run()) != nil {
                task.waitUntilExit()
                let result = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                focused = task.terminationStatus == 0 && result.contains("ok")
            }
            if !focused { DispatchQueue.main.async { activate(fallback) } }
        }
    }

    private static let terminalScript = """
    on run argv
      set target to item 1 of argv
      tell application id "com.apple.Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is target then
              set selected tab of w to t
              set index of w to 1
              activate
              return "ok"
            end if
          end repeat
        end repeat
      end tell
      return "miss"
    end run
    """

    private static let itermScript = """
    on run argv
      set target to item 1 of argv
      tell application id "com.googlecode.iterm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is target then
                select w
                tell t to select
                tell s to select
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return "miss"
    end run
    """
}
