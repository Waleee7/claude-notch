import AppKit
import SwiftUI

enum Fonts {
    static let title = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let body = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    static let meta = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    static let chip = Font.system(size: 9, weight: .bold, design: .monospaced)
}

/// The notch silhouette: concave flares where it meets the top edge, soft bottom corners.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        let t = min(top, rect.width / 4)
        let b = max(0, min(bottom, rect.height - t, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let engine: MascotEngine

    var body: some View {
        let mode = model.mode
        let size = model.size(for: mode)
        let open = mode != .collapsed
        let shape = NotchShape(top: open ? 13 : 6, bottom: open ? 24 : 10)
        let ground = model.mascotGround(for: mode)
        let pixel: CGFloat = open ? 3 : 2
        let box = MascotView.box * 3

        ZStack(alignment: .topLeading) {
            shape.fill(Color.black)

            EarStatusView(engine: engine, sessions: model.sessions)
                .frame(width: model.earWidth - 6, height: model.metrics.height)
                .offset(x: size.width - model.earWidth)
                .opacity(open ? 0 : 1)

            content(mode)

            MascotView(engine: engine, pixel: pixel)
                .frame(width: box, height: box, alignment: .bottom)
                .position(x: ground.x, y: ground.y + pixel - box / 2)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { model.open(nil) }
        .contextMenu {
            Button(model.muted ? "Unmute Pop-downs" : "Mute Pop-downs") { model.muted.toggle() }
            Divider()
            Button("Quit Claude Notch (until next login)") { AppDelegate.quit() }
        }
        // Radius 0 when collapsed: an invisible shadow still re-blurs the pill every frame.
        .shadow(color: .black.opacity(open ? 0.5 : 0), radius: open ? 16 : 0, y: open ? 7 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(model.reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.74), value: mode)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: model.sessions.count)
    }

    @ViewBuilder
    private func content(_ mode: NotchModel.Mode) -> some View {
        switch mode {
        case .banner:
            if let banner = model.banner {
                BannerContent(banner: banner, metrics: model.metrics)
                    .id(banner.id)
                    .transition(.blurFade)
            }
        case .overview:
            OverviewContent(sessions: model.sessions, metrics: model.metrics) { model.open($0) }
                .transition(.blurFade)
        case .collapsed:
            EmptyView()
        }
    }
}

// MARK: - Banner

struct BannerContent: View {
    let banner: NotchModel.Banner
    let metrics: NotchMetrics

    var body: some View {
        let session = banner.session
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear.frame(width: NotchModel.textStart, height: 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(session.project).font(Fonts.title).foregroundStyle(.white).lineLimit(1)
                    Chip(text: banner.kind == .done ? "done" : "needs you",
                         color: banner.kind == .done ? Palette.green : Palette.amber)
                }
                Text(line)
                    .font(Fonts.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(trailing(at: timeline.date)).font(Fonts.meta).foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(.trailing, NotchModel.gutter)
        .frame(height: 58)
        .padding(.top, metrics.height + 2)
    }

    private var line: String {
        switch banner.kind {
        case .needsInput: return banner.session.message ?? "Claude needs your input"
        case .done: return banner.session.message ?? "Finished"
        }
    }

    private func trailing(at now: Date) -> String {
        let session = banner.session
        if banner.kind == .done, let start = session.turnStartedAt, let end = session.turnEndedAt {
            return Clock.timer(end.timeIntervalSince(start))
        }
        return Clock.ago(now.timeIntervalSince(session.updatedAt))
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(Fonts.chip)
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Overview

struct OverviewContent: View {
    let sessions: [Session]
    let metrics: NotchMetrics
    let onOpen: (Session) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: NotchModel.textStart - NotchModel.gutter, height: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sessions.isEmpty ? "all quiet" : "claude code").font(Fonts.title).foregroundStyle(.white)
                    Text(summary).font(Fonts.meta).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 50)

            if !sessions.isEmpty {
                Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.bottom, 8)
                ForEach(sessions.prefix(4)) { session in
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(session) }
                }
            }
        }
        .padding(.horizontal, NotchModel.gutter)
        .padding(.top, metrics.height + 2)
    }

    private var summary: String {
        guard !sessions.isEmpty else { return "click to start claude" }
        let needs = sessions.filter { $0.state == .needsInput }.count
        let working = sessions.filter { $0.state == .working }.count
        let done = sessions.filter { $0.state == .done }.count
        var parts: [String] = []
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) working") }
        if done > 0 { parts.append("\(done) done") }
        if parts.isEmpty { parts.append("\(sessions.count) session\(sessions.count == 1 ? "" : "s") resting") }
        return parts.joined(separator: " · ")
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        // Two lines, like a notification: the detail gets a full column instead of whatever
        // room a long project name leaves.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StateDot(state: session.state)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project).font(Fonts.title).foregroundStyle(.white).lineLimit(1)
                Text(session.detail)
                    .font(Fonts.body)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(elapsed(at: timeline.date)).font(Fonts.meta).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(height: 40)
    }

    private func elapsed(at now: Date) -> String {
        if session.state == .working, let start = session.turnStartedAt {
            return Clock.timer(now.timeIntervalSince(start))
        }
        return Clock.ago(now.timeIntervalSince(session.updatedAt))
    }
}

struct StateDot: View {
    let state: Session.State

    var body: some View {
        // Shape as well as hue, so states read without color: working is a ring,
        // needs-you carries a halo.
        Group {
            if state == .working {
                Circle().strokeBorder(color, lineWidth: 1.75)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
        .background(Circle().fill(color.opacity(state == .needsInput ? 0.3 : 0)).frame(width: 16, height: 16))
    }

    private var color: Color {
        switch state {
        case .needsInput: return Palette.amber
        case .working: return Palette.claude
        case .done: return Palette.green
        case .waiting: return Palette.amber.opacity(0.6)
        case .idle: return Color.white.opacity(0.25)
        }
    }
}

// MARK: - Transition

private struct BlurFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 6 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.97 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}
