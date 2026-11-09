import Foundation

/// "Fetch fresh numbers when stale" (off unless turned on): when a plan is
/// over 15 minutes old, or missing, the AIs' own commands are asked for it.
/// - Claude: `claude -p` in stream-json answers a `get_usage` control request.
///   No prompt is sent, so nothing is billed; it starts without settings,
///   hooks or MCP, once per account (CLAUDE_CONFIG_DIR), and is closed after.
/// - Antigravity: `agy -p /usage` prints the plan table; the slash command
///   runs in the CLI and starts no conversation.
/// Both run in an empty temp folder, off the main thread, with a time limit,
/// and are ended when Paceline quits. Paceline never reads their tokens.
enum FreshLimits {
    /// Older than this, a plan is asked for again; and no one is asked more often.
    static let every: TimeInterval = 15 * 60

    struct Target: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case claude(configDir: String?)     // nil: the main account (~/.claude)
            case antigravity
        }
        let id: String                          // "claude", an extra account's id, "antigravity"
        let kind: Kind
        let at: Date?                           // when its plan was saved, if it was
    }

    /// Who to ask now: a missing or 15-minute-old plan, not asked in the last 15 minutes.
    static func due(_ targets: [Target], lastAsked: [String: Date], now: Date = Date()) -> [Target] {
        targets.filter { target in
            (target.at.map { now.timeIntervalSince($0) >= every } ?? true)
                && (lastAsked[target.id].map { now.timeIntervalSince($0) >= every } ?? true)
        }
    }

    // MARK: - Commands

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var claudeCommand: String? {
        ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first(where: FileManager.default.isExecutableFile)
    }

    static var agyCommand: String? {
        ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"].first(where: FileManager.default.isExecutableFile)
    }

    /// Asks and saves. Blocks: call off the main thread.
    static func fetch(_ target: Target) {
        switch target.kind {
        case .claude(let configDir):
            guard let command = claudeCommand, let limits = askClaude(command, configDir: configDir),
                  let windows = windows(fromUsage: limits) else { return }
            PlanUsageReader.save(windows, to: target.id == "claude" ? PlanUsageReader.ownClaudeFile : PlanUsageReader.claudeFile(account: target.id),
                                 fetched: true)
        case .antigravity:
            guard let command = agyCommand,
                  let table = run(command, ["-p", "/usage", "--print-timeout", "20s"], timeout: 25),
                  table.contains("%"),
                  let data = try? JSONSerialization.data(withJSONObject: ["at": Date().timeIntervalSince1970, "table": table, "fetched": true] as [String: Any]) else { return }
            let file = PlanUsageReader.ownAntigravityFile
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// `get_usage`'s `rate_limits` as the status line saves them:
    /// `{"five_hour": {"utilization": 66, "resets_at": "2026-11-08T06:40:00.28+00:00"}, …}`
    /// → `{"five_hour": {"used": 66, "resets_at": 1794119200}, …}`; nil when it's empty
    /// (it can be, right after the account's first request).
    static func windows(fromUsage limits: [String: Any]) -> [String: Any]? {
        let iso = ISO8601DateFormatter(), fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let window = limits[key] as? [String: Any], let used = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
            var entry: [String: Any] = ["used": used]
            if let stamp = window["resets_at"] as? String, let date = fractions.date(from: stamp) ?? iso.date(from: stamp) {
                entry["resets_at"] = date.timeIntervalSince1970
            }
            out[key] = entry
        }
        return out.isEmpty ? nil : out
    }

    /// The `rate_limits` from a `control_response` line answering `id`, if this is it.
    static func rateLimits(inLine line: Data, id: String) -> [String: Any]? {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              message["type"] as? String == "control_response",
              let response = message["response"] as? [String: Any], response["request_id"] as? String == id else { return nil }
        return (response["response"] as? [String: Any])?["rate_limits"] as? [String: Any] ?? [:]
    }

    private static func askClaude(_ command: String, configDir: String?, timeout: TimeInterval = 20) -> [String: Any]? {
        var environment = ProcessInfo.processInfo.environment
        // The main account is no CLAUDE_CONFIG_DIR at all (an empty one would make the temp folder the config).
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir } else { environment.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        let id = "paceline-\(UUID().uuidString.prefix(8))"
        let request = #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"get_usage"}}"# + "\n"
        var found: [String: Any]?
        _ = run(command, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                          "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config"],
                environment: environment, input: Data(request.utf8), timeout: timeout) { line in
            found = autoreleasepool { rateLimits(inLine: line, id: id) }
            return found != nil
        }
        return found
    }

    /// Runs a command in an empty temp folder and returns what it printed, or
    /// nil past the time limit. `onLine` sees each line and can end it early.
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
                            timeout: TimeInterval, onLine: ((Data) -> Bool)? = nil) -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-ask-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        if let environment { process.environment = environment }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        Running.shared.add(process)
        defer {
            try? stdin.fileHandleForWriting.close()
            ProcessDeadline.end(process)
            Running.shared.remove(process)
        }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) } else { try? stdin.fileHandleForWriting.close() }

        var pending = Data(), answered = false
        let (all, timedOut) = PipeReader.read(stdout.fileHandleForReading, until: Date().addingTimeInterval(timeout)) { chunk in
            guard let onLine else { return false }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if onLine(Data(line)) { answered = true; return true }
            }
            return false
        }
        if answered { return String(decoding: all, as: UTF8.self) }
        if timedOut { return nil }
        process.waitUntilExit()
        return process.terminationReason == .exit ? String(decoding: all, as: UTF8.self) : nil
    }

    /// Ends whatever is still being asked (Paceline is quitting).
    static func stopAll() { Running.shared.terminateAll() }
}

/// Ending a command that ran past its time: SIGTERM, then SIGKILL 3 s later
/// if it's still there.
enum ProcessDeadline {
    static func end(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Reads a command's output up to a deadline with poll(), so the time limit
/// holds even when the command, or something it started, keeps the pipe open
/// (a blocking read would wait for every holder to close it).
enum PipeReader {
    /// Everything read, and whether the deadline came first. `onChunk` sees
    /// each piece and returning true stops reading.
    static func read(_ handle: FileHandle, until deadline: Date, onChunk: (Data) -> Bool = { _ in false }) -> (data: Data, timedOut: Bool) {
        var all = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var fds = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return (all, true) }
            let ready = poll(&fds, 1, Int32(min(left * 1000, 1000)))
            if ready < 0 && errno != EINTR { return (all, false) }
            guard ready > 0 else { continue }
            let count = Foundation.read(fds.fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return (all, false) }   // the end, or an error
            let chunk = Data(buffer[0..<count])
            all.append(chunk)
            if onChunk(chunk) { return (all, false) }
        }
    }
}

/// The commands running now, so quitting can end them.
private final class Running: @unchecked Sendable {
    static let shared = Running()
    private let lock = NSLock()
    private var processes: [Process] = []

    func add(_ process: Process) { lock.withLock { processes.append(process) } }
    func remove(_ process: Process) { lock.withLock { processes.removeAll { $0 === process } } }
    func terminateAll() { lock.withLock { processes.filter(\.isRunning).forEach { $0.terminate() } } }
}
