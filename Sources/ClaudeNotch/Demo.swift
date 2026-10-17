import AppKit
import SwiftUI

extension Session {
    static func sample(_ id: String, _ project: String, _ state: State, _ message: String?,
                       ran: TimeInterval = 48, at now: Date = Date()) -> Session {
        Session(id: id, state: state, project: project, message: message, prompt: "add the calibration overlay",
                tty: nil, app: nil, term: nil, pid: nil, updatedAt: now,
                turnStartedAt: now.addingTimeInterval(-ran), turnEndedAt: state == .done ? now : nil)
    }
}

/// Scripted sessions for screen recordings: `ClaudeNotch --demo` (scripts/demo.sh).
/// One hands-free loop of about 17s: asleep, working, needs you, working, done, then a
/// peek at the session list.
@MainActor
final class DemoDriver {
    private struct Beat {
        var sessions: [Session]
        var event: SessionEvent.Kind? = nil
        var peek: Bool? = nil
        var hold: TimeInterval
    }

    private let emit: ([Session], [SessionEvent]) -> Void
    private let peek: (Bool) -> Void
    private var step = 0
    private var timer: Timer?

    init(emit: @escaping ([Session], [SessionEvent]) -> Void, peek: @escaping (Bool) -> Void) {
        self.emit = emit
        self.peek = peek
    }

    func start() {
        advance()
    }

    private func advance() {
        let finished = "Calibration overlay is in. All 14 tests pass."
        let pair: [Session] = [.sample("b", "infinite-edition", .working, "Editing drift.ts", ran: 21),
                               .sample("a", "trackside", .done, finished, ran: 134)]
        let script: [Beat] = [
            Beat(sessions: [], hold: 1.8),
            Beat(sessions: [.sample("a", "trackside", .working, "Reading calibrate.py")], hold: 2),
            Beat(sessions: [.sample("a", "trackside", .working, "Editing overlay.ts")], hold: 1.6),
            Beat(sessions: [.sample("a", "trackside", .needsInput, "Claude needs your permission to use Bash")],
                 event: .needsInput, hold: 2.8),
            Beat(sessions: [.sample("a", "trackside", .working, "Running the test suite")], hold: 1.8),
            Beat(sessions: [.sample("a", "trackside", .done, finished, ran: 134)], event: .done, hold: 2.8),
            Beat(sessions: pair, peek: true, hold: 2.8),
            Beat(sessions: pair, peek: false, hold: 1.2),
        ]
        let beat = script[step % script.count]
        step += 1
        let events = beat.event.flatMap { kind in beat.sessions.first.map { [SessionEvent(kind: kind, session: $0)] } } ?? []
        emit(beat.sessions, events)
        if let open = beat.peek { peek(open) }
        timer = Timer.scheduledTimer(withTimeInterval: beat.hold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }
}

// MARK: - Snapshots

/// Renders every state to PNG without touching the screen:
/// `ClaudeNotch --snapshot <dir>` and `ClaudeNotch --iconset <dir>`.
@MainActor
enum Snapshotter {
    static func renderAll(to dir: URL) {
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let metrics = NotchMetrics.detect()
        let canvas = CGSize(width: 600, height: metrics.height + 250)

        let poses: [(String, MascotFrame)] = [
            ("idle", MascotFrame()),
            ("blink", MascotFrame(eyes: .blink)),
            ("look", MascotFrame(eyes: .left)),
            ("walk", MascotFrame(eyes: .right, legs: .stepA)),
            ("squash", MascotFrame(squash: 0.2)),
            ("jump", MascotFrame(arms: .up, dy: -5, squash: -0.14)),
            ("cheer", MascotFrame(eyes: .happy, arms: .up, glow: .green)),
            ("alert", MascotFrame(arms: .leftUp, bang: true, glow: .amber)),
            ("work", MascotFrame(legs: .stepB, particles: [Particle(kind: .spark, x: -2, y: -12, vx: 0, vy: 0, life: 8, span: 10)])),
            ("sleep", MascotFrame(eyes: .closed, squash: 0.1, particles: [Particle(kind: .zee, x: 5, y: -11, vx: 0, vy: 0, life: 9, span: 10)])),
        ]
        write(PoseSheet(poses: poses), size: CGSize(width: CGFloat(poses.count) * 104 + 28, height: 150),
              to: dir.appendingPathComponent("poses.png"), scale: 2)

        let trio: [Session] = [
            .sample("a", "trackside", .needsInput, "Claude needs your permission to use Bash"),
            .sample("b", "infinite-edition", .working, "Editing drift.ts", ran: 187),
            .sample("c", "claude-notch", .done, "Built the notch app with 0 warnings.", ran: 412),
        ]
        let working = MascotFrame(legs: .stepA, particles: [Particle(kind: .spark, x: -1, y: -12, vx: 0, vy: 0, life: 8, span: 10)], tick: 6)
        let states: [(String, [Session], SessionEvent.Kind?, Bool, MascotFrame)] = [
            ("1-collapsed-sleeping", [], nil, false,
             MascotFrame(eyes: .closed, squash: 0.1, particles: [Particle(kind: .zee, x: 5, y: -11, vx: 0, vy: 0, life: 9, span: 10)])),
            ("2-collapsed-working", [trio[1]], nil, false, working),
            ("3-collapsed-alert", [trio[0], trio[1]], nil, false, MascotFrame(arms: .rightUp, bang: true, glow: .amber, tick: 2)),
            ("4-banner-needs-you", [trio[0]], .needsInput, false, MascotFrame(arms: .leftUp, bang: true, glow: .amber)),
            ("5-banner-done", [trio[2]], .done, false, MascotFrame(eyes: .happy, arms: .up, glow: .green)),
            ("6-overview", trio, nil, true, MascotFrame(eyes: .right)),
            ("7-overview-empty", [], nil, true, MascotFrame(eyes: .closed, squash: 0.1)),
        ]
        for (name, sessions, kind, hovering, frame) in states {
            let model = NotchModel(metrics: metrics)
            model.sessions = sessions
            model.stage(kind, session: sessions.first, hovering: hovering)
            let engine = MascotEngine()
            engine.pose(frame)
            write(Backdrop(height: metrics.height) { NotchView(model: model, engine: engine) },
                  size: canvas, to: dir.appendingPathComponent("\(name).png"), scale: 2)
        }
    }

    static func renderIconset(to dir: URL) {
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, edge) in specs {
            let side = CGFloat(edge)
            write(AppIconView(size: side), size: CGSize(width: side, height: side),
                  to: dir.appendingPathComponent("\(name).png"), scale: 1)
        }
    }

    static func write<V: View>(_ view: V, size: CGSize, to url: URL, scale: CGFloat) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not render \(url.lastPathComponent)\n".utf8))
            return
        }
        try? png.write(to: url)
    }
}

/// A stand-in wallpaper and menu bar so snapshots show the notch in context.
private struct Backdrop<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.42, green: 0.55, blue: 0.74), Color(red: 0.83, green: 0.66, blue: 0.58)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.white.opacity(0.28)).frame(height: height)
            content
        }
    }
}

private struct PoseSheet: View {
    let poses: [(String, MascotFrame)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(poses.enumerated()), id: \.offset) { _, pose in
                VStack(spacing: 6) {
                    Canvas { ctx, size in
                        ctx.withCGContext { MascotPainter.draw(pose.1, pixel: 6, ground: CGPoint(x: size.width / 2, y: size.height - 6), in: $0) }
                    }
                    .frame(width: 100, height: 110)
                    Text(pose.0).font(Fonts.meta).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(14)
        .background(Color.black)
    }
}

private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        let tile = (size * 0.8).rounded()
        let pixel = max(1, (tile * 0.62 / CGFloat(Sprite.columns)).rounded(.down))
        let frame = MascotFrame(eyes: .happy, arms: .up)
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
                .frame(width: tile, height: tile)
            RadialGradient(colors: [Palette.claude.opacity(0.38), .clear], center: .center,
                           startRadius: 0, endRadius: tile * 0.42)
                .frame(width: tile, height: tile)
            Canvas { ctx, canvas in
                let spriteHeight = CGFloat(Sprite.rows) * pixel
                let ground = CGPoint(x: (canvas.width / 2).rounded(), y: ((canvas.height + spriteHeight) / 2).rounded())
                ctx.withCGContext { MascotPainter.draw(frame, pixel: pixel, ground: ground, in: $0) }
            }
            .frame(width: tile, height: tile)
        }
        .frame(width: size, height: size)
    }
}
