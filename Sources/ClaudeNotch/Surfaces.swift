import AppKit
import SwiftUI

/// The two things that animate every frame (the mascot and the ear glyph) draw in small
/// native layers. An engine tick only marks a layer dirty, never the SwiftUI view graph,
/// so animation doesn't re-run the hosting view's layout. Snapshots can't capture native
/// views, so they draw the same painters through a Canvas instead.
@MainActor
enum RenderMode {
    static var snapshot = false
}

// MARK: - Mascot

struct MascotView: View {
    let engine: MascotEngine
    var pixel: CGFloat

    /// Canvas edge in sprite px: room to hop, wander and throw particles.
    static let box: CGFloat = 26

    var body: some View {
        if RenderMode.snapshot {
            let frame = engine.frame
            Canvas { ctx, size in
                ctx.withCGContext { cg in
                    MascotPainter.draw(frame, pixel: pixel, ground: CGPoint(x: size.width / 2, y: size.height - pixel), in: cg)
                }
            }
        } else {
            MascotSurfaceView(engine: engine, pixel: pixel)
        }
    }
}

/// Pixel size animates (2 in the ear, 3 when the notch opens). The sprite is redrawn at
/// every in-between size, so it stays crisp instead of being scaled up.
private struct MascotSurfaceView: NSViewRepresentable, Animatable {
    let engine: MascotEngine
    var pixel: CGFloat

    nonisolated var animatableData: CGFloat {
        get { pixel }
        set { pixel = newValue }
    }

    func makeNSView(context: Context) -> MascotSurface {
        let view = MascotSurface()
        view.engine = engine
        engine.subscribe(view) { [weak view] in view?.state = $0 }
        return view
    }

    func updateNSView(_ view: MascotSurface, context: Context) {
        view.pixel = pixel
    }

    static func dismantleNSView(_ view: MascotSurface, coordinator: ()) {
        view.engine?.unsubscribe(view)
    }
}

final class MascotSurface: NSView {
    weak var engine: MascotEngine?
    var state = MascotFrame() { didSet { if state != oldValue { needsDisplay = true } } }
    var pixel: CGFloat = 2 { didSet { if pixel != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        MascotPainter.draw(state, pixel: pixel, ground: CGPoint(x: bounds.midX, y: bounds.maxY - pixel), in: cg)
    }
}

// MARK: - Ear

/// What the right ear shows: Claude's own spinner while working, a pulsing `!` when it
/// needs you, a check when it's done, and a count when more than one session is busy.
struct EarStatus: Equatable {
    enum Glyph: Equatable { case none, spinner(Int), alert(dim: Bool), done, waiting }

    var lead: Session.State?
    var freshDone: Bool
    var busy: Int

    init(sessions: [Session]) {
        let lead = sessions.first
        self.lead = lead?.state
        freshDone = lead.map { $0.state == .done && Date().timeIntervalSince($0.updatedAt) < 15 * 60 } ?? false
        busy = sessions.filter { $0.state == .working || $0.state == .needsInput }.count
    }

    func glyph(tick: Int) -> Glyph {
        switch lead {
        case .working?: return .spinner((tick / 2) % EarPainter.spinner.count)
        case .needsInput?: return .alert(dim: tick % 12 >= 8)
        case .waiting?: return .waiting
        default: return freshDone ? .done : .none
        }
    }
}

enum EarPainter {
    static let spinner = ["·", "✢", "✶", "✻", "✽", "✻", "✶", "✢"]

    static func draw(_ glyph: EarStatus.Glyph, badge: Int, in cg: CGContext, size: CGSize) {
        let badgeText = badge > 1 ? "\(badge)" : nil
        let badgeFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let badgeWidth = badgeText.map { NSAttributedString(string: $0, attributes: [.font: badgeFont]).size().width } ?? 0
        let glyphWidth: CGFloat = glyph == .none ? 0 : 14
        let total = glyphWidth + (badgeText != nil ? 4 + badgeWidth : 0)
        var x = (size.width - total) / 2
        let midY = size.height / 2

        switch glyph {
        case .none:
            break
        case .spinner(let i):
            MascotPainter.text(spinner[i], at: CGPoint(x: x + 7, y: midY),
                               font: .monospacedSystemFont(ofSize: 14, weight: .bold), color: Palette.claudeNS, in: cg)
        case .alert(let dim):
            symbol("exclamationmark", color: Palette.amberNS, alpha: dim ? 0.3 : 1, center: CGPoint(x: x + 7, y: midY), in: cg)
        case .done:
            symbol("checkmark", color: Palette.greenNS, alpha: 1, center: CGPoint(x: x + 7, y: midY), in: cg)
        case .waiting:
            cg.setFillColor(Palette.amberNS.withAlphaComponent(0.75).cgColor)
            cg.fillEllipse(in: CGRect(x: x + 4.5, y: midY - 2.5, width: 5, height: 5))
        }
        x += glyphWidth + (glyphWidth > 0 ? 4 : 0)
        if let badgeText {
            MascotPainter.text(badgeText, at: CGPoint(x: x + badgeWidth / 2, y: midY), font: badgeFont,
                               color: NSColor.white.withAlphaComponent(0.55), in: cg)
        }
    }

    private static func symbol(_ name: String, color: NSColor, alpha: CGFloat, center: CGPoint, in cg: CGContext) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .black)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        image.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct EarStatusView: View {
    let engine: MascotEngine
    let sessions: [Session]

    var body: some View {
        let status = EarStatus(sessions: sessions)
        if RenderMode.snapshot {
            let glyph = status.glyph(tick: engine.frame.tick)
            Canvas { ctx, size in
                ctx.withCGContext { cg in EarPainter.draw(glyph, badge: status.busy, in: cg, size: size) }
            }
        } else {
            EarSurfaceView(engine: engine, status: status)
        }
    }
}

private struct EarSurfaceView: NSViewRepresentable {
    let engine: MascotEngine
    let status: EarStatus

    func makeNSView(context: Context) -> EarSurface {
        let view = EarSurface()
        view.engine = engine
        engine.subscribe(view) { [weak view] in view?.tick = $0.tick }
        return view
    }

    func updateNSView(_ view: EarSurface, context: Context) {
        view.status = status
    }

    static func dismantleNSView(_ view: EarSurface, coordinator: ()) {
        view.engine?.unsubscribe(view)
    }
}

final class EarSurface: NSView {
    weak var engine: MascotEngine?
    var status = EarStatus(sessions: []) { didSet { refresh() } }
    var tick = 0 { didSet { refresh() } }
    private var shown: (EarStatus.Glyph, Int) = (.none, 0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Redraw only when what's visible actually changes.
    private func refresh() {
        let next = (status.glyph(tick: tick), status.busy)
        if next.0 != shown.0 || next.1 != shown.1 {
            shown = next
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        EarPainter.draw(shown.0, badge: shown.1, in: cg, size: bounds.size)
    }
}
