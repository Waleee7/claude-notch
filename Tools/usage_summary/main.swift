import Foundation

// Runs the real usage engine against ~/.claude/projects and prints totals and timings.
// Prints numbers and folder names only, never transcript contents. See scripts/usage-summary.sh.

let root = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

let scanner = TranscriptScanner(root: root)
let full = scanner.scan()
let again = scanner.scan()

let snap = UsageAggregator.snapshot(entries: scanner.entries, now: Date())
let timeFormat = DateFormatter()
timeFormat.dateFormat = "EEE HH:mm"

func line(_ label: String, _ totals: UsageTotals) -> String {
    let t = totals.tokens
    return label.padding(toLength: 12, withPad: " ", startingAt: 0)
        + "counted \(UsageFormat.tokens(t.counted(includeCacheReads: false)).padding(toLength: 7, withPad: " ", startingAt: 0))"
        + " in \(UsageFormat.tokens(t.input)) out \(UsageFormat.tokens(t.output)) cache-write \(UsageFormat.tokens(t.cacheWrite))"
        + " cache-read \(UsageFormat.tokens(t.cacheRead)) msgs \(totals.messages)"
}

print("root            \(root.path)")
print("files           \(full.filesSeen) transcripts, \(full.filesRead) read")
print("bytes read      \(String(format: "%.1f", Double(full.bytesRead) / 1e6)) MB, \(full.lines) lines, \(full.candidateLines) with usage, \(full.rejected) rejected (synthetic, zero or malformed)")
print("entries         \(full.entries) unique messages (after dedupe)")
print("full scan       \(String(format: "%.3f", full.seconds)) s")
print("rescan (idle)   \(String(format: "%.3f", again.seconds)) s, \(again.bytesRead) bytes read")
print("")
print(line("today", snap.today))
if let block = snap.block {
    print(line("5h block", block.totals)
          + "  \(timeFormat.string(from: block.start))-\(timeFormat.string(from: block.end)), resets in \(UsageFormat.countdown(snap.blockRemaining ?? 0))")
} else {
    print("5h block    none active")
}
print(line("week", snap.week) + "  since \(timeFormat.string(from: snap.weekStart))")
print(line("last 7 days", snap.last7Days))
print("est. vs defaults  5h \(UsageFormat.percent(snap.blockFraction)) of \(UsageFormat.tokens(snap.config.fiveHourLimit)),"
      + " week \(UsageFormat.percent(snap.weekFraction)) of \(UsageFormat.tokens(snap.config.weeklyLimit))")
print("active now      \(snap.activeNow)")
print("models (week)   " + snap.models.map { "\($0.name) \(UsageFormat.tokens($0.counted))" }.joined(separator: ", "))
print("projects (week) " + snap.projects.prefix(3).map { "\($0.name) \(UsageFormat.tokens($0.counted))" }.joined(separator: ", "))
