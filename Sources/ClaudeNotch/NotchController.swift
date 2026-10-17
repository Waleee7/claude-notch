import AppKit
import SwiftUI

/// Borderless, non-activating panel parked over the notch, just above the menu bar.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click land even though the panel never becomes key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    private let model = NotchModel(metrics: NotchMetrics.detect())
    private let engine = MascotEngine()
    private let store = SessionStore()
    private var panel = NotchPanel()
    private var misplacedChecks = 0
    private let demo: Bool
    private var demoDriver: DemoDriver?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pulse: Timer?
    private var hoverChange: DispatchWorkItem?
    private var pauseReasons: Set<String> = []
    private let debug = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DEBUG"] != nil

    /// notify.py skips its macOS banner while this file is fresh.
    private static let aliveFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/mascot/notch.alive")

    init(demo: Bool) {
        self.demo = demo
    }

    func start() {
        let host = NotchHostingView(rootView: NotchView(model: model, engine: engine))
        host.sizingOptions = []
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        model.onOpen = { TerminalFocus.open($0) }
        engine.reduceMotion = model.reduceMotion
        engine.start()

        if demo {
            let driver = DemoDriver(emit: { [weak self] sessions, events in self?.apply(sessions, events) },
                                    peek: { [weak self] open in
                                        guard let self else { return }
                                        model.peek(open)
                                        log("peek: \(open) mode: \(model.mode)")
                                    })
            driver.start()
            demoDriver = driver
        } else {
            store.onChange = { [weak self] sessions, events in self?.apply(sessions, events) }
            store.start()
            beat()
            pulse = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
        }

        trackMouse()
        observeSystem()
        if Self.screenIsLocked { setPaused("lock", true) }  // launched behind the lock screen
    }

    // MARK: Placement healing

    /// macOS can leave this overlay frozen mid-transform (90% size, pushed below the menu
    /// bar): seen when an app is launched outside LaunchServices, and behind the lock screen.
    /// When the window server and AppKit disagree on where the panel is, re-place it, and
    /// rebuild the panel if that doesn't take.
    private func healPlacement() {
        guard !Self.screenIsLocked, let drawn = serverBounds(), let primary = NSScreen.screens.first else { return }
        let expectedTop = primary.frame.maxY - panel.frame.maxY  // window-server space is y-down
        if abs(drawn.width - panel.frame.width) < 1 && abs(drawn.minY - expectedTop) < 1 {
            misplacedChecks = 0
            return
        }
        misplacedChecks += 1
        log("misplaced (check \(misplacedChecks)): drawn \(drawn), expected top \(expectedTop)")
        if misplacedChecks >= 2 {
            misplacedChecks = 0
            rebuildPanel()
        } else {
            panel.orderOut(nil)
            layout()
            panel.orderFrontRegardless()
        }
    }

    private func rebuildPanel() {
        let host = panel.contentView
        panel.contentView = nil
        panel.orderOut(nil)
        panel = NotchPanel()
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()
    }

    /// Unlock and wake animations need a moment to settle before placement is final.
    private func healSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { self?.healPlacement() }
        }
    }

    private func serverBounds() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("[notch] \(message())\n".utf8))
    }

    func stop() {
        try? FileManager.default.removeItem(at: Self.aliveFile)
    }

    // MARK: State

    private func apply(_ sessions: [Session], _ events: [SessionEvent]) {
        model.sessions = sessions
        model.syncBanner()
        engine.setMood(Self.mood(for: sessions))
        for event in events {
            if event.kind == .done { engine.celebrate() }
            model.present(event, hostIsFrontmost: TerminalFocus.isFrontmost(event.session))
        }
        log("sessions: [\(sessions.map { "\($0.project)=\($0.state.rawValue)" }.joined(separator: ", "))] "
            + "events: \(events.map { "\($0.kind)" }) mode: \(model.mode) mood: \(engine.mood)")
        refreshHitTesting()
    }

    static func mood(for sessions: [Session]) -> MascotEngine.Mood {
        guard let lead = sessions.first else { return .sleeping }
        switch lead.state {
        case .needsInput: return .alert
        case .working: return .working
        case .waiting: return .waiting
        case .done, .idle:
            let lastActivity = sessions.map(\.updatedAt).max() ?? .distantPast
            return Date().timeIntervalSince(lastActivity) > 10 * 60 ? .sleeping : .idle
        }
    }

    /// Heartbeat for notify.py, a chance for the mascot to doze off when things go quiet,
    /// and a placement check.
    private func beat() {
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: Self.aliveFile, options: .atomic)
        engine.setMood(Self.mood(for: model.sessions))
        healPlacement()
    }

    // MARK: Layout & hit testing

    private func layout() {
        let metrics = NotchMetrics.detect()
        model.metrics = metrics
        let size = CGSize(width: 600, height: metrics.height + 260)
        let target = NSRect(x: (metrics.centerX - size.width / 2).rounded(), y: metrics.top - size.height,
                            width: size.width, height: size.height)
        panel.setFrame(target, display: true)
        log("layout target: \(target) got: \(panel.frame) notch: \(metrics)")
    }

    private var pillFrame: NSRect {
        let size = model.size(for: model.mode)
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func trackMouse() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHitTesting() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.refreshHitTesting() }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Only the pill itself takes the mouse; everything around it stays click-through.
    /// Hover opens after a short dwell so sweeping past the menu bar doesn't trigger it.
    private func refreshHitTesting() {
        let inside = pillFrame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        guard !demo else { return }  // --demo scripts hover itself, so recordings don't depend on the cursor
        if inside == model.hovering {
            hoverChange?.cancel()
            hoverChange = nil
            return
        }
        guard hoverChange == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverChange = nil
                if self.pillFrame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation) == inside {
                    self.model.setHovering(inside)
                }
                self.refreshHitTesting()
            }
        }
        hoverChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.12 : 0.32), execute: work)
    }

    // MARK: System events

    /// No one sees the mascot while the display sleeps, the screen is locked or another
    /// user is on the console, so the animation stops until every reason has cleared.
    private func setPaused(_ reason: String, _ paused: Bool) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if pauseReasons.isEmpty { engine.resume() } else { engine.pause() }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        on(center, NSApplication.didChangeScreenParametersNotification) { $0.layout() }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.setPaused("sleep", true) }
        on(workspace, NSWorkspace.screensDidWakeNotification) {
            $0.setPaused("sleep", false)
            $0.healSoon()
        }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setPaused("console", true) }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setPaused("console", false) }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.setPaused("lock", true) }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
            $0.setPaused("lock", false)
            $0.healSoon()
        }
        on(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.panel.orderFrontRegardless() }
        on(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            $0.model.reduceMotion = reduce
            $0.engine.reduceMotion = reduce
        }
    }

    private func on(_ center: NotificationCenter, _ name: Notification.Name,
                    _ action: @escaping @MainActor (NotchController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }
}
