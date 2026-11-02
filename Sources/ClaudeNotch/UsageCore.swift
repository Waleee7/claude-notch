import Foundation

// Usage engine: transcript parsing, incremental scanning and aggregation.
// Foundation only, so scripts/test.sh and Tools/usage_summary can compile it on its own.
//
// Source: Claude Code transcripts, ~/.claude/projects/**/*.jsonl. Everything stays local;
// nothing here touches the network, claude.ai or any credentials.

// MARK: - Tokens

struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite + cacheRead }

    /// What the limit percentages are measured in. Cache reads are cheap, repeat the same
    /// context every turn and run into the tens of millions, so they're off by default.
    func counted(includeCacheReads: Bool) -> Int {
        input + output + cacheWrite + (includeCacheReads ? cacheRead : 0)
    }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output,
                    cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    /// Streamed duplicates of one message report growing output counts; keep the largest of each field.
    mutating func formMax(_ other: TokenCounts) {
        input = max(input, other.input)
        output = max(output, other.output)
        cacheWrite = max(cacheWrite, other.cacheWrite)
        cacheRead = max(cacheRead, other.cacheRead)
    }
}

struct UsageEntry: Equatable {
    var time: TimeInterval  // seconds since 1970
    var model: String
    var project: String     // folder name under ~/.claude/projects
    var tokens: TokenCounts
}

// MARK: - Parser

struct ParsedUsageLine: Equatable {
    let key: String
    let time: TimeInterval
    let model: String
    let tokens: TokenCounts
}

enum TranscriptParser {
    private static let needle: [UInt8] = Array("\"output_tokens\"".utf8)

    /// Cheap byte search so the (many, large) lines without usage are never JSON-decoded.
    static func mightContainUsage(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, bytes.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, $0.count) != nil }
    }

    /// One transcript line to a usage record, or nil for anything that isn't a usable assistant entry.
    static func parse(_ line: Data) -> ParsedUsageLine? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let time = parseTimestamp(stamp) else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        if model == "<synthetic>" { return nil }  // Claude Code's own placeholder messages

        func count(_ name: String) -> Int {
            guard let n = usage[name] as? NSNumber else { return 0 }
            return max(0, n.intValue)
        }
        let tokens = TokenCounts(input: count("input_tokens"), output: count("output_tokens"),
                                 cacheWrite: count("cache_creation_input_tokens"),
                                 cacheRead: count("cache_read_input_tokens"))
        if tokens.total == 0 { return nil }

        // Streamed entries repeat the same message; message.id (+ requestId) identifies it.
        let request = (object["requestId"] as? String) ?? ""
        let key: String
        if let id = message["id"] as? String, !id.isEmpty {
            key = id + "|" + request
        } else if let uuid = object["uuid"] as? String {
            key = "uuid:" + uuid
        } else {
            return nil
        }
        return ParsedUsageLine(key: key, time: time, model: model, tokens: tokens)
    }

    /// ISO-8601 with optional fractional seconds and a Z or ±hh:mm offset. Hand-rolled because
    /// a formatter object is the slowest part of a full scan.
    static func parseTimestamp(_ text: String) -> TimeInterval? {
        let b = Array(text.utf8)
        guard b.count >= 19, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20,
              b[13] == 0x3A, b[16] == 0x3A else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                guard i < b.count, b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                v = v * 10 + Int(b[i] - 0x30)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                fraction += Double(b[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
            let sign = b[i] == 0x2B ? 1 : -1
            guard let oh = num(i + 1, 2) else { return nil }
            let om = (i + 3 < b.count && b[i + 3] == 0x3A ? num(i + 4, 2) : num(i + 3, 2)) ?? 0
            offset = sign * (oh * 3600 + om * 60)
        }
        // Days from civil (Howard Hinnant): proleptic Gregorian, no calendar object needed.
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return TimeInterval(days * 86400 + h * 3600 + mi * 60 + s - offset) + fraction
    }
}

// MARK: - Incremental scanner

struct ScanStats: Equatable {
    var filesSeen = 0
    var filesRead = 0
    var bytesRead: Int64 = 0
    var lines = 0
    var candidateLines = 0
    /// Lines that mention usage but weren't a countable assistant entry: malformed, synthetic, zero.
    var rejected = 0
    var entries = 0
    var seconds: Double = 0
}

/// Streams transcripts line by line and remembers a byte offset per file, so a refresh only
/// reads what was appended. Not thread-safe: use it from one serial queue.
final class TranscriptScanner {
    let root: URL
    /// History worth keeping. Files untouched for longer than this are never opened; the
    /// aggregator needs the current week plus enough lead-in to chain 5-hour blocks.
    let maxAge: TimeInterval

    private struct FileState {
        var inode: UInt64
        var offset: Int64
    }

    private var files: [String: FileState] = [:]
    private(set) var entries: [UsageEntry] = []
    private var keys: [String] = []
    private var index: [String: Int] = [:]
    private var interned: [String: String] = [:]
    private var lastPrune = Date()

    private static let chunk = 1 << 20
    private var buffer = UnsafeMutableRawPointer.allocate(byteCount: TranscriptScanner.chunk * 2, alignment: 16)
    private var capacity = TranscriptScanner.chunk * 2

    init(root: URL, maxAge: TimeInterval = 10 * 86400) {
        self.root = root
        self.maxAge = maxAge
    }

    deinit { buffer.deallocate() }

    @discardableResult
    func scan(now: Date = Date()) -> ScanStats {
        let started = Date()
        var stats = ScanStats()
        let cutoff = now.timeIntervalSince1970 - maxAge
        var seen = Set<String>()

        let rootPath = root.standardizedFileURL.path
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if url.lastPathComponent == "tool-results" { walker.skipDescendants(); continue }
                guard url.pathExtension == "jsonl" else { continue }
                let path = url.standardizedFileURL.path
                var info = stat()
                guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                stats.filesSeen += 1
                seen.insert(path)

                let inode = UInt64(info.st_ino)
                let size = Int64(info.st_size)
                var state = files[path]
                if let known = state, known.inode != inode || size < known.offset {
                    state = nil  // replaced or truncated: read again (duplicates merge by key)
                }
                if state == nil, TimeInterval(info.st_mtimespec.tv_sec) < cutoff { continue }
                let offset = state?.offset ?? 0
                guard size > offset || state == nil else { continue }

                let project = Self.project(of: path, root: rootPath)
                let consumed = read(path: path, from: offset, project: project, cutoff: cutoff, stats: &stats)
                files[path] = FileState(inode: inode, offset: consumed)
                stats.filesRead += 1
            }
        }
        for path in files.keys where !seen.contains(path) { files[path] = nil }
        if now.timeIntervalSince(lastPrune) > 3600 { prune(before: cutoff, now: now) }

        stats.entries = entries.count
        stats.seconds = Date().timeIntervalSince(started)
        return stats
    }

    /// The folder directly under the projects root (sessions and subagents both live below it).
    static func project(of path: String, root: String) -> String {
        guard path.hasPrefix(root + "/") else { return "unknown" }
        let rest = path.dropFirst(root.count + 1)
        return rest.firstIndex(of: "/").map { String(rest[..<$0]) } ?? "unknown"
    }

    // MARK: Reading

    /// Returns the offset just past the last complete line. A trailing partial line (a write in
    /// flight) is parsed speculatively but not consumed, so it's read again once finished.
    private func read(path: String, from offset: Int64, project: String, cutoff: TimeInterval, stats: inout ScanStats) -> Int64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return offset }
        defer { close(fd) }

        let project = intern(project)
        var bufferStart = offset  // file offset of buffer[0]
        var length = 0
        var scanned = 0
        while true {
            if capacity - length < Self.chunk { grow(to: capacity * 2) }
            let n = pread(fd, buffer + length, capacity - length, off_t(bufferStart + Int64(length)))
            if n <= 0 { break }
            length += n
            stats.bytesRead += Int64(n)

            var lineStart = 0
            while scanned < length, let hit = memchr(buffer + scanned, 0x0A, length - scanned) {
                let end = buffer.distance(to: hit)
                handle(line: UnsafeRawBufferPointer(start: buffer + lineStart, count: end - lineStart),
                       project: project, cutoff: cutoff, stats: &stats)
                lineStart = end + 1
                scanned = lineStart
            }
            if lineStart > 0 {
                memmove(buffer, buffer + lineStart, length - lineStart)
                bufferStart += Int64(lineStart)
                length -= lineStart
            }
            scanned = length
        }
        if length > 0 {
            handle(line: UnsafeRawBufferPointer(start: buffer, count: length), project: project, cutoff: cutoff, stats: &stats)
        }
        if capacity > Self.chunk * 16 { shrink() }  // one enormous line shouldn't pin memory forever
        return bufferStart
    }

    private func handle(line: UnsafeRawBufferPointer, project: String, cutoff: TimeInterval, stats: inout ScanStats) {
        guard line.count > 2 else { return }
        stats.lines += 1
        guard TranscriptParser.mightContainUsage(line) else { return }
        stats.candidateLines += 1
        guard let parsed = TranscriptParser.parse(Data(bytes: line.baseAddress!, count: line.count)) else {
            stats.rejected += 1
            return
        }
        guard parsed.time >= cutoff else { return }
        if let i = index[parsed.key] {
            entries[i].tokens.formMax(parsed.tokens)
            entries[i].time = min(entries[i].time, parsed.time)
        } else {
            index[parsed.key] = entries.count
            keys.append(parsed.key)
            entries.append(UsageEntry(time: parsed.time, model: intern(parsed.model), project: project, tokens: parsed.tokens))
        }
    }

    private func intern(_ s: String) -> String {
        if let known = interned[s] { return known }
        interned[s] = s
        return s
    }

    private func grow(to newCapacity: Int) {
        let next = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 16)
        memcpy(next, buffer, capacity)
        buffer.deallocate()
        buffer = next
        capacity = newCapacity
    }

    private func shrink() {
        buffer.deallocate()
        capacity = Self.chunk * 2
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    /// Entries older than the retention window age out so a long-running app doesn't grow.
    private func prune(before cutoff: TimeInterval, now: Date) {
        lastPrune = now
        guard entries.contains(where: { $0.time < cutoff }) else { return }
        var keptEntries: [UsageEntry] = []
        var keptKeys: [String] = []
        for (entry, key) in zip(entries, keys) where entry.time >= cutoff {
            keptEntries.append(entry)
            keptKeys.append(key)
        }
        entries = keptEntries
        keys = keptKeys
        index = Dictionary(uniqueKeysWithValues: keptKeys.enumerated().map { ($1, $0) })
    }
}

// MARK: - Aggregation

struct UsageConfig: Equatable {
    var fiveHourLimit = 3_000_000
    var weeklyLimit = 30_000_000
    /// Calendar weekday the week begins on: 1 = Sunday ... 7 = Saturday. Default Monday.
    var weekStartDay = 2
    var includeCacheReads = false
}

struct UsageTotals: Equatable {
    var tokens = TokenCounts()
    var messages = 0

    mutating func add(_ entry: UsageEntry) {
        tokens += entry.tokens
        messages += 1
    }
}

struct UsageBlock: Equatable {
    var start: Date
    var end: Date
    var totals = UsageTotals()
    var lastActivity: Date
}

struct UsageBreakdown: Equatable, Identifiable {
    var name: String
    var tokens: TokenCounts
    var counted: Int
    var messages: Int
    var id: String { name }
}

struct UsageSnapshot: Equatable {
    var now: Date
    var config: UsageConfig
    var today = UsageTotals()
    var week = UsageTotals()
    var weekStart: Date
    var weekEnd: Date
    var last7Days = UsageTotals()
    var block: UsageBlock?
    var models: [UsageBreakdown] = []    // this week, largest first
    var projects: [UsageBreakdown] = []  // this week, largest first
    var activeNow = false
    var lastActivity: Date?

    var blockCounted: Int { block?.totals.tokens.counted(includeCacheReads: config.includeCacheReads) ?? 0 }
    var weekCounted: Int { week.tokens.counted(includeCacheReads: config.includeCacheReads) }
    var todayCounted: Int { today.tokens.counted(includeCacheReads: config.includeCacheReads) }

    /// 1.0 = at the (user-set) limit. Can exceed 1.
    var blockFraction: Double { config.fiveHourLimit > 0 ? Double(blockCounted) / Double(config.fiveHourLimit) : 0 }
    var weekFraction: Double { config.weeklyLimit > 0 ? Double(weekCounted) / Double(config.weeklyLimit) : 0 }

    var blockRemaining: TimeInterval? { block.map { max(0, $0.end.timeIntervalSince(now)) } }
}

enum UsageAggregator {
    static let blockLength: TimeInterval = 5 * 3600
    static let activeWindow: TimeInterval = 120

    /// Blocks follow the convention popular usage tools use: a block opens at the first
    /// message after the previous block ended, floored to the hour (UTC), and runs 5 hours.
    /// The block is active while `now` is before its end.
    static func blocks(from sorted: [UsageEntry]) -> [UsageBlock] {
        var result: [UsageBlock] = []
        for entry in sorted {
            let time = Date(timeIntervalSince1970: entry.time)
            if let last = result.last, time < last.end {
                result[result.count - 1].totals.add(entry)
                result[result.count - 1].lastActivity = time
            } else {
                let start = Date(timeIntervalSince1970: (entry.time / 3600).rounded(.down) * 3600)
                var block = UsageBlock(start: start, end: start.addingTimeInterval(blockLength), lastActivity: time)
                block.totals.add(entry)
                result.append(block)
            }
        }
        return result
    }

    static func weekStart(containing now: Date, calendar: Calendar, startDay: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let back = ((weekday - startDay) % 7 + 7) % 7
        return calendar.date(byAdding: .day, value: -back, to: today) ?? today
    }

    private struct Breakdowns {
        var rows: [String: UsageBreakdown] = [:]

        mutating func add(_ name: String, _ entry: UsageEntry, cache: Bool) {
            var row = rows[name] ?? UsageBreakdown(name: name, tokens: TokenCounts(), counted: 0, messages: 0)
            row.tokens += entry.tokens
            row.counted += entry.tokens.counted(includeCacheReads: cache)
            row.messages += 1
            rows[name] = row
        }

        var sorted: [UsageBreakdown] {
            rows.values.sorted { $0.counted != $1.counted ? $0.counted > $1.counted : $0.name < $1.name }
        }
    }

    static func snapshot(entries: [UsageEntry], now: Date, calendar: Calendar = .current,
                         config: UsageConfig = UsageConfig(), home: String = NSHomeDirectory()) -> UsageSnapshot {
        let nowT = now.timeIntervalSince1970
        let startOfToday = calendar.startOfDay(for: now)
        let weekStart = weekStart(containing: now, calendar: calendar, startDay: config.weekStartDay)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart.addingTimeInterval(7 * 86400)
        let last7Start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday.addingTimeInterval(-6 * 86400)

        var snap = UsageSnapshot(now: now, config: config, weekStart: weekStart, weekEnd: weekEnd)
        var models = Breakdowns()
        var projects = Breakdowns()
        let live = entries.filter { $0.time <= nowT + 60 }  // clock-skewed future entries don't count

        for entry in live {
            let date = Date(timeIntervalSince1970: entry.time)
            if date >= startOfToday { snap.today.add(entry) }
            if date >= last7Start { snap.last7Days.add(entry) }
            guard date >= weekStart else { continue }
            snap.week.add(entry)
            models.add(ModelName.display(entry.model), entry, cache: config.includeCacheReads)
            projects.add(ProjectName.display(entry.project, home: home), entry, cache: config.includeCacheReads)
        }
        snap.models = models.sorted
        snap.projects = projects.sorted

        let ordered = live.sorted { $0.time < $1.time }
        if let last = ordered.last {
            snap.lastActivity = Date(timeIntervalSince1970: last.time)
            snap.activeNow = nowT - last.time <= activeWindow
            if let block = blocks(from: ordered).last, block.end > now { snap.block = block }
        }
        return snap
    }
}

// MARK: - Names

enum ModelName {
    /// claude-opus-5-5 -> "opus 5.5", claude-3-5-sonnet-20241022 -> "sonnet 3.5".
    static func display(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard let family = parts.first(where: { ["opus", "sonnet", "haiku"].contains($0) }) else {
            return id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
        }
        let version = parts.filter { $0.count <= 2 && Int($0) != nil }.joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }
}

enum ProjectName {
    /// Claude Code names a project folder after its path with "/" and "." turned into "-".
    static func display(_ folder: String, home: String) -> String {
        let encodedHome = String(home.map { $0 == "/" || $0 == "." ? "-" : $0 })
        if folder == encodedHome { return "~" }
        if folder.hasPrefix(encodedHome + "-") { return String(folder.dropFirst(encodedHome.count + 1)) }
        return folder.hasPrefix("-") ? String(folder.dropFirst()) : folder
    }
}

// MARK: - Formatting & limits

enum UsageFormat {
    /// 842, 9.8k, 12k, 1.24M, 12.3M, 123M, 1.20B.
    static func tokens(_ n: Int) -> String {
        let v = Double(max(0, n))
        func trim(_ x: Double, _ unit: String) -> String {
            let digits = x < 10 ? 2 : (x < 100 ? 1 : 0)
            return String(format: "%.\(digits)f", x) + unit
        }
        if v < 1000 { return "\(Int(v))" }
        if v < 10_000 { return String(format: "%.1fk", v / 1000) }
        if v < 1_000_000 { return String(format: "%.0fk", v / 1000) }
        if v < 1_000_000_000 { return trim(v / 1_000_000, "M") }
        return trim(v / 1_000_000_000, "B")
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// 2h 14m, 42m, <1m.
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        if s >= 60 { return "\(s / 60)m" }
        return s > 0 ? "<1m" : "0m"
    }

    /// 3d 4h, 5h 20m: reset countdowns that can span days.
    static func longCountdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        return countdown(seconds)
    }
}

enum UsageLimits {
    /// 1-2-5 style ladder the settings steppers walk, so any stored value still has a neighbour.
    static let ladder: [Int] = {
        var out: [Int] = []
        var decade = 100_000
        while decade <= 1_000_000_000 {
            out += [decade, decade * 3 / 2, decade * 2, decade * 3, decade * 4, decade * 5, decade * 15 / 2]
            decade *= 10
        }
        return out
    }()

    static func step(_ value: Int, up: Bool) -> Int {
        if up { return ladder.first(where: { $0 > value }) ?? ladder.last! }
        return ladder.last(where: { $0 < value }) ?? ladder.first!
    }
}

// MARK: - Alerts

/// Decides when the 75% / 90% notifications fire: once per block per threshold, and only
/// the highest one when a jump crosses both.
struct AlertTracker: Equatable {
    var blockStart: TimeInterval?
    var fired: Set<Int> = []

    static let thresholds = [75, 90]

    /// `silent` records crossings without returning them (first look after launch, so a restart
    /// doesn't replay a warning the user already saw).
    mutating func update(blockStart start: TimeInterval?, fraction: Double, silent: Bool = false) -> Int? {
        if start != blockStart {
            blockStart = start
            fired = []
        }
        guard start != nil else { return nil }
        let crossed = Self.thresholds.filter { fraction * 100 >= Double($0) && !fired.contains($0) }
        fired.formUnion(crossed)
        return silent ? nil : crossed.max()
    }
}
