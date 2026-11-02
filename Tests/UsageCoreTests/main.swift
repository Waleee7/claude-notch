import Foundation

// Unit tests for UsageCore.swift, run by scripts/test.sh (plain swiftc, no XCTest needed).

var passed = 0
var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() { passed += 1 } else { failures.append("line \(line): \(message)") }
}

func checkEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ message: String, line: Int = #line) {
    let (x, y) = (a(), b())
    if x == y { passed += 1 } else { failures.append("line \(line): \(message): got \(x), expected \(y)") }
}

func iso(_ s: String) -> Date { Date(timeIntervalSince1970: TranscriptParser.parseTimestamp(s)!) }

func calendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

func transcriptLine(id: String? = "msg_1", request: String? = "req_1", time: String = "2026-11-02T10:00:00.000Z",
                    model: String = "claude-opus-5-5", input: Int = 10, output: Int = 20, cacheWrite: Int = 0,
                    cacheRead: Int = 0, type: String = "assistant", pad: Int = 0) -> String {
    var parts = ["\"type\":\"\(type)\"", "\"timestamp\":\"\(time)\"", "\"uuid\":\"u-\(id ?? "x")\""]
    if let request { parts.append("\"requestId\":\"\(request)\"") }
    var message = ["\"model\":\"\(model)\"", "\"role\":\"assistant\"",
                   "\"content\":[{\"type\":\"text\",\"text\":\"\(String(repeating: "x", count: pad))\"}]",
                   "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":\(cacheWrite),\"cache_read_input_tokens\":\(cacheRead)}"]
    if let id { message.append("\"id\":\"\(id)\"") }
    parts.append("\"message\":{\(message.joined(separator: ","))}")
    return "{" + parts.joined(separator: ",") + "}"
}

func entry(_ time: String, _ tokens: Int = 100, model: String = "claude-opus-5-5", project: String = "-Users-me-app") -> UsageEntry {
    UsageEntry(time: iso(time).timeIntervalSince1970, model: model, project: project, tokens: TokenCounts(input: tokens))
}

// MARK: Timestamps

checkEqual(TranscriptParser.parseTimestamp("2026-11-02T04:19:28.548Z"), 1_793_593_168.548, "fractional Z timestamp")
checkEqual(TranscriptParser.parseTimestamp("2026-11-02T04:19:28Z"), 1_793_593_168, "whole-second timestamp")
checkEqual(TranscriptParser.parseTimestamp("2026-11-01T23:19:28-05:00"), 1_793_593_168, "negative offset")
checkEqual(TranscriptParser.parseTimestamp("2026-11-02T09:49:28+05:30"), 1_793_593_168, "half-hour offset")
checkEqual(TranscriptParser.parseTimestamp("2026-03-08T05:00:00Z"), 1_772_946_000, "DST day")
check(TranscriptParser.parseTimestamp("garbage") == nil, "garbage timestamp")
check(TranscriptParser.parseTimestamp("2026-13-02T04:19:28Z") == nil, "bad month")
check(TranscriptParser.parseTimestamp("") == nil, "empty timestamp")

// MARK: Parser

let good = TranscriptParser.parse(Data(transcriptLine(input: 3, output: 4, cacheWrite: 5, cacheRead: 6).utf8))
checkEqual(good?.tokens, TokenCounts(input: 3, output: 4, cacheWrite: 5, cacheRead: 6), "all four token fields")
checkEqual(good?.key, "msg_1|req_1", "key is message.id|requestId")
checkEqual(good?.model, "claude-opus-5-5", "model")
checkEqual(TranscriptParser.parse(Data(transcriptLine(request: nil).utf8))?.key, "msg_1|", "missing requestId still keys")
check(TranscriptParser.parse(Data(transcriptLine(type: "user").utf8)) == nil, "non-assistant ignored")
check(TranscriptParser.parse(Data(transcriptLine(model: "<synthetic>").utf8)) == nil, "synthetic ignored")
check(TranscriptParser.parse(Data(transcriptLine(input: 0, output: 0).utf8)) == nil, "all-zero usage ignored")
check(TranscriptParser.parse(Data("{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":5}".utf8)) == nil, "truncated JSON")
check(TranscriptParser.parse(Data("not json at all \"output_tokens\"".utf8)) == nil, "garbage line")
check(TranscriptParser.parse(Data(transcriptLine(time: "nope").utf8)) == nil, "bad timestamp ignored")
check(TranscriptParser.parse(Data(transcriptLine(id: nil).utf8))?.key == "uuid:u-x", "no message.id falls back to uuid")
let sample = Array("{\"a\":output_tokens}".utf8)
check(sample.withUnsafeBytes { TranscriptParser.mightContainUsage($0) } == false, "needle needs quotes around the name")

// MARK: Scanner (real files)

let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-notch-tests-\(getpid())")
let root = work.appendingPathComponent("projects")
let fm = FileManager.default
try? fm.removeItem(at: work)
func write(_ relative: String, _ text: String, append: Bool = false) {
    let url = root.appendingPathComponent(relative)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if append, let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url)
    }
}

let nowDate = iso("2026-11-02T12:00:00Z")
let recent = "2026-11-02T10:00:00.000Z"
let streamed = [
    transcriptLine(id: "m1", time: recent, input: 2, output: 8),
    transcriptLine(id: "m1", time: "2026-11-02T10:00:01.000Z", input: 2, output: 256),   // streamed repeat, bigger output
    transcriptLine(id: "m1", time: "2026-11-02T10:00:02.000Z", input: 2, output: 256),
    "this line is not json",
    "{\"type\":\"assistant\",\"message\":{\"usage\":{\"output_tokens\":99}",            // truncated candidate
    transcriptLine(id: "m2", request: "r2", time: "2026-11-02T10:05:00.000Z", input: 1, output: 1),
    transcriptLine(id: "m3", time: "2026-11-02T10:06:00.000Z", model: "<synthetic>", input: 5, output: 5),
    transcriptLine(id: "u1", time: recent, type: "user"),
].joined(separator: "\n") + "\n"
write("-Users-me-app/session-a.jsonl", streamed)
write("-Users-me-app/session-a/subagents/agent-1.jsonl", transcriptLine(id: "m2", request: "r2", time: "2026-11-02T10:05:00.000Z", input: 1, output: 1) + "\n"
      + transcriptLine(id: "m4", time: "2026-11-02T10:07:00.000Z", input: 7, output: 7) + "\n")  // m2 repeats across files
write("-Users-me-other/session-b.jsonl", transcriptLine(id: "m5", time: "2026-11-02T11:00:00.000Z", model: "claude-sonnet-5-5", input: 4, output: 4) + "\n")
write("-Users-me-app/tool-results/skipme.jsonl", transcriptLine(id: "m9", time: recent) + "\n")

let scanner = TranscriptScanner(root: root)
let first = scanner.scan(now: nowDate)
checkEqual(scanner.entries.count, 4, "dedupe by message id across lines and files (m1, m2, m4, m5)")
checkEqual(first.filesSeen, 3, "tool-results is skipped; subagent files are found")
check(first.rejected >= 1, "truncated candidate line is rejected, not fatal")
let m1 = scanner.entries.first { $0.tokens.input == 2 }
checkEqual(m1?.tokens.output, 256, "streamed duplicates keep the largest output count")
checkEqual(m1?.project, "-Users-me-app", "project is the folder under the root")
checkEqual(scanner.entries.first { $0.tokens.input == 7 }?.project, "-Users-me-app", "subagent transcript belongs to its project")
checkEqual(scanner.entries.first { $0.tokens.input == 4 }?.project, "-Users-me-other", "second project")

// incremental: only appended bytes are read
let sizeBefore = (try? fm.attributesOfItem(atPath: root.appendingPathComponent("-Users-me-app/session-a.jsonl").path)[.size] as? Int) ?? 0
let quiet = scanner.scan(now: nowDate)
checkEqual(quiet.bytesRead, 0, "an unchanged tree reads nothing")
let appended = transcriptLine(id: "m6", time: "2026-11-02T10:30:00.000Z", input: 9, output: 9) + "\n"
write("-Users-me-app/session-a.jsonl", appended, append: true)
let incremental = scanner.scan(now: nowDate)
checkEqual(incremental.bytesRead, Int64(appended.utf8.count), "append reads exactly the new bytes")
check(sizeBefore > 0 && incremental.bytesRead < Int64(sizeBefore), "append read is smaller than the file")
checkEqual(scanner.entries.count, 5, "appended message added")

// a write in flight: the partial line is not consumed, then completes
let whole = transcriptLine(id: "m7", time: "2026-11-02T10:40:00.000Z", input: 11, output: 11)
let cut = whole.index(whole.startIndex, offsetBy: whole.count / 2)
write("-Users-me-app/session-a.jsonl", String(whole[..<cut]), append: true)
_ = scanner.scan(now: nowDate)
checkEqual(scanner.entries.count, 5, "partial line adds nothing")
write("-Users-me-app/session-a.jsonl", String(whole[cut...]) + "\n", append: true)
_ = scanner.scan(now: nowDate)
checkEqual(scanner.entries.count, 6, "completed line is picked up exactly once")
_ = scanner.scan(now: nowDate)
checkEqual(scanner.entries.count, 6, "and not double counted afterwards")

// truncation / replacement rereads without double counting
write("-Users-me-other/session-b.jsonl", transcriptLine(id: "m5", time: "2026-11-02T11:00:00.000Z", model: "claude-sonnet-5-5", input: 4, output: 4) + "\n")
_ = scanner.scan(now: nowDate)
checkEqual(scanner.entries.count, 6, "rewritten file merges by message id")

// big lines and chunk boundaries
var big = ""
for i in 0..<400 { big += transcriptLine(id: "bulk\(i)", time: "2026-11-02T09:00:00.000Z", pad: 6000 + i) + "\n" }  // ~2.4 MB across the 1 MiB chunks
big += transcriptLine(id: "huge", time: "2026-11-02T09:01:00.000Z", input: 77, pad: 3_000_000) + "\n"             // one 3 MB line
big += transcriptLine(id: "after", time: "2026-11-02T09:02:00.000Z", input: 78) + "\n"
write("-Users-me-big/session-c.jsonl", big)
_ = scanner.scan(now: nowDate)
checkEqual(scanner.entries.count, 6 + 402, "every bulk line plus the 3 MB line and the one after it")
checkEqual(scanner.entries.first { $0.tokens.input == 77 }?.tokens.input, 77, "3 MB line parsed")

// old files are never opened
write("-Users-me-old/session-d.jsonl", transcriptLine(id: "old1", time: recent) + "\n")
let oldPath = root.appendingPathComponent("-Users-me-old/session-d.jsonl").path
var times = [timeval(tv_sec: Int(nowDate.timeIntervalSince1970) - 30 * 86400, tv_usec: 0), timeval(tv_sec: Int(nowDate.timeIntervalSince1970) - 30 * 86400, tv_usec: 0)]
utimes(oldPath, &times)
let skipped = scanner.scan(now: nowDate)
checkEqual(skipped.filesRead, 0, "30-day-old file skipped")
check(!scanner.entries.contains { $0.project == "-Users-me-old" }, "old file contributes nothing")

// entries outside the retention window are dropped
write("-Users-me-app/ancient.jsonl", transcriptLine(id: "anc", time: "2026-01-01T00:00:00.000Z") + "\n")
let before = scanner.entries.count
_ = scanner.scan(now: nowDate)
checkEqual(scanner.entries.count, before, "line older than retention is not stored")

// missing root is harmless
checkEqual(TranscriptScanner(root: work.appendingPathComponent("nope")).scan().entries, 0, "missing root scans empty")
try? fm.removeItem(at: work)

// MARK: Blocks

let utc = calendar("UTC")
let cfg = UsageConfig()

do {
    let entries = [entry("2026-11-02T10:20:00Z"), entry("2026-11-02T12:00:00Z"), entry("2026-11-02T14:59:59Z"),
                   entry("2026-11-02T15:00:00Z"), entry("2026-11-02T16:45:00Z")]
    let blocks = UsageAggregator.blocks(from: entries)
    checkEqual(blocks.count, 2, "message exactly at block end starts a new block")
    checkEqual(blocks[0].start, iso("2026-11-02T10:00:00Z"), "block floors to the hour")
    checkEqual(blocks[0].end, iso("2026-11-02T15:00:00Z"), "block lasts five hours")
    checkEqual(blocks[0].totals.messages, 3, "first block holds three messages")
    checkEqual(blocks[1].start, iso("2026-11-02T15:00:00Z"), "second block starts at its first message, floored")
}
do {
    // The next block opens at the first message after the previous one ended, not at the end itself.
    let blocks = UsageAggregator.blocks(from: [entry("2026-11-02T10:20:00Z"), entry("2026-11-02T18:40:00Z")])
    checkEqual(blocks.count, 2, "gap longer than five hours")
    checkEqual(blocks[1].start, iso("2026-11-02T18:00:00Z"), "block starts at the message hour, not previous end")
}
do {
    let entries = [entry("2026-11-02T10:20:00Z", 100), entry("2026-11-02T13:00:00Z", 50)]
    let active = UsageAggregator.snapshot(entries: entries, now: iso("2026-11-02T14:00:00Z"), calendar: utc, config: cfg)
    checkEqual(active.block?.totals.tokens.input, 150, "active block totals")
    checkEqual(active.blockRemaining, 3600, "one hour to reset")
    let expired = UsageAggregator.snapshot(entries: entries, now: iso("2026-11-02T15:00:00Z"), calendar: utc, config: cfg)
    check(expired.block == nil, "no active block once the window has passed")
    let none = UsageAggregator.snapshot(entries: [], now: iso("2026-11-02T15:00:00Z"), calendar: utc, config: cfg)
    check(none.block == nil && !none.activeNow && none.lastActivity == nil, "empty history")
}

// Across local midnight: one 5-hour block, two different days.
do {
    let la = calendar("America/Los_Angeles")  // PST: midnight = 08:00Z
    let entries = [entry("2026-11-02T06:30:00Z", 100), entry("2026-11-02T08:30:00Z", 40), entry("2026-11-02T09:00:00Z", 60)]
    let snap = UsageAggregator.snapshot(entries: entries, now: iso("2026-11-02T10:00:00Z"), calendar: la, config: cfg)
    checkEqual(snap.block?.totals.messages, 3, "block spans local midnight")
    checkEqual(snap.today.tokens.input, 100, "today counts only after local midnight")
    checkEqual(snap.week.tokens.input, 100, "Monday-start week began at local midnight Nov 2 00:00 PST, so Sunday evening is last week")
    let sundayWeek = UsageAggregator.snapshot(entries: entries, now: iso("2026-11-02T10:00:00Z"), calendar: la, config: UsageConfig(weekStartDay: 1))
    checkEqual(sundayWeek.week.tokens.input, 200, "Sunday-start week includes both sides of midnight")
}

// DST: spring forward 2026-03-08 in New York (EST->EDT at 07:00Z), 23-hour day.
do {
    let ny = calendar("America/New_York")
    let entries = [entry("2026-03-08T04:59:00Z", 1),   // Mar 7 23:59 EST: yesterday
                   entry("2026-03-08T05:00:00Z", 10),  // Mar 8 00:00 EST: today
                   entry("2026-03-08T06:30:00Z", 100), // 01:30 EST
                   entry("2026-03-08T07:10:00Z", 1000)] // 03:10 EDT, same absolute 5h block
    let snap = UsageAggregator.snapshot(entries: entries, now: iso("2026-03-08T08:00:00Z"), calendar: ny, config: cfg)
    checkEqual(snap.today.tokens.input, 1110, "today starts at local midnight on the 23-hour day")
    checkEqual(snap.block?.start, iso("2026-03-08T04:00:00Z"), "block start floors in UTC, unaffected by the DST jump")
    checkEqual(snap.block?.end, iso("2026-03-08T09:00:00Z"), "block is exactly 5 absolute hours across DST")
    checkEqual(snap.block?.totals.messages, 4, "all four messages in the block")
    let later = UsageAggregator.snapshot(entries: entries, now: iso("2026-03-09T20:00:00Z"), calendar: ny, config: cfg)
    checkEqual(later.today.tokens.input, 0, "next day empty")
    checkEqual(later.weekStart, iso("2026-03-09T04:00:00Z"), "Monday after DST starts at 00:00 EDT (04:00Z)")
    checkEqual(later.week.tokens.input, 0, "the week resets Monday")
    let sundayStart = UsageAggregator.snapshot(entries: entries, now: iso("2026-03-09T20:00:00Z"), calendar: ny,
                                               config: UsageConfig(weekStartDay: 1))
    checkEqual(sundayStart.weekStart, iso("2026-03-08T05:00:00Z"), "Sunday week start is 00:00 EST that day")
    checkEqual(sundayStart.week.tokens.input, 1110, "Sunday-start week holds Mar 8 entries")
}

// DST: fall back 2026-11-01 (25-hour day).
do {
    let ny = calendar("America/New_York")
    let entries = [entry("2026-11-01T03:59:00Z", 1), entry("2026-11-01T04:00:00Z", 10), entry("2026-11-02T04:59:00Z", 100)]
    let snap = UsageAggregator.snapshot(entries: entries, now: iso("2026-11-02T04:59:30Z"), calendar: ny, config: cfg)
    checkEqual(snap.today.tokens.input, 110, "25-hour day: Nov 1 runs 04:00Z to 05:00Z the next day")
}

// Week start
do {
    // 2026-11-01 is a Sunday.
    let sunday = iso("2026-11-01T15:00:00Z")
    let monday = UsageAggregator.weekStart(containing: sunday, calendar: utc, startDay: 2)
    checkEqual(monday, iso("2026-10-26T00:00:00Z"), "Monday-start week containing a Sunday begins six days earlier")
    checkEqual(UsageAggregator.weekStart(containing: sunday, calendar: utc, startDay: 1), iso("2026-11-01T00:00:00Z"), "Sunday-start")
    checkEqual(UsageAggregator.weekStart(containing: sunday, calendar: utc, startDay: 7), iso("2026-10-31T00:00:00Z"), "Saturday-start")
    checkEqual(UsageAggregator.weekStart(containing: iso("2026-11-02T00:00:00Z"), calendar: utc, startDay: 2), iso("2026-11-02T00:00:00Z"), "Monday midnight is the start")
}

// Totals, breakdowns, active, limits
do {
    let home = "/Users/me"
    let entries = [
        UsageEntry(time: iso("2026-11-02T09:00:00Z").timeIntervalSince1970, model: "claude-opus-5-5", project: "-Users-me-app",
                   tokens: TokenCounts(input: 10, output: 20, cacheWrite: 30, cacheRead: 1000)),
        UsageEntry(time: iso("2026-11-02T09:30:00Z").timeIntervalSince1970, model: "claude-sonnet-5-5", project: "-Users-me",
                   tokens: TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)),
        UsageEntry(time: iso("2026-10-30T09:30:00Z").timeIntervalSince1970, model: "claude-opus-5-5", project: "-Users-me-app",
                   tokens: TokenCounts(input: 100)),
        UsageEntry(time: iso("2026-10-20T09:30:00Z").timeIntervalSince1970, model: "claude-haiku-4-5-20251001", project: "-Users-me-app",
                   tokens: TokenCounts(input: 5000)),
        UsageEntry(time: iso("2026-11-02T13:00:00Z").timeIntervalSince1970, model: "claude-opus-5-5", project: "-Users-me-app",
                   tokens: TokenCounts(input: 99999)),  // future relative to `now`
    ]
    let now = iso("2026-11-02T09:31:00Z")
    var snap = UsageAggregator.snapshot(entries: entries, now: now, calendar: utc, config: cfg, home: home)
    checkEqual(snap.today.messages, 2, "today message count, future entry ignored")
    checkEqual(snap.week.tokens.input, 11, "week since Monday, excluding last week and future")
    checkEqual(snap.last7Days.tokens.input, 111, "last 7 calendar days")
    checkEqual(snap.todayCounted, 66, "counted excludes cache reads by default")
    snap = UsageAggregator.snapshot(entries: entries, now: now, calendar: utc, config: UsageConfig(includeCacheReads: true), home: home)
    checkEqual(snap.todayCounted, 1070, "counted can include cache reads")
    checkEqual(snap.models.map(\.name), ["opus 5.5", "sonnet 5.5"], "models sorted by tokens, display names")
    checkEqual(snap.projects.map(\.name), ["app", "~"], "projects named by folder, home collapsed")
    check(snap.activeNow, "message within 2 minutes is active now")
    let idle = UsageAggregator.snapshot(entries: entries, now: iso("2026-11-02T09:33:00Z"), calendar: utc, config: cfg, home: home)
    check(!idle.activeNow, "no longer active after 2 minutes")
    var limited = cfg
    limited.fiveHourLimit = 200
    let limitedSnap = UsageAggregator.snapshot(entries: entries, now: now, calendar: utc, config: limited, home: home)
    checkEqual(limitedSnap.blockFraction, 66.0 / 200.0, "block fraction vs limit")
    limited.fiveHourLimit = 0
    checkEqual(UsageAggregator.snapshot(entries: entries, now: now, calendar: utc, config: limited, home: home).blockFraction, 0, "zero limit never divides")
}

// MARK: Names, formatting, limits, alerts

checkEqual(ModelName.display("claude-opus-5-5"), "opus 5.5", "model name")
checkEqual(ModelName.display("claude-haiku-4-5-20251001"), "haiku 4.5", "model name with date suffix")
checkEqual(ModelName.display("claude-3-5-sonnet-20241022"), "sonnet 3.5", "legacy order")
checkEqual(ModelName.display("gpt-x"), "gpt-x", "unknown model passes through")
checkEqual(ProjectName.display("-Users-me", home: "/Users/me"), "~", "home folder")
checkEqual(ProjectName.display("-Users-me-claude-notch", home: "/Users/me"), "claude-notch", "folder under home")
checkEqual(ProjectName.display("-opt-thing", home: "/Users/me"), "opt-thing", "outside home")

checkEqual(UsageFormat.tokens(842), "842", "tokens under 1k")
checkEqual(UsageFormat.tokens(9_800), "9.8k", "tokens k one decimal")
checkEqual(UsageFormat.tokens(12_345), "12k", "tokens k")
checkEqual(UsageFormat.tokens(1_240_000), "1.24M", "tokens M")
checkEqual(UsageFormat.tokens(12_300_000), "12.3M", "tokens 10M+")
checkEqual(UsageFormat.tokens(123_000_000), "123M", "tokens 100M+")
checkEqual(UsageFormat.percent(0.618), "62%", "percent rounds")
checkEqual(UsageFormat.percent(1.37), "137%", "percent can exceed 100")
checkEqual(UsageFormat.countdown(2 * 3600 + 14 * 60), "2h 14m", "countdown hours")
checkEqual(UsageFormat.countdown(2 * 3600 + 4 * 60), "2h 04m", "countdown pads minutes")
checkEqual(UsageFormat.countdown(42 * 60), "42m", "countdown minutes")
checkEqual(UsageFormat.countdown(20), "<1m", "countdown seconds")
checkEqual(UsageFormat.longCountdown(3 * 86400 + 4 * 3600), "3d 4h", "long countdown")

checkEqual(UsageLimits.step(3_000_000, up: true), 4_000_000, "ladder up")
checkEqual(UsageLimits.step(3_000_000, up: false), 2_000_000, "ladder down")
checkEqual(UsageLimits.step(3_300_000, up: true), 4_000_000, "ladder up from an off-ladder value")
checkEqual(UsageLimits.step(3_300_000, up: false), 3_000_000, "ladder down from an off-ladder value")
checkEqual(UsageLimits.step(100_000, up: false), 100_000, "ladder floor")
check(UsageLimits.ladder == UsageLimits.ladder.sorted(), "ladder is ascending")

do {
    var tracker = AlertTracker()
    check(tracker.update(blockStart: nil, fraction: 0.9) == nil, "no block, no alert")
    check(tracker.update(blockStart: 100, fraction: 0.5) == nil, "below 75%")
    checkEqual(tracker.update(blockStart: 100, fraction: 0.76), 75, "crossing 75%")
    check(tracker.update(blockStart: 100, fraction: 0.80) == nil, "75% fires once per block")
    checkEqual(tracker.update(blockStart: 100, fraction: 0.91), 90, "crossing 90%")
    check(tracker.update(blockStart: 100, fraction: 1.2) == nil, "90% fires once per block")
    checkEqual(tracker.update(blockStart: 200, fraction: 0.8), 75, "a new block re-arms")
    var jump = AlertTracker()
    checkEqual(jump.update(blockStart: 1, fraction: 0.95), 90, "a jump over both fires only the highest")
    check(jump.update(blockStart: 1, fraction: 0.96) == nil, "and 75% isn't replayed afterwards")
    var quietStart = AlertTracker()
    check(quietStart.update(blockStart: 1, fraction: 0.8, silent: true) == nil, "silent first look")
    check(quietStart.update(blockStart: 1, fraction: 0.81) == nil, "silently recorded crossing stays fired")
    checkEqual(quietStart.update(blockStart: 1, fraction: 0.92), 90, "later thresholds still fire")
}

// MARK: Report

if failures.isEmpty {
    print("PASS: \(passed) checks")
} else {
    for failure in failures { print("FAIL \(failure)") }
    print("\(failures.count) failed, \(passed) passed")
    exit(1)
}
