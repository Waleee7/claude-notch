import Foundation

/// Watches ~/.claude/mascot/sessions (written by the hook) and reports the live
/// session list plus the transitions worth a pop-down.
@MainActor
final class SessionStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/mascot/sessions", isDirectory: true)

    var onChange: (([Session], [SessionEvent]) -> Void)?

    private var known: [String: Session] = [:]
    private var primed = false
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        watchDirectory()
        // The watcher catches every atomic rename; the slow poll keeps stale-session
        // cleanup honest even if an event slips through.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private func watchDirectory() {
        let fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func reload() {
        let now = Date()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []

        var current: [String: Session] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(SessionRecord.self, from: data),
                  var session = Session(record: record) else { continue }
            if let pid = session.pid, pid > 0, kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(at: url)  // Claude exited without SessionEnd (closed tab, crash)
                continue
            }
            let age = now.timeIntervalSince(session.updatedAt)
            if age > 12 * 3600 { continue }
            // Stop never fires on Esc-interrupt, so a long-silent "working" is really idle.
            if session.state == .working && age > 15 * 60 { session.state = .idle }
            current[session.id] = session
        }

        var events: [SessionEvent] = []
        if primed {
            for session in current.values {
                let before = known[session.id]
                switch session.state {
                case .done where before != nil && before?.state != .done:
                    events.append(SessionEvent(kind: .done, session: session))
                case .needsInput where before?.state != .needsInput || before?.message != session.message:
                    events.append(SessionEvent(kind: .needsInput, session: session))
                default:
                    break
                }
            }
        }

        let changed = !primed || current != known
        known = current
        primed = true
        if changed { onChange?(Self.ranked(current.values), events) }
    }

    static func ranked<S: Sequence>(_ sessions: S) -> [Session] where S.Element == Session {
        sessions.sorted {
            $0.state.urgency != $1.state.urgency
                ? $0.state.urgency > $1.state.urgency
                : $0.updatedAt > $1.updatedAt
        }
    }
}
