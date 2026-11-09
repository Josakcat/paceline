import Foundation
import SQLite3

// Usage from tools other than Claude Code (which TokenMonitor reads).
// See docs/token-sources.md. `SourcesMonitor` feeds the HUD's Tokens tab and `--sources`.

/// How far a number can be trusted. The HUD should never add these together silently.
enum UsageAccuracy: String, Sendable {
    case exact      // token counts the provider reported, read from disk
    case estimated  // derived from text length
    case activity   // derived from active minutes; a rough range, not a count
}

struct TokenCounts: Sendable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var messages = 0
    var total: Int { input + output + cacheWrite + cacheRead }

    static func += (a: inout TokenCounts, b: TokenCounts) {
        a.input += b.input; a.output += b.output; a.cacheWrite += b.cacheWrite; a.cacheRead += b.cacheRead
        a.messages += b.messages
    }
}

struct SourceUsage: Sendable {
    let source: String
    let accuracy: UsageAccuracy
    var byModel: [String: TokenCounts] = [:]
    var lastActivity: Date?
    var note: String?
    /// $ the tool itself recorded per model (OpenCode does), used before `Pricing`.
    var costs: [String: Double] = [:]
    /// The day these are for (its start), set by the monitor; nil for demo numbers.
    var day: Date?

    var total: TokenCounts { byModel.values.reduce(into: TokenCounts()) { $0 += $1 } }

    /// The tool's own recorded cost, else the API-equivalent cost of the models
    /// `Pricing` knows; the rest count as $0.
    var usd: Double {
        byModel.reduce(0) { sum, entry in
            if let recorded = costs[entry.key], recorded > 0 { return sum + recorded }
            guard let p = Pricing.price(for: entry.key) else { return sum }
            let c = entry.value
            return sum + (Double(c.input) * p.input + Double(c.output) * p.output
                          + Double(c.cacheWrite) * p.input * 1.25 + Double(c.cacheRead) * p.cacheRead) / 1_000_000
        }
    }

    var unpricedModels: [String] { byModel.keys.filter { (costs[$0] ?? 0) <= 0 && Pricing.price(for: $0) == nil }.sorted() }
}

protocol UsageSource: Sendable {
    var name: String { get }
    /// Folders to watch with FSEvents.
    var watchPaths: [URL] { get }
    var isInstalled: Bool { get }
    /// How many folders down a change can be (a file in tasks/<id>/ is 2).
    var changeDepth: Int { get }
    func usage(since dayStart: Date) -> SourceUsage
}

extension UsageSource {
    var changeDepth: Int { 1 }
}

// MARK: - Antigravity

/// Antigravity keeps one SQLite file per conversation in
/// ~/.gemini/antigravity/conversations/<id>.db. Each model call adds a row to
/// `gen_metadata` whose protobuf carries the provider's usage numbers, and the
/// step it ran for (`last_step_index`) has a creation timestamp in `steps.metadata`.
///
/// The layout was worked out by reading the files (2026-11-02), not from any
/// documentation, so an update can change it. Unknown rows are skipped, never guessed.
struct AntigravitySource: UsageSource {
    let name = "Antigravity"
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/conversations")

    var watchPaths: [URL] { [root] }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// The later of the database's and its -wal's modification dates.
    static func modified(_ db: URL) -> Date {
        [db, URL(fileURLWithPath: db.path + "-wal")].compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? .distantPast
    }

    func usage(since dayStart: Date) -> SourceUsage {
        var result = SourceUsage(source: name, accuracy: .exact)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var skipped = 0, unreadable = 0
        for file in files where file.pathExtension == "db" {
            // Writes may still be in <id>.db-wal, which the .db's date doesn't show until a checkpoint.
            guard Self.modified(file) >= dayStart else { continue }
            guard let db = SQLiteFile(file) else {
                unreadable += 1
                continue
            }

            var stepTimes: [Int: Date] = [:]
            db.forEachRow("SELECT idx, metadata FROM steps") { row in
                // metadata.1 = created_at (google.protobuf.Timestamp), .1 = seconds
                if let seconds = Proto.varint(row.blob(1), path: [1, 1]) {
                    stepTimes[row.int(0)] = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            }
            db.forEachRow("SELECT data FROM gen_metadata") { row in
                autoreleasepool { () -> Void in
                let data = row.blob(0)
                guard let call = Proto.bytes(data, path: [1]),
                      let usage = Proto.bytes(call, path: [4]),
                      let step = Proto.mapValue(call, field: 20, key: "last_step_index").flatMap(Int.init),
                      let time = stepTimes[step] else {
                    skipped += 1
                    return
                }
                guard time >= dayStart else { return }
                let model = Proto.bytes(call, path: [19]).map { String(decoding: $0, as: UTF8.self) } ?? "unknown"
                var counts = TokenCounts()
                counts.input = Proto.varint(usage, path: [2]).map(Int.init(count:)) ?? 0
                counts.output = Proto.varint(usage, path: [3]).map(Int.init(count:)) ?? 0
                counts.cacheWrite = Proto.varint(usage, path: [4]).map(Int.init(count:)) ?? 0  // not seen yet; assumed
                counts.cacheRead = Proto.varint(usage, path: [5]).map(Int.init(count:)) ?? 0
                counts.messages = 1
                result.byModel[model, default: TokenCounts()] += counts
                result.lastActivity = max(result.lastActivity ?? time, time)
                }
            }
        }
        result.note = [skipped > 0 ? "\(skipped) model calls had an unknown layout and were skipped" : nil,
                       unreadable > 0 ? "\(unreadable) conversations couldn’t be opened" : nil].compactMap { $0 }.joined(separator: "; ").nonEmpty
        return result
    }
}

// MARK: - Codex

/// OpenAI Codex keeps its state in $CODEX_HOME (default ~/.codex):
/// - `sessions/YYYY/MM/DD/rollout-*.jsonl`: one file per session. Each model
///   call adds an `event_msg` of type `token_count` with the session's running
///   total and, from the CLI, the plan's `rate_limits`. Read by `CodexLog`.
/// - `state_5.sqlite`, table `threads`: one row per thread with `tokens_used`
///   (a running total, no in/out split) and `rollout_path`. Used for threads
///   whose rollout isn't on disk; only threads created today can be counted.
///
/// `auth.json` is never opened. Worked out from the files (2026-11-07).
struct CodexSource: UsageSource {
    let name = "Codex"
    static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    let root = CodexSource.home
    var sessions: URL { root.appendingPathComponent("sessions") }

    /// The folder itself (state_5.sqlite-wal changes with every turn), plus
    /// today's and yesterday's session folders, which a JSONL-only CLI appends to.
    var watchPaths: [URL] {
        [root] + Self.dayFolders(in: sessions, days: 2).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// sessions/YYYY/MM/DD (local time, Gregorian even when the Mac uses the
    /// Buddhist calendar) for today and the days before it.
    static func dayFolders(in sessions: URL, days: Int, now: Date = Date()) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return (0..<days).compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            return sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
        }
    }

    func usage(since dayStart: Date) -> SourceUsage {
        var result = SourceUsage(source: name, accuracy: .exact)
        var rollouts: Set<String> = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        if let walk = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys) {
            for case let file as URL in walk where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                if modified >= dayStart { rollouts.insert(file.standardizedFileURL.path) }
            }
        }

        // Threads touched today; a thread whose rollout is missing counts by its total.
        var totalsOnly: [(model: String, tokens: Int, created: Date, updated: Date)] = []
        if let db = SQLiteFile(root.appendingPathComponent("state_5.sqlite")) {
            db.forEachRow("SELECT rollout_path, created_at, updated_at, tokens_used, COALESCE(model, '') FROM threads WHERE updated_at >= \(Int(dayStart.timeIntervalSince1970))") { row in
                let path = URL(fileURLWithPath: row.text(0)).standardizedFileURL.path
                if !row.text(0).isEmpty, FileManager.default.fileExists(atPath: path) {
                    rollouts.insert(path)
                } else {
                    totalsOnly.append((row.text(4).nonEmpty ?? "unknown", row.int(3),
                                       Date(timeIntervalSince1970: TimeInterval(row.int(1))), Date(timeIntervalSince1970: TimeInterval(row.int(2)))))
                }
            }
        }

        for path in rollouts {
            autoreleasepool {
                guard let data = FileManager.default.contents(atPath: path) else { return }
                let log = CodexLog.read(data, since: dayStart)
                for (model, counts) in log.byModel { result.byModel[model, default: TokenCounts()] += counts }
                if let t = log.lastActivity { result.lastActivity = max(result.lastActivity ?? t, t) }
            }
        }

        var counted = 0, skipped = 0
        for thread in totalsOnly where thread.tokens > 0 {
            guard thread.created >= dayStart else { skipped += 1; continue }
            // No in/out split in the table: the whole total goes under input.
            result.byModel[thread.model, default: TokenCounts()] += TokenCounts(input: thread.tokens, messages: 1)
            result.lastActivity = max(result.lastActivity ?? thread.updated, thread.updated)
            counted += 1
        }
        result.note = [counted > 0 ? "\(counted) threads counted from their totals only (no in/out split)" : nil,
                       skipped > 0 ? "\(skipped) threads started before today have no rollout and were skipped" : nil]
            .compactMap { $0 }.joined(separator: "; ").nonEmpty
        return result
    }
}

/// Reads a Codex rollout (JSONL). Only two kinds of line matter:
/// `{"type":"turn_context","payload":{"model":"gpt-5-codex",…}}` and
/// `{"timestamp":"…Z","type":"event_msg","payload":{"type":"token_count",
///   "info":{"total_token_usage":{"input_tokens":…,"cached_input_tokens":…,"output_tokens":…},
///           "last_token_usage":{…}},
///   "rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":…},"secondary":{…}}}}`
enum CodexLog {
    struct Window: Equatable, Sendable {
        let minutes: Int?
        let used: Double
        let resets: Date?
    }

    struct Limits: Sendable {
        let primary: Window?
        let secondary: Window?
        let at: Date
        /// `rate_limits.plan_type` ("team", "plus"…), as written.
        var planType: String?
    }

    struct Result: Sendable {
        var byModel: [String: TokenCounts] = [:]
        var lastActivity: Date?
        var limits: Limits?
    }

    static func read(_ data: Data, since dayStart: Date) -> Result {
        var result = Result()
        var model = "unknown"
        var previous: TokenCounts?  // the session's running total so far
        let tokenCount = Data("token_count".utf8), turnContext = Data("turn_context".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Most lines are messages and tool output; skip them before parsing.
            guard line.range(of: tokenCount) != nil || line.range(of: turnContext) != nil,
                  let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            if json["type"] as? String == "turn_context" {
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
                continue
            }
            guard json["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                  let time = (json["timestamp"] as? String).flatMap(date) else { continue }

            if let limits = payload["rate_limits"] as? [String: Any] {
                let primary = window(limits["primary"], at: time), secondary = window(limits["secondary"], at: time)
                if primary != nil || secondary != nil, time >= result.limits?.at ?? .distantPast {
                    result.limits = Limits(primary: primary, secondary: secondary, at: time,
                                           planType: (limits["plan_type"] as? String)?.nonEmpty)
                }
            }
            guard let info = payload["info"] as? [String: Any], let total = counts(info["total_token_usage"]) else { continue }
            // The total repeats when only the limits changed; count what it grew by.
            var delta = total
            if let previous {
                delta = total.total >= previous.total
                    ? TokenCounts(input: total.input - previous.input, output: total.output - previous.output,
                                  cacheRead: total.cacheRead - previous.cacheRead)
                    : counts(info["last_token_usage"]) ?? TokenCounts()
            }
            previous = total
            guard delta.total > 0, time >= dayStart else { continue }
            delta.messages = 1
            result.byModel[model, default: TokenCounts()] += delta
            result.lastActivity = max(result.lastActivity ?? time, time)
        }
        return result
    }

    /// "team" → "Team"; unknown values get a capital; nothing → nil.
    static func planName(_ type: String?) -> String? {
        guard let t = type?.trimmingCharacters(in: .whitespaces).nonEmpty else { return nil }
        switch t.lowercased() {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return t.prefix(1).uppercased() + t.dropFirst()
        }
    }

    /// OpenAI's input_tokens include the cached ones.
    private static func counts(_ value: Any?) -> TokenCounts? {
        guard let usage = value as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        return TokenCounts(input: max(0, int("input_tokens") - cached), output: int("output_tokens"), cacheRead: cached)
    }

    /// `resets_at` is epoch seconds (or ISO 8601); older CLIs wrote `resets_in_seconds` from the event's time.
    private static func window(_ value: Any?, at time: Date) -> Window? {
        guard let w = value as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        var resets: Date?
        if let at = w["resets_at"] as? NSNumber { resets = Date(timeIntervalSince1970: at.doubleValue) }
        else if let at = w["resets_at"] as? String { resets = date(at) }
        else if let seconds = w["resets_in_seconds"] as? NSNumber { resets = time.addingTimeInterval(seconds.doubleValue) }
        return Window(minutes: (w["window_minutes"] as? NSNumber)?.intValue, used: used, resets: resets)
    }

    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }
}

// MARK: - Activity fallback

// MARK: - Monitor

/// Rescans every installed source when its folder changes (FSEvents, at most
/// every 5 s) and once a minute for the midnight rollover.
final class SourcesMonitor: @unchecked Sendable {
    private let sources: [any UsageSource]
    private let queue = DispatchQueue(label: "paceline.sources", qos: .utility)
    private let onUpdate: @Sendable ([SourceUsage]) -> Void
    // Only touched on `queue`.
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var lastScan = Date.distantPast
    private var pending = false
    private var lastSignature: [Date] = []
    private var lastDay = Date.distantPast

    init(sources: [any UsageSource] = UsageSources.all, onUpdate: @escaping @Sendable ([SourceUsage]) -> Void) {
        self.sources = sources.filter(\.isInstalled)
        self.onUpdate = onUpdate
    }

    func start() {
        guard !sources.isEmpty else { return }
        queue.async { self.scan() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SourcesMonitor>.fromOpaque(info).takeUnretainedValue().scanSoon()
        }
        let paths = sources.flatMap(\.watchPaths).map(\.path)
        if let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, 0) {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    func stop() {
        queue.sync {
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                stream = nil
            }
            timer?.cancel()
        }
    }

    /// Antigravity writes its database many times per answer; coalesce those.
    private func scanSoon() {
        guard !pending else { return }
        pending = true
        let wait = max(0, 5 - Date().timeIntervalSince(lastScan))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.pending = false
            self?.scan()
        }
    }

    private func scan() {
        lastScan = Date()
        let dayStart = Calendar.current.startOfDay(for: Date())
        // Skip the work (opening every database) when nothing in the watched
        // folders changed since the last pass and it's still the same day.
        let signature = sources.flatMap { source in source.watchPaths.map { Self.newestChange(in: $0, depth: source.changeDepth) } }
        guard signature != lastSignature || dayStart != lastDay else { return }
        lastSignature = signature
        lastDay = dayStart
        onUpdate(sources.map { source in
            var usage = source.usage(since: dayStart)
            usage.day = dayStart
            return usage
        })
    }

    /// The newest modification `depth` levels down (a file rewritten in place
    /// doesn't touch its folder's date).
    private static func newestChange(in folder: URL, depth: Int) -> Date {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        return items.map { url -> Date in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let own = values?.contentModificationDate ?? .distantPast
            return depth > 1 && values?.isDirectory == true ? max(own, newestChange(in: url, depth: depth - 1)) : own
        }.max() ?? .distantPast
    }
}

// MARK: - CLI

enum UsageSources {
    static let all: [any UsageSource] = Providers.sources

    /// `Paceline --sources`
    static func printToday() {
        let dayStart = Calendar.current.startOfDay(for: Date())
        for source in all {
            guard source.isInstalled else {
                print("\(source.name): not installed")
                continue
            }
            let usage = source.usage(since: dayStart)
            let total = usage.total
            print("\(source.name) (\(usage.accuracy.rawValue)): \(Format.tokens(total.total)) tokens in \(total.messages) requests today")
            for (model, c) in usage.byModel.sorted(by: { $0.value.total > $1.value.total }) {
                print("  \(model): in \(Format.tokens(c.input)) · out \(Format.tokens(c.output)) · cache read \(Format.tokens(c.cacheRead))"
                      + (c.cacheWrite > 0 ? " · cache write \(Format.tokens(c.cacheWrite))" : "")
                      + (Pricing.price(for: model) == nil ? " · price unknown" : ""))
            }
            if let note = usage.note { print("  note: \(note)") }
        }
    }
}

// MARK: - Helpers

/// Read-only access to another app's SQLite file. A read-only connection to a
/// WAL database fails when the app isn't running (no -shm file to share), so
/// then a private copy of the database and its -wal is read instead (or, with
/// `copy: false`, the file is read as is, without its -wal).
final class SQLiteFile {
    private var db: OpaquePointer?
    private var copyDir: URL?

    init?(_ url: URL, copy: Bool = true) {
        if open("\(url.absoluteString)?mode=ro") { return }
        if !copy {
            guard open("\(url.absoluteString)?mode=ro&immutable=1") else { return nil }
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-sqlite-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for suffix in ["", "-wal"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(url.lastPathComponent + suffix))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        copyDir = dir
        // Read-write, because SQLite has to rebuild the -shm index for a WAL file. It's our own copy.
        guard open(dir.appendingPathComponent(url.lastPathComponent).absoluteString, flags: SQLITE_OPEN_READWRITE) else { return nil }
    }

    private func open(_ uri: String, flags: Int32 = SQLITE_OPEN_READONLY) -> Bool {
        sqlite3_close(db)
        db = nil
        guard sqlite3_open_v2(uri, &db, flags | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(db, 200)
        // Opening is lazy; the first query is what fails on a locked or unreadable file.
        return sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func blob(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    /// Every query run, while a selftest is watching (it checks no secret row is asked for).
    nonisolated(unsafe) static var queryLog: [String]?

    func forEachRow(_ sql: String, _ body: (Row) -> Void) {
        Self.queryLog?.append(sql)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { body(Row(statement: statement)) }
    }

    deinit {
        sqlite3_close(db)
        if let copyDir { try? FileManager.default.removeItem(at: copyDir) }
    }
}

/// Just enough protobuf to follow field numbers: varints and length-delimited
/// fields. Scans in place (sub-messages are slices of the same buffer) and
/// returns nil instead of trapping on anything unexpected.
enum Proto {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    /// Calls `body` for each top-level field until it returns false.
    /// Returns false if the data isn't a well-formed message.
    @discardableResult
    static func forEachField(_ data: Data, _ body: (Int, Value) -> Bool) -> Bool {
        var i = data.startIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex, shift < 64 {
                let b = data[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while i < data.endIndex {
            guard let key = varint(), key >> 3 > 0 else { return false }
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                guard let v = varint() else { return false }
                value = .varint(v)
            case 1, 5:
                i += key & 7 == 1 ? 8 : 4
                guard i <= data.endIndex else { return false }
                continue
            case 2:
                guard let n = varint(), n <= UInt64(data.endIndex - i) else { return false }
                value = .bytes(data[i..<i + Int(n)])
                i += Int(n)
            default:
                return false
            }
            if !body(field, value) { return true }
        }
        return true
    }

    private static func value(_ data: Data, path: ArraySlice<Int>) -> Value? {
        guard let first = path.first else { return nil }
        var found: Value?
        forEachField(data) { field, value in
            if field == first { found = value }
            return found == nil
        }
        guard let found, path.count > 1 else { return found }
        guard case .bytes(let inner) = found else { return nil }
        return value(inner, path: path.dropFirst())
    }

    static func varint(_ data: Data, path: [Int]) -> UInt64? {
        if case .varint(let v)? = value(data, path: path[...]) { return v }
        return nil
    }

    static func bytes(_ data: Data, path: [Int]) -> Data? {
        if case .bytes(let d)? = value(data, path: path[...]) { return d }
        return nil
    }

    /// A `map<string, string>` field: repeated entries with key = 1, value = 2.
    static func mapValue(_ data: Data, field: Int, key: String) -> String? {
        var result: String?
        forEachField(data) { f, value in
            if f == field, case .bytes(let pair) = value,
               let k = bytes(pair, path: [1]), String(decoding: k, as: UTF8.self) == key,
               let v = bytes(pair, path: [2]) {
                result = String(decoding: v, as: UTF8.self)
            }
            return result == nil
        }
        return result
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Int {
    /// A count read from another app's file: NaN, negative or absurd values
    /// (a corrupt file) become 0 or a trillion, never a crash (`Int(1e20)` traps).
    init(count value: Double) {
        self = value.isFinite ? Int(Swift.min(Swift.max(value, 0), 1e12)) : 0
    }

    init(count value: UInt64) { self = Int(Swift.min(value, 1_000_000_000_000)) }

    /// A percentage, rounded, in 0…100 whatever the file said.
    init(percent value: Double) {
        self = value.isFinite ? Int(Swift.min(Swift.max(value, 0), 100).rounded()) : 0
    }
}
