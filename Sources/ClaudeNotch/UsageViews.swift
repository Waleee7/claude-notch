import AppKit
import SwiftUI

enum UsageStyle {
    /// Calm under 75%, amber 75-90%, red from 90%.
    static let calmNS = NSColor(srgbRed: 0.47, green: 0.80, blue: 0.70, alpha: 1)
    static let redNS = NSColor(srgbRed: 1.0, green: 0.31, blue: 0.28, alpha: 1)

    static func tintNS(_ fraction: Double) -> NSColor {
        fraction >= 0.9 ? redNS : (fraction >= 0.75 ? Palette.amberNS : calmNS)
    }
    static func tint(_ fraction: Double) -> Color { Color(nsColor: tintNS(fraction)) }

    static let caption = Font.system(size: 9, weight: .bold, design: .monospaced)
    static let strip = Font.system(size: 9.5, weight: .medium, design: .monospaced)
    static let big = Font.system(size: 21, weight: .semibold, design: .monospaced)
    static let value = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static let small = Font.system(size: 10, weight: .regular, design: .monospaced)

    static let dim = Color.white.opacity(0.42)
    static let soft = Color.white.opacity(0.66)

    static func modelColor(_ name: String) -> Color {
        if name.hasPrefix("opus") { return Palette.claude }
        if name.hasPrefix("sonnet") { return Color(nsColor: Palette.goldNS) }
        if name.hasPrefix("haiku") { return Color(nsColor: calmNS) }
        return Color.white.opacity(0.4)
    }
}

// MARK: - Strip

struct UsageTrack: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if fraction > 0 {
                    Capsule().fill(tint).frame(width: max(height, geo.size.width * min(fraction, 1)))
                }
            }
        }
        .frame(height: height)
    }
}

/// The always-visible bar under the notch: a hairline track and one tiny label.
struct UsageStripView: View {
    @ObservedObject var usage: UsageModel
    /// Under an open shape the bottom corners are wider, so the track pulls in further.
    var open = false

    var body: some View {
        let snap = usage.snapshot
        let active = snap?.block != nil
        let fraction = snap?.blockFraction ?? 0
        let tint = active ? UsageStyle.tint(fraction) : Color.white.opacity(0.4)

        VStack(spacing: 3) {
            HStack(spacing: 4) {
                if snap?.activeNow == true {
                    Circle().fill(tint).frame(width: 4, height: 4)
                }
                if let snap, let remaining = snap.blockRemaining {
                    Text(UsageFormat.percent(snap.blockFraction)).foregroundStyle(tint)
                    Text("est. · resets \(UsageFormat.countdown(remaining))").foregroundStyle(UsageStyle.soft)
                } else {
                    Text(snap == nil ? "usage · reading" : "no active block").foregroundStyle(UsageStyle.dim)
                }
            }
            .font(UsageStyle.strip)
            .lineLimit(1)
            UsageTrack(fraction: fraction, tint: tint, height: 2.5)
                .padding(.horizontal, open ? 11 : 6)
        }
        .padding(.horizontal, open ? NotchModel.gutter : 18)
        .padding(.top, 1)
        .frame(maxWidth: .infinity)
        .frame(height: NotchModel.stripHeight, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snap.map { "Claude 5-hour usage \(UsageFormat.percent($0.blockFraction)) estimated" } ?? "Claude usage")
    }
}

// MARK: - Panel

/// The expanded usage panel. In the notch it sits under the mascot header; in the menu bar
/// popover (`metrics == nil`) it stands alone.
struct UsagePanelView: View {
    @ObservedObject var usage: UsageModel
    let metrics: NotchMetrics?

    var body: some View {
        let snap = usage.snapshot ?? UsageAggregator.snapshot(entries: [], now: Date(), config: usage.settings.config)
        VStack(alignment: .leading, spacing: 0) {
            header(snap)
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.bottom, 11)
            if usage.showingSettings {
                UsageSettingsView(usage: usage)
            } else {
                content(snap)
            }
        }
        .padding(.horizontal, NotchModel.gutter)
        .padding(.top, metrics.map { $0.height + 2 } ?? 14)
        .padding(.bottom, metrics == nil ? 16 : 0)
        .frame(width: NotchModel.usageWidth, height: metrics == nil ? NotchModel.usageBodyHeight + 14 : nil, alignment: .topLeading)
        .background(metrics == nil ? Color.black : Color.clear)
        .environment(\.colorScheme, .dark)
    }

    private func header(_ snap: UsageSnapshot) -> some View {
        HStack(spacing: 0) {
            if metrics != nil { Color.clear.frame(width: NotchModel.textStart - NotchModel.gutter, height: 1) }
            VStack(alignment: .leading, spacing: 3) {
                Text("usage").font(Fonts.title).foregroundStyle(.white)
                Text("claude code only · est.").font(Fonts.meta).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            if snap.activeNow { Chip(text: "active now", color: UsageStyle.tint(0)) }
            Button { usage.showingSettings.toggle() } label: {
                Image(systemName: usage.showingSettings ? "checkmark" : "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(usage.showingSettings ? 0.9 : 0.5))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .accessibilityLabel(usage.showingSettings ? "Close settings" : "Usage settings")
        }
        .frame(height: 50)
    }

    private func content(_ snap: UsageSnapshot) -> some View {
        let cfg = snap.config
        return VStack(alignment: .leading, spacing: 12) {
            LimitRow(title: "5-hour block",
                     trailing: snap.blockRemaining.map { "resets in \(UsageFormat.countdown($0))" } ?? "no active block",
                     fraction: snap.block == nil ? 0 : snap.blockFraction, hasData: snap.block != nil,
                     counted: snap.blockCounted, limit: cfg.fiveHourLimit)
            LimitRow(title: "this week",
                     trailing: "since \(weekday(snap.weekStart)) · resets in \(UsageFormat.longCountdown(snap.weekEnd.timeIntervalSince(snap.now)))",
                     fraction: snap.weekFraction, hasData: true, counted: snap.weekCounted, limit: cfg.weeklyLimit)
            TodayRow(snap: snap)
            HStack(alignment: .top, spacing: 18) {
                ProjectsColumn(rows: Array(snap.projects.prefix(3)))
                ModelsColumn(rows: snap.models)
            }
            footer(snap)
        }
    }

    private func footer(_ snap: UsageSnapshot) -> some View {
        HStack {
            Text("updated \(Self.time.string(from: snap.now))").font(UsageStyle.small).foregroundStyle(UsageStyle.dim)
            Spacer()
            Text("local · est.\(cacheNote(snap))").font(UsageStyle.small).foregroundStyle(UsageStyle.dim)
        }
        .padding(.top, 2)
    }

    private func cacheNote(_ snap: UsageSnapshot) -> String {
        snap.config.includeCacheReads ? " · cache reads counted" : " · cache reads not counted"
    }

    private func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

struct SectionCaption: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased()).font(UsageStyle.caption).tracking(0.9).foregroundStyle(UsageStyle.dim)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(Fonts.meta).foregroundStyle(UsageStyle.soft).lineLimit(1) }
        }
    }
}

struct LimitRow: View {
    let title: String
    let trailing: String
    let fraction: Double
    let hasData: Bool
    let counted: Int
    let limit: Int

    var body: some View {
        let tint = hasData ? UsageStyle.tint(fraction) : Color.white.opacity(0.35)
        VStack(alignment: .leading, spacing: 4) {
            SectionCaption(text: title, trailing: trailing)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(hasData ? UsageFormat.percent(fraction) : "0%").font(UsageStyle.big).foregroundStyle(tint)
                Text("est.").font(Fonts.meta).foregroundStyle(UsageStyle.dim)
                Spacer(minLength: 8)
                Text("\(UsageFormat.tokens(counted)) / \(UsageFormat.tokens(limit))").font(UsageStyle.value).foregroundStyle(UsageStyle.soft)
            }
            UsageTrack(fraction: fraction, tint: tint, height: 5).padding(.top, 2)
        }
    }
}

struct TodayRow: View {
    let snap: UsageSnapshot

    var body: some View {
        let t = snap.today.tokens
        VStack(alignment: .leading, spacing: 5) {
            SectionCaption(text: "today", trailing: "\(snap.today.messages) messages")
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(UsageFormat.tokens(snap.todayCounted)).font(UsageStyle.big).foregroundStyle(.white)
                }
                .frame(width: 96, alignment: .leading)
                Stat(label: "in", value: t.input)
                Stat(label: "out", value: t.output)
                Stat(label: "cache wr", value: t.cacheWrite)
                Stat(label: "cache rd", value: t.cacheRead, dim: !snap.config.includeCacheReads)
            }
        }
    }
}

struct Stat: View {
    let label: String
    let value: Int
    var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7).foregroundStyle(UsageStyle.dim)
            Text(UsageFormat.tokens(value)).font(UsageStyle.value).foregroundStyle(.white.opacity(dim ? 0.45 : 0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProjectsColumn: View {
    let rows: [UsageBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption(text: "top projects · week")
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 8) {
                    if i < rows.count {
                        Text(rows[i].name).font(Fonts.body).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(UsageFormat.tokens(rows[i].counted)).font(UsageStyle.value).foregroundStyle(UsageStyle.soft)
                    } else {
                        Text("—").font(Fonts.body).foregroundStyle(.white.opacity(0.2))
                        Spacer()
                    }
                }
                .frame(height: 15)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ModelsColumn: View {
    let rows: [UsageBreakdown]

    var body: some View {
        let total = max(1, rows.reduce(0) { $0 + $1.counted })
        let segments = rows.filter { $0.counted * 100 >= total }  // slivers under 1% stay in the legend only
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption(text: "models · week")
            GeometryReader { geo in
                let usable = geo.size.width - 2 * CGFloat(max(0, segments.count - 1))
                HStack(spacing: 2) {
                    ForEach(segments) { row in
                        Rectangle().fill(UsageStyle.modelColor(row.name))
                            .frame(width: usable * CGFloat(row.counted) / CGFloat(segments.reduce(0) { $0 + $1.counted }))
                    }
                    if segments.isEmpty { Rectangle().fill(Color.white.opacity(0.12)) }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            .padding(.top, 2)
            ForEach(rows.prefix(2)) { row in
                HStack(spacing: 6) {
                    Circle().fill(UsageStyle.modelColor(row.name)).frame(width: 6, height: 6)
                    Text(row.name).font(Fonts.body).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(UsageFormat.percent(Double(row.counted) / Double(total))).font(UsageStyle.value).foregroundStyle(UsageStyle.soft)
                }
                .frame(height: 15)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings

struct UsageSettingsView: View {
    @ObservedObject var usage: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepRow(title: "5-hour limit", value: UsageFormat.tokens(usage.settings.config.fiveHourLimit)) {
                usage.settings.config.fiveHourLimit = UsageLimits.step(usage.settings.config.fiveHourLimit, up: $0)
            }
            StepRow(title: "weekly limit", value: UsageFormat.tokens(usage.settings.config.weeklyLimit)) {
                usage.settings.config.weeklyLimit = UsageLimits.step(usage.settings.config.weeklyLimit, up: $0)
            }
            StepRow(title: "week starts", value: Calendar.current.weekdaySymbols[usage.settings.config.weekStartDay - 1].prefix(3).lowercased()) {
                let day = usage.settings.config.weekStartDay - 1 + ($0 ? 1 : 6)
                usage.settings.config.weekStartDay = day % 7 + 1
            }
            SwitchRow(title: "count cache reads", isOn: $usage.settings.config.includeCacheReads)
            SwitchRow(title: "notify at 75% and 90%", isOn: $usage.settings.notify)
            Text("Claude has no public API for plan limits, so these are yours to set; every percentage is an estimate (est.) against them. Only Claude Code usage on this Mac is counted, read locally from ~/.claude/projects.")
                .font(UsageStyle.small)
                .foregroundStyle(UsageStyle.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }
}

private struct StepRow: View {
    let title: String
    let value: String
    let change: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Fonts.body).foregroundStyle(.white.opacity(0.85))
            Spacer()
            StepButton(symbol: "minus") { change(false) }
            Text(value).font(UsageStyle.value).foregroundStyle(.white).frame(width: 58)
            StepButton(symbol: "plus") { change(true) }
        }
        .frame(height: 34)
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }
}

private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(Fonts.body).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button { isOn.toggle() } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? UsageStyle.tint(0).opacity(0.85) : Color.white.opacity(0.16))
                    Circle().fill(Color.white).frame(width: 12, height: 12).padding(2)
                }
                .frame(width: 30, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "on" : "off")
        }
        .frame(height: 34)
    }
}
