import Foundation

/// One Claude Code session, as reported by hooks/session_state.py.
struct Session: Identifiable, Equatable {
    enum State: String {
        case idle, working, done, waiting
        case needsInput = "needs-input"

        /// Higher is more urgent. Drives the mascot's mood and what a click opens.
        var urgency: Int {
            switch self {
            case .needsInput: return 4
            case .working: return 3
            case .done: return 2
            case .waiting: return 1
            case .idle: return 0
            }
        }
    }

    let id: String
    var state: State
    var project: String
    var message: String?
    var prompt: String?
    var tty: String?
    var app: String?
    var term: String?
    var pid: Int32?
    var updatedAt: Date
    var turnStartedAt: Date?
    var turnEndedAt: Date?

    /// One line for the overview list.
    var detail: String {
        switch state {
        case .needsInput: return message ?? "Needs your input"
        case .working: return message ?? "Working"
        case .done: return message ?? "Finished"
        case .waiting: return "Waiting for you"
        case .idle: return prompt.map { "Last: \($0)" } ?? "Idle"
        }
    }
}

/// The JSON the hook writes (snake_case on disk).
struct SessionRecord: Decodable {
    let sessionId: String
    let state: String
    let project: String?
    let message: String?
    let prompt: String?
    let tty: String?
    let app: String?
    let term: String?
    let pid: Int32?
    let updatedAt: Double
    let turnStartedAt: Double?
    let turnEndedAt: Double?
}

extension Session {
    init?(record r: SessionRecord) {
        guard let state = State(rawValue: r.state) else { return nil }
        self.init(
            id: r.sessionId, state: state, project: r.project ?? "claude",
            message: r.message, prompt: r.prompt, tty: r.tty, app: r.app, term: r.term, pid: r.pid,
            updatedAt: Date(timeIntervalSince1970: r.updatedAt),
            turnStartedAt: r.turnStartedAt.map { Date(timeIntervalSince1970: $0) },
            turnEndedAt: r.turnEndedAt.map { Date(timeIntervalSince1970: $0) })
    }
}

struct SessionEvent {
    enum Kind { case done, needsInput }
    let kind: Kind
    let session: Session
}

enum Clock {
    /// Duration style: 42s, 3m 07s, 1h 02m. Never mistakable for a clock time.
    static func timer(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        if s >= 60 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return "\(s)s"
    }

    /// Relative style: now, 4m, 2h, 3d.
    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
