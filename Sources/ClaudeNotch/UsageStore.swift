import AppKit
import Combine
import CoreServices
import SwiftUI
import UserNotifications

// MARK: - Settings

/// The user's own limits and switches, kept in UserDefaults. Plan limits aren't available
/// from any public API, so every percentage in the UI is an estimate against these numbers.
struct UsageSettings: Equatable {
    var config = UsageConfig()
    var notify = true
    var showBar = true

    private enum Key {
        static let fiveHour = "usage.limit5h"
        static let weekly = "usage.limitWeek"
        static let weekStart = "usage.weekStart"
        static let cacheReads = "usage.includeCacheReads"
        static let notify = "usage.notify"
        static let showBar = "usage.showBar"
    }

    static func load(_ defaults: UserDefaults = .standard) -> UsageSettings {
        var s = UsageSettings()
        if let v = defaults.object(forKey: Key.fiveHour) as? Int, v > 0 { s.config.fiveHourLimit = v }
        if let v = defaults.object(forKey: Key.weekly) as? Int, v > 0 { s.config.weeklyLimit = v }
        if let v = defaults.object(forKey: Key.weekStart) as? Int, (1...7).contains(v) { s.config.weekStartDay = v }
        if let v = defaults.object(forKey: Key.cacheReads) as? Bool { s.config.includeCacheReads = v }
        if let v = defaults.object(forKey: Key.notify) as? Bool { s.notify = v }
        if let v = defaults.object(forKey: Key.showBar) as? Bool { s.showBar = v }
        return s
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(config.fiveHourLimit, forKey: Key.fiveHour)
        defaults.set(config.weeklyLimit, forKey: Key.weekly)
        defaults.set(config.weekStartDay, forKey: Key.weekStart)
        defaults.set(config.includeCacheReads, forKey: Key.cacheReads)
        defaults.set(notify, forKey: Key.notify)
        defaults.set(showBar, forKey: Key.showBar)
    }
}

/// What the views read: the latest snapshot and the settings behind it.
@MainActor
final class UsageModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var showingSettings = false
    @Published var settings: UsageSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            onSettingsChange?(oldValue, settings)
        }
    }

    /// (old, new). The store recomputes when the numbers behind the snapshot change.
    var onSettingsChange: ((UsageSettings, UsageSettings) -> Void)?

    init(settings: UsageSettings = .load(), snapshot: UsageSnapshot? = nil) {
        self.settings = settings
        self.snapshot = snapshot
    }
}

// MARK: - Store

/// Keeps the usage snapshot fresh: a 30 s timer plus file-system events on the transcript
/// folder. All file work runs on one utility queue; the main thread only publishes results.
@MainActor
final class UsageStore {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)

    let model: UsageModel
    private let queue = DispatchQueue(label: "com.joshdare.claudenotch.usage", qos: .utility)
    private let scanner = TranscriptScanner(root: UsageStore.root)
    private var timer: Timer?
    private var stream: FSEventStreamRef?
    private var scheduledScan: DispatchWorkItem?
    private var alerts = AlertTracker()
    private var firstLook = true
    private let defaults = UserDefaults.standard
    private let debug = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_DEBUG"] != nil

    init(model: UsageModel) {
        self.model = model
        let savedStart = defaults.object(forKey: "usage.alertBlock") as? Double
        let savedFired = (defaults.array(forKey: "usage.alertFired") as? [Int]) ?? []
        alerts = AlertTracker(blockStart: savedStart, fired: Set(savedFired))
    }

    func start() {
        model.onSettingsChange = { [weak self] old, new in
            // Limits only change percentages, which snapshots carry; the week start and the
            // cache-read switch change the aggregation itself.
            self?.refresh(rescan: false, reason: old.config == new.config ? "settings" : "config")
        }
        refresh(rescan: true, reason: "launch")
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(rescan: true, reason: "timer") }
        }
        timer?.tolerance = 5
        startWatching()
    }

    func stop() {
        timer?.invalidate()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func refresh(rescan: Bool, reason: String = "") {
        let config = model.settings.config
        let calendar = Calendar.current
        let debug = debug
        queue.async { [scanner] in
            if rescan {
                let stats = scanner.scan()
                if debug {
                    FileHandle.standardError.write(Data("[usage] scan \(reason): \(stats.filesRead) files read, \(stats.bytesRead) bytes, \(String(format: "%.3f", stats.seconds))s\n".utf8))
                }
            }
            let snapshot = UsageAggregator.snapshot(entries: scanner.entries, now: Date(), calendar: calendar, config: config)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.publish(snapshot) }
            }
        }
        if stream == nil { startWatching() }  // projects folder may not have existed at launch
    }

    private func publish(_ snapshot: UsageSnapshot) {
        // A refresh queued before a settings change must not overwrite fresher numbers.
        guard snapshot.config == model.settings.config else { return }
        model.snapshot = snapshot
        if debug {
            FileHandle.standardError.write(Data(("[usage] block \(UsageFormat.percent(snapshot.blockFraction)) week \(UsageFormat.percent(snapshot.weekFraction))"
                + " today \(UsageFormat.tokens(snapshot.todayCounted)) active \(snapshot.activeNow)\n").utf8))
        }
        checkAlerts(snapshot)
    }

    // MARK: File-system events

    private func startWatching() {
        guard stream == nil, FileManager.default.fileExists(atPath: Self.root.path) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<UsageStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.transcriptsChanged() }  // the stream is scheduled on the main queue
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [Self.root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// A streaming reply appends to a transcript many times a second; at most one scan per 3 s.
    private func transcriptsChanged() {
        guard scheduledScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduledScan = nil
                self?.refresh(rescan: true, reason: "fsevent")
            }
        }
        scheduledScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: Notifications

    private func checkAlerts(_ snapshot: UsageSnapshot) {
        let crossed = alerts.update(blockStart: snapshot.block?.start.timeIntervalSince1970,
                                    fraction: snapshot.blockFraction, silent: firstLook || !model.settings.notify)
        firstLook = false
        defaults.set(alerts.blockStart, forKey: "usage.alertBlock")
        defaults.set(Array(alerts.fired), forKey: "usage.alertFired")
        guard let threshold = crossed else { return }

        let body = "5-hour block: \(UsageFormat.tokens(snapshot.blockCounted)) of \(UsageFormat.tokens(snapshot.config.fiveHourLimit)) tokens (est.)"
            + (snapshot.blockRemaining.map { " · resets in \(UsageFormat.countdown($0))" } ?? "")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Claude usage passed \(threshold)% (est.)"
            content.body = body
            content.sound = threshold >= 90 ? .default : nil
            center.add(UNNotificationRequest(identifier: "usage-\(threshold)", content: content, trigger: nil))
        }
    }
}

// MARK: - Menu bar fallback

/// A compact menu bar item for displays without a notch, opening the same panel.
@MainActor
final class UsageStatusItem: NSObject {
    private let model: UsageModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    init(model: UsageModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: UsagePanelView(usage: model, metrics: nil))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        cancellable = model.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] snapshot in
            self?.render(snapshot)
        }
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggle)
            item.button?.setAccessibilityLabel("Claude usage")
            self.item = item
            render(model.snapshot)
        } else if !visible, let existing = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    private func render(_ snapshot: UsageSnapshot?) {
        guard let button = item?.button else { return }
        let fraction = snapshot?.blockFraction ?? 0
        let text = snapshot.map { $0.block == nil ? "·" : UsageFormat.percent(fraction) } ?? "…"
        let tint = snapshot?.block == nil ? NSColor.secondaryLabelColor : UsageStyle.tintNS(fraction)
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: tint,
        ])
        button.toolTip = snapshot.map { "Claude 5-hour block: \(UsageFormat.percent($0.blockFraction)) est." }
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
