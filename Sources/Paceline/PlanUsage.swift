import Foundation

/// One window of a subscription plan: the five hours or the week.
struct PlanWindow: Equatable, Identifiable, Sendable {
    let label: String       // "5h" (or "Day" for a daily limit) or "Week"
    let left: Int           // percent left, 0–100
    let resets: Date?
    var wasReset = false    // reset since it was saved: assumed full, but nothing new is known

    var id: String { label }

    /// "resets in 1h 42m" today, "resets Thu 14:00" further off.
    func resetText(now: Date = Date()) -> String? {
        guard let resets, resets > now else { return nil }
        let seconds = Int(resets.timeIntervalSince(now))
        if seconds < 3600 { return "resets in \(max(1, seconds / 60))m" }
        if seconds < 12 * 3600 { return "resets in \(seconds / 3600)h \(seconds % 3600 / 60)m" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_GB")
        format.dateFormat = "EEE HH:mm"
        return "resets \(format.string(from: resets))"
    }
}

extension PlanWindow {
    /// How a window is going at the rate used since it started.
    enum Pace: Equatable, Sendable {
        case onPace
        case runsOut(in: TimeInterval)   // before it resets
    }

    /// 5 hours, a day or 7 days, from the label.
    var length: TimeInterval? { ["5h": 5 * 3600, "Day": 86400, "Week": 7 * 86400][label] }

    /// "5-hour", "daily", "weekly", for notifications and VoiceOver.
    static func spokenName(_ label: String) -> String { label == "5h" ? "5-hour" : label == "Day" ? "daily" : "weekly" }

    /// The last fifth of a window (the last hour of five) is what "lately" means.
    static let recentShare = 0.2

    /// The rate it's being used at, carried forward: half the average since the
    /// window began, half the rate lately (`samples`, the readings seen this
    /// round; with none, lately is the average, as before). It runs out if
    /// that empties it at least max(15 min, 5% of the window) before the
    /// reset; closer than that is on pace, and so is nothing used lately (it
    /// was used, then stopped). nil when there's too little to go on: no reset
    /// time, under a quarter of the way in, nothing used, or nothing left (it
    /// has run out; 0% says so, "runs out in 1m" wouldn't).
    /// (Old data is the caller's call: `PlanUsage.isStale`.)
    func pace(now: Date = Date(), samples: [PaceSample] = []) -> Pace? {
        guard let resets, let length, resets > now else { return nil }
        let elapsed = length - resets.timeIntervalSince(now), used = Double(100 - left)
        guard elapsed >= length * 0.25, used > 0, left > 0 else { return nil }
        // Lately: since the newest reading at least a fifth of the window old.
        // The window's start (0% used) always is one, being a quarter in.
        let start = PaceSample(at: resets.addingTimeInterval(-length), used: 0)
        let cutoff = now.addingTimeInterval(-length * Self.recentShare)
        let base = samples.filter { $0.at > start.at && $0.at <= cutoff && $0.used <= 100 - left }
            .max { $0.at < $1.at } ?? start
        let recent = (used - Double(base.used)) / now.timeIntervalSince(base.at)
        guard recent > 0 else { return .onPace }
        let runsOut = (100 - used) / ((used / elapsed + recent) / 2)
        return resets.timeIntervalSince(now) - runsOut >= max(15 * 60, length * 0.05) ? .runsOut(in: runsOut) : .onPace
    }

    /// "45m", "1h 20m", "2d 3h".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

/// One reading of a window: how much was used, and when it was saved.
struct PaceSample: Equatable, Sendable {
    let at: Date
    let used: Int
}

/// The readings seen this round of each plan's windows, kept in memory only:
/// one every 1% of the window at most (3 minutes of five hours), 40 at most.
/// A new round (another reset time) starts over.
struct PaceLog: Sendable {
    static let kept = 40
    private var rounds: [String: (resets: Date, samples: [PaceSample])] = [:]

    private static func key(_ plan: PlanUsage, _ window: PlanWindow) -> String { "\(plan.id)|\(window.label)" }

    /// These plans' readings added.
    func recording(_ plans: [PlanUsage]) -> PaceLog {
        var out = self
        for plan in plans {
            for window in plan.windows where !window.wasReset {
                guard let resets = window.resets, let length = window.length else { continue }
                let key = Self.key(plan, window), sample = PaceSample(at: plan.at, used: 100 - window.left)
                // The same round, give or take a few minutes of rounding.
                var samples = out.rounds[key].flatMap { abs($0.resets.timeIntervalSince(resets)) < 600 ? $0.samples : nil } ?? []
                if let last = samples.last {
                    guard sample.at > last.at else { continue }
                    // The newest stands in for its 1% until a new one is due.
                    if samples.count >= 2, last.at.timeIntervalSince(samples[samples.count - 2].at) < length * 0.01 {
                        samples[samples.count - 1] = sample
                    } else {
                        samples.append(sample)
                    }
                } else {
                    samples = [sample]
                }
                out.rounds[key] = (resets, Array(samples.suffix(Self.kept)))
            }
        }
        return out
    }

    /// These plans with their windows' readings, for `PlanUsage.pace`.
    func attached(to plans: [PlanUsage]) -> [PlanUsage] {
        plans.map { plan in
            var plan = plan
            for window in plan.windows {
                guard let resets = window.resets, let round = rounds[Self.key(plan, window)],
                      abs(round.resets.timeIntervalSince(resets)) < 600 else { continue }
                plan.paceSamples[window.label] = round.samples
            }
            return plan
        }
    }
}

/// What's left of one agent's plan, or of one model group in it.
struct PlanUsage: Equatable, Identifiable, Sendable {
    let agent: String
    var group: String?
    let windows: [PlanWindow]
    let at: Date
    /// Saved by Paceline asking the AI itself (Fetch fresh numbers), not by
    /// using it: its time says nothing about which AI was used last.
    var fetched = false
    /// The plan's name where the log gives it (Codex: "Team").
    var planName: String?
    /// Earlier readings this round, per window label, for the pace (`PaceLog`).
    var paceSamples: [String: [PaceSample]] = [:]

    var id: String { group.map { "\(agent) \($0)" } ?? agent }
    var title: String { group.map { "\(agent) · \($0)" } ?? agent }
    func window(_ label: String) -> PlanWindow? { windows.first { $0.label == label } }
    /// The short window: five hours, or a day where that's the limit (Windsurf).
    var shortWindow: PlanWindow? { window("5h") ?? window("Day") }

    /// Six hours without an update: shown dimmed, with its age.
    static let staleAfter: TimeInterval = 6 * 3600
    func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(at) >= Self.staleAfter }

    /// A window's pace, unless this plan's data is old.
    func pace(_ window: PlanWindow, now: Date = Date()) -> PlanWindow.Pace? {
        isStale(now: now) ? nil : window.pace(now: now, samples: paceSamples[window.label] ?? [])
    }

    /// "as of 12 min ago" once it's 15 minutes old.
    func age(now: Date = Date()) -> String? {
        let seconds = now.timeIntervalSince(at)
        guard seconds >= 15 * 60 else { return nil }
        if seconds < 3600 { return "as of \(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "as of \(Int(seconds / 3600)) h ago" }
        return "as of \(Int(seconds / 86400)) d ago"
    }
}

/// Plan limits come from files on this Mac, never from the network:
/// - Claude: the `rate_limits` Claude Code passes to its status line, saved by
///   `Paceline --statusline` (or by Pixpaw's status line, if that's installed).
/// - Extra Claude accounts (`ClaudeAccounts`, each its own CLAUDE_CONFIG_DIR): saved
///   by `--statusline` run under that folder or by `--claude-limits <id>` from `-p` runs.
/// - Antigravity: the `/usage` table Pixpaw's plugin saves, if present.
/// - Codex: the `rate_limits` of the newest `token_count` in its session logs
///   (~/.codex/sessions/YYYY/MM/DD/*.jsonl). The desktop app fetches them live
///   and doesn't save them, so with only the app there's nothing to read.
enum PlanUsageReader {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let ownClaudeFile = home.appendingPathComponent("Library/Caches/Paceline/claude-usage.json")
    /// Where this app saved them as AgentPet; still read while an old copy writes there.
    static let legacyDir = home.appendingPathComponent("Library/Caches/AgentPet")
    static let pixpawClaudeFile = home.appendingPathComponent("Library/Caches/Pixpaw/claude-usage.json")
    /// Ours, AgentPet's (only where AgentPet was), then Pixpaw's status line's.
    static func claudeFiles(legacy: Bool = Legacy.agentPetWasHere) -> [URL] {
        [ownClaudeFile] + (legacy ? [legacyDir.appendingPathComponent("claude-usage.json")] : []) + [pixpawClaudeFile]
    }
    static var claudeFiles: [URL] { claudeFiles() }
    /// `claude-usage-<account>.json` next to the main file.
    static func claudeFile(account: String) -> URL {
        ownClaudeFile.deletingLastPathComponent().appendingPathComponent("claude-usage-\(account).json")
    }
    /// That file and its AgentPet-era twin.
    static func claudeFiles(account: String, legacy: Bool = Legacy.agentPetWasHere) -> [URL] {
        [claudeFile(account: account)] + (legacy ? [legacyDir.appendingPathComponent("claude-usage-\(account).json")] : [])
    }
    /// `agy -p /usage`'s table, as Paceline saved it (Fetch fresh numbers), then as Pixpaw's plugin did.
    static let ownAntigravityFile = ownClaudeFile.deletingLastPathComponent().appendingPathComponent("antigravity-usage.json")
    static let antigravityFiles = [ownAntigravityFile, home.appendingPathComponent("Library/Application Support/Pixpaw/antigravity-usage.json")]
    /// Older than this, a reading is dropped.
    static let keptFor: TimeInterval = 7 * 86400

    static func all(now: Date = Date(), accounts: [ClaudeAccount] = ClaudeAccounts.load()) -> [PlanUsage] {
        if Demo.isOn { return Demo.plans(now: now) }
        return [claude(now: now)].compactMap { $0 } + accounts.compactMap { claude($0, now: now) }
            + antigravity(now: now) + [codex(now: now), windsurf(now: now)].compactMap { $0 }
    }

    /// Which app's status line wrote the newest Claude file, for Settings.
    static func claudeWriter() -> String? {
        if Demo.isOn { return "Paceline" }
        let dated = claudeFiles.compactMap { url -> (URL, Date)? in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (url, date)
        }
        return dated.max { $0.1 < $1.1 }.map { $0.0 == ownClaudeFile ? "Paceline" : $0.0 == pixpawClaudeFile ? "Pixpaw" : "AgentPet" }
    }

    /// This binary for a shell command: `~/…` when that's safe unquoted, else quoted.
    static var executable: String {
        ClaudeAccounts.shellPath(Bundle.main.executablePath ?? "/Applications/Paceline.app/Contents/MacOS/Paceline")
    }

    /// The command to put in Claude Code's `statusLine`.
    static var statusLineCommand: String { executable + " --statusline" }

    /// An extra account's `-p` run, saving its limits.
    static func claudeLimitsCommand(_ account: ClaudeAccount) -> String {
        "CLAUDE_CONFIG_DIR=\(ClaudeAccounts.shellPath(account.configDir)) claude -p \"…\" --output-format stream-json --verbose"
            + " | \(executable) --claude-limits \(account.id)"
    }

    /// The `statusLine` entry for ~/.claude/settings.json, to copy.
    static var statusLineJSON: String { statusLineJSON(command: statusLineCommand) }

    /// The command as a JSON string: quotes and backslashes escaped.
    static func statusLineJSON(command: String) -> String {
        let quoted = (try? JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return #""statusLine": {"type": "command", "command": \#(quoted)}"#
    }

    /// The newest of the saved files: `{"saved_at": …, "five_hour": {"used": 23, "resets_at": …}, "seven_day": {…}}`
    static func claude(now: Date = Date()) -> PlanUsage? {
        newest(claudeFiles, agent: "Claude", now: now)
    }

    /// The most recently saved of these files.
    static func newest(_ files: [URL], agent: String, now: Date = Date()) -> PlanUsage? {
        let plans = files.compactMap { url -> PlanUsage? in
            guard let data = try? Data(contentsOf: url),
                  let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return claude(saved, agent: agent, now: now)
        }
        return plans.max { $0.at < $1.at }
    }

    /// An extra account's file, same format, under its name.
    static func claude(_ account: ClaudeAccount, now: Date = Date()) -> PlanUsage? {
        if Demo.isOn { return Demo.plans(now: now).first { $0.agent == account.name } }   // never the real cache
        return newest(claudeFiles(account: account.id), agent: account.name, now: now)
    }

    /// Where `--statusline` saves: the main file with no CLAUDE_CONFIG_DIR or
    /// ~/.claude, a listed account's file for its folder, and nowhere for any
    /// other folder (an unknown account's numbers mustn't land on the main one).
    static func statusLineFile(configDir: String?, accounts: [ClaudeAccount]) -> URL? {
        guard let configDir, ClaudeAccounts.standardized(configDir) != ClaudeAccounts.standardized("~/.claude") else { return ownClaudeFile }
        return ClaudeAccounts.account(forConfigDir: configDir, in: accounts).map { claudeFile(account: $0.id) }
    }

    static func claude(_ saved: [String: Any], agent: String, now: Date = Date()) -> PlanUsage? {
        guard let at = (saved["saved_at"] as? NSNumber)?.doubleValue else { return nil }
        let windows: [PlanWindow] = [("five_hour", "5h"), ("seven_day", "Week")].compactMap { key, label in
            guard let entry = saved[key] as? [String: Any], let used = (entry["used"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return window(label, left: Int(percent: 100 - used), resets: resets, now: now)
        }
        var plan = usage(agent, group: nil, windows: windows, at: Date(timeIntervalSince1970: at), now: now)
        plan?.fetched = saved["fetched"] as? Bool ?? false
        return plan
    }

    /// `{"at": …, "table": "Gemini Models\tFive Hour Limit Remaining\t98%\t2026-11-02T06:28:15Z\n…"}`
    /// The newest of the saved tables.
    static func antigravity(now: Date = Date(), files: [URL] = antigravityFiles) -> [PlanUsage] {
        let saved = files.compactMap { url -> (at: Double, table: String, fetched: Bool)? in
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let at = (json["at"] as? NSNumber)?.doubleValue, let table = json["table"] as? String else { return nil }
            return (at, table, json["fetched"] as? Bool ?? false)
        }
        guard let (at, table, fetched) = saved.max(by: { $0.at < $1.at }) else { return [] }
        let iso = ISO8601DateFormatter()
        var groups: [(name: String, windows: [PlanWindow])] = []
        for row in table.split(separator: "\n") {
            let cells = row.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3, cells[2].hasSuffix("%"), let left = Int(cells[2].dropLast()) else { continue }
            let kind = cells[1].lowercased()
            guard let label = kind.contains("five hour") ? "5h" : kind.contains("weekly") ? "Week" : nil else { continue }
            let name = cells[0].replacingOccurrences(of: #"\s+models?$"#, with: "", options: [.regularExpression, .caseInsensitive])
            let w = window(label, left: left, resets: cells.count > 3 ? iso.date(from: cells[3]) : nil, now: now)
            if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].windows.append(w) } else { groups.append((name, [w])) }
        }
        return groups.compactMap { group in
            var plan = usage("Antigravity", group: group.name, windows: group.windows.sorted { $0.label == "5h" && $1.label != "5h" },
                             at: Date(timeIntervalSince1970: at), now: now)
            plan?.fetched = fetched
            return plan
        }
    }

    /// The newest rollouts of the last week, read from the end (limits come with
    /// every model call, so the tail of the newest file that has them is enough).
    static func codex(now: Date = Date()) -> PlanUsage? {
        let folders = CodexSource.dayFolders(in: CodexSource.home.appendingPathComponent("sessions"), days: Int(keptFor / 86400) + 1, now: now)
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        let files: [URL] = folders.flatMap { folder -> [URL] in
            let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return all.filter { $0.pathExtension == "jsonl" }
        }
        for file in files.sorted(by: { modified($0) > modified($1) }).prefix(5) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
            guard let tail = try? handle.readToEnd(), let limits = CodexLog.read(tail, since: .distantFuture).limits else { continue }
            return codex(limits, now: now)
        }
        return nil
    }

    /// Codex labels its windows primary/secondary; their length says which is which.
    static func codex(_ limits: CodexLog.Limits, now: Date = Date()) -> PlanUsage? {
        let windows = [(limits.primary, "5h"), (limits.secondary, "Week")].compactMap { w, fallback -> PlanWindow? in
            guard let w else { return nil }
            let label = w.minutes.map { $0 <= 24 * 60 ? "5h" : "Week" } ?? fallback
            return window(label, left: Int(percent: 100 - w.used), resets: w.resets, now: now)
        }
        var plan = usage("Codex", group: nil, windows: windows.sorted { $0.label == "5h" && $1.label != "5h" }, at: limits.at, now: now)
        plan?.planName = CodexLog.planName(limits.planType)
        return plan
    }

    /// A window that has reset since it was saved is full again.
    static func window(_ label: String, left: Int, resets: Date?, now: Date) -> PlanWindow {
        if let resets, resets <= now { return PlanWindow(label: label, left: 100, resets: nil, wasReset: true) }
        return PlanWindow(label: label, left: max(0, min(100, left)), resets: resets)
    }

    static func usage(_ agent: String, group: String?, windows: [PlanWindow], at: Date, now: Date) -> PlanUsage? {
        guard !windows.isEmpty, now.timeIntervalSince(at) < keptFor else { return nil }
        return PlanUsage(agent: agent, group: group, windows: windows, at: at)
    }

    // MARK: - Status line

    /// `Paceline --statusline`, set as Claude Code's `statusLine` command:
    /// reads the session JSON on stdin, saves only the plan percentages and
    /// reset times, and prints "Opus 5.5 · ctx 40% · 5h 32% · Week 91% left".
    /// With the pace on (Settings → Accounts → Claude, or `--pace` / `--show`), a window
    /// that's running out adds "· 5h runs out in 1h 12m". Empty or broken
    /// input prints "Claude" and saves nothing.
    static func statusLine(arguments: [String] = CommandLine.arguments) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        // Run under an extra account's folder, the numbers are that account's; an unlisted folder's aren't saved.
        if let file = statusLineFile(configDir: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], accounts: ClaudeAccounts.load()) {
            save(statusLineWindows(json), to: file)
        }
        let pace = arguments.contains("--pace") || arguments.contains("--show") || UserDefaults.standard.bool(forKey: statusLinePaceKey)
        print(statusLineText(json, pace: pace))
    }

    /// Off by default: the status line stays as it was.
    static let statusLinePaceKey = "statusLinePace"

    /// The session JSON's `rate_limits`, as saved: `["five_hour": ["used": 38, "resets_at": …], …]`.
    static func statusLineWindows(_ json: [String: Any]) -> [String: Any] {
        let limits = json["rate_limits"] as? [String: Any] ?? [:]
        var keep: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let w = limits[key] as? [String: Any], let used = w["used_percentage"] as? NSNumber else { continue }
            keep[key] = ["used": used, "resets_at": w["resets_at"] ?? NSNull()]
        }
        return keep
    }

    /// The status line's text for this session JSON.
    static func statusLineText(_ json: [String: Any], pace: Bool, now: Date = Date()) -> String {
        let keep = statusLineWindows(json)
        var bits = [((json["model"] as? [String: Any])?["display_name"] as? String) ?? "Claude"]
        if let context = ((json["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
            bits.append("ctx \(Int(percent: context))%")
        }
        let left = [("five_hour", "5h"), ("seven_day", "Week")].compactMap { key, label -> String? in
            ((keep[key] as? [String: Any])?["used"] as? NSNumber).map { "\(label) \(Int(percent: 100 - $0.doubleValue))%" }
        }
        if !left.isEmpty { bits.append(left.joined(separator: " · ") + " left") }
        if pace, let warning = paceWarning(keep, now: now) { bits.append(warning) }
        return bits.joined(separator: " · ")
    }

    /// "5h runs out in 1h 12m": the window that runs out soonest at the rate since
    /// it began (one reading, so no "lately"); nil when none is running out.
    static func paceWarning(_ windows: [String: Any], now: Date = Date()) -> String? {
        var saved = windows
        saved["saved_at"] = now.timeIntervalSince1970
        guard let plan = claude(saved, agent: "Claude", now: now) else { return nil }
        let soonest = plan.windows.compactMap { window -> (label: String, in: TimeInterval)? in
            guard case .runsOut(let seconds) = plan.pace(window, now: now) else { return nil }
            return (window.label, seconds)
        }.min { $0.in < $1.in }
        return soonest.map { "\($0.label) runs out in \(PlanWindow.duration($0.in))" }
    }

    /// Writes `{"saved_at": …, "five_hour": {"used": …, "resets_at": …}, …}`; nothing when empty.
    /// `fetched`: Paceline asked for these (Fetch fresh numbers) rather than the AI being used.
    static func save(_ windows: [String: Any], to url: URL, fetched: Bool = false) {
        guard !windows.isEmpty else { return }
        let old = (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var saved = merged(windows, into: old)
        if fetched { saved["fetched"] = true }
        if let data = try? JSONSerialization.data(withJSONObject: saved) { try? data.write(to: url, options: .atomic) }
    }

    /// New windows over the saved ones: an update with only the five hours keeps the week.
    static func merged(_ windows: [String: Any], into old: [String: Any]?, now: Date = Date()) -> [String: Any] {
        var keep = (old ?? [:]).filter { ["five_hour", "seven_day"].contains($0.key) }
        keep.merge(windows) { $1 }
        keep["saved_at"] = now.timeIntervalSince1970
        return keep
    }

    // MARK: - claude -p

    /// `claude -p --output-format stream-json --verbose … | Paceline --claude-limits <account>`:
    /// saves every `rate_limit_event` to `claude-usage-<account>.json` and prints
    /// only the `{"type":"result"…}` line (or the last line if there's none),
    /// so the caller reads it as with `--output-format json`.
    static func claudeLimits(account: String) {
        let name = String(account.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        var result: String?, last: String?
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            last = line
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "rate_limit_event": if !name.isEmpty { save(rateLimitWindows(json), to: claudeFile(account: name)) }
            case "result": result = line
            default: break
            }
        }
        if let line = result ?? last { print(line) }
    }

    /// `rate_limit_info.unifiedWindows` (utilization 0–1, resetsAt in seconds) as saved windows;
    /// without them, the one window `rateLimitType` names, from the top-level numbers.
    static func rateLimitWindows(_ event: [String: Any]) -> [String: Any] {
        let info = event["rate_limit_info"] as? [String: Any] ?? [:]
        var windows = info["unifiedWindows"] as? [String: Any] ?? [:]
        if windows.isEmpty, let type = info["rateLimitType"] as? String {
            windows[type] = info
        }
        var keep: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let w = windows[key] as? [String: Any], let utilization = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            keep[key] = ["used": (utilization * 1000).rounded() / 10, "resets_at": w["resetsAt"] ?? NSNull()]
        }
        return keep
    }
}
