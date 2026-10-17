import AppKit
import SwiftUI

/// Where the hardware notch sits, or where a virtual one goes on displays without it.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var centerX: CGFloat
    var top: CGFloat
    var isHardware: Bool

    @MainActor
    static func detect() -> NotchMetrics {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let frame = screen.frame
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let width = frame.width - left - right
            if width > 40 {
                return NotchMetrics(width: width, height: screen.safeAreaInsets.top,
                                    centerX: frame.minX + left + width / 2, top: frame.maxY, isHardware: true)
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero
        let menuBar = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return NotchMetrics(width: 180, height: max(24, menuBar), centerX: frame.midX, top: frame.maxY, isHardware: false)
    }
}

@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable { case collapsed, banner, overview }

    struct Banner: Equatable {
        let id = UUID()
        let kind: SessionEvent.Kind
        var session: Session
    }

    @Published var metrics: NotchMetrics
    @Published var sessions: [Session] = []
    @Published private(set) var banner: Banner?
    @Published private(set) var hovering = false
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var muted = UserDefaults.standard.bool(forKey: "mutePopdowns") {
        didSet { UserDefaults.standard.set(muted, forKey: "mutePopdowns") }
    }

    let earWidth: CGFloat = 46
    /// Open layouts: a 16pt gutter inside the shape's 13pt top flare keeps content clear of
    /// the 24pt corners; text starts after the 36pt mascot plus a 12pt gap.
    static let gutter: CGFloat = 13 + 16
    static let textStart: CGFloat = gutter + 36 + 12
    var onOpen: ((Session?) -> Void)?

    private var dismissal: DispatchWorkItem?

    init(metrics: NotchMetrics) {
        self.metrics = metrics
    }

    var mode: Mode {
        if banner != nil { return .banner }
        return hovering ? .overview : .collapsed
    }

    // MARK: Geometry

    var openWidth: CGFloat { max(metrics.width + earWidth * 2 + 140, 420) }

    func size(for mode: Mode) -> CGSize {
        switch mode {
        case .collapsed:
            return CGSize(width: metrics.width + earWidth * 2, height: metrics.height)
        case .banner:
            return CGSize(width: openWidth, height: metrics.height + 66)
        case .overview:
            let rows = CGFloat(min(sessions.count, 4))
            return CGSize(width: openWidth, height: metrics.height + (rows > 0 ? 52 + 9 + rows * 40 + 10 : 56))
        }
    }

    /// Bottom-center of the mascot's feet, in pill coordinates.
    func mascotGround(for mode: Mode) -> CGPoint {
        switch mode {
        // Legs 6pt off the bottom edge centers the body on the menu bar, level with the ear glyph.
        case .collapsed: return CGPoint(x: 6 + (earWidth - 6) / 2, y: metrics.height - 6)
        case .banner: return CGPoint(x: Self.gutter + 18, y: metrics.height + 47)
        case .overview: return CGPoint(x: Self.gutter + 18, y: metrics.height + 40)
        }
    }

    // MARK: Pop-downs

    func present(_ event: SessionEvent, hostIsFrontmost: Bool) {
        guard !muted else { return }
        // A finished task never bumps another session's pending "needs you".
        if let current = banner, current.kind == .needsInput, event.kind == .done,
           current.session.id != event.session.id { return }
        banner = Banner(kind: event.kind, session: event.session)
        let hold: TimeInterval = event.kind == .needsInput ? 9 : 6
        scheduleDismiss(after: hostIsFrontmost ? 3.5 : hold)
    }

    /// Keep the visible banner in sync with its session, and drop it once resolved.
    func syncBanner() {
        guard let current = banner else { return }
        guard let fresh = sessions.first(where: { $0.id == current.session.id }) else {
            banner = nil
            return
        }
        if current.kind == .needsInput && fresh.state != .needsInput {
            banner = nil
        } else if fresh != current.session {
            banner?.session = fresh
        }
    }

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        if !value, banner != nil { scheduleDismiss(after: 1.4) }
    }

    func open(_ session: Session?) {
        onOpen?(session ?? banner?.session ?? sessions.first)
        dismissal?.cancel()
        banner = nil
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.banner = nil
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Open or close the session list as if hovered, dropping any banner (the --demo script).
    func peek(_ open: Bool) {
        dismissal?.cancel()
        banner = nil
        hovering = open
    }

    /// Put the notch in an exact state (snapshots).
    func stage(_ kind: SessionEvent.Kind?, session: Session?, hovering: Bool) {
        banner = kind.flatMap { kind in session.map { Banner(kind: kind, session: $0) } }
        self.hovering = hovering
    }
}
