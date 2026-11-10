import Foundation

struct UsageBucket: Sendable {
    var tokens = 0
    var usd = 0.0
}

struct UsageSnapshot: Sendable {
    var totalTokens = 0
    var totalUSD = 0.0
    var messages = 0
    var byModel: [String: UsageBucket] = [:]
    var byProject: [String: UsageBucket] = [:]
    var unpricedModels: Set<String> = []
    /// The day these are for (its start); nil for made-up demo numbers.
    var day: Date?

    /// Several accounts' days as one: totals summed, models and projects merged.
    static func combined(_ snapshots: [UsageSnapshot]) -> UsageSnapshot {
        var out = UsageSnapshot(day: snapshots.first?.day)
        for s in snapshots {
            out.totalTokens += s.totalTokens
            out.totalUSD += s.totalUSD
            out.messages += s.messages
            out.unpricedModels.formUnion(s.unpricedModels)
            for (k, b) in s.byModel { out.byModel[k, default: UsageBucket()].tokens += b.tokens; out.byModel[k, default: UsageBucket()].usd += b.usd }
            for (k, b) in s.byProject { out.byProject[k, default: UsageBucket()].tokens += b.tokens; out.byProject[k, default: UsageBucket()].usd += b.usd }
        }
        return out
    }
}

/// API list prices in $ per million tokens. Cache writes are derived from the
/// input price (5-minute TTL 1.25×, 1-hour TTL 2×); cache reads are per model.
enum Pricing {
    struct Price { let input: Double; let output: Double; let cacheRead: Double }

    static func price(for model: String, on date: Date = Date()) -> Price? {
        let m = model.lowercased()
        func has(_ s: String) -> Bool { m.contains(s) }
        if m.hasPrefix("gemini") { return gemini(m, on: date) }
        if m.hasPrefix("gpt-") { return openAI(m) }
        if has("fable-5-2") || has("mythos-5-2") { return Price(input: 8, output: 40, cacheRead: 0.20) }
        if has("fable-5-1") || has("mythos-5-1") { return Price(input: 10, output: 50, cacheRead: 0.25) }
        if has("fable-5") || has("mythos-5") { return Price(input: 10, output: 50, cacheRead: 1) }
        if has("opus-5-5") { return Price(input: 4, output: 20, cacheRead: 0.20) }
        if has("opus-5") || has("opus-4-8") || has("opus-4-7") || has("opus-4-6") || has("opus-4-5") {
            return Price(input: 5, output: 25, cacheRead: 0.5)
        }
        if has("opus") { return Price(input: 15, output: 75, cacheRead: 1.5) }
        if has("sonnet-5") { return Price(input: 2, output: 10, cacheRead: 0.20) }
        if has("sonnet") { return Price(input: 3, output: 15, cacheRead: 0.3) }
        if has("haiku-5-5") { return Price(input: 0.10, output: 0.50, cacheRead: 0.01) }
        if has("haiku-4-5") { return Price(input: 1, output: 5, cacheRead: 0.1) }
        if has("haiku") { return Price(input: 0.8, output: 4, cacheRead: 0.08) }
        return nil
    }

    /// Gemini API, paid tier, standard, prompts ≤200k tokens; cache read is
    /// "context caching". https://aistudio.google.com/docs/pricing (checked
    /// 2026-11-08). Some rise on a set day, so the date matters. Image, audio
    /// and TTS models aren't here (no tokens of theirs show up).
    private static func gemini(_ m: String, on date: Date) -> Price? {
        func until(_ year: Int, _ month: Int, _ day: Int) -> Bool {
            var parts = DateComponents(); parts.year = year; parts.month = month; parts.day = day
            parts.timeZone = TimeZone(identifier: "UTC")
            return Calendar(identifier: .gregorian).date(from: parts).map { date < $0 } ?? true
        }
        if m.contains("tts") || m.contains("image") || m.contains("embedding") { return nil }
        if m.hasPrefix("gemini-4-argon") {
            return until(2026, 12, 1) ? Price(input: 2, output: 10, cacheRead: 0.10) : Price(input: 4, output: 20, cacheRead: 0.20)
        }
        if m.hasPrefix("gemini-3.8-flash-lite") { return nil }   // not on the page (only its TTS)
        if m.hasPrefix("gemini-3.8-flash") || m.hasPrefix("gemini-3.6-flash") {
            return until(2027, 1, 1) ? Price(input: 0.75, output: 3.75, cacheRead: 0.075) : Price(input: 1.5, output: 7.5, cacheRead: 0.15)
        }
        if m.hasPrefix("gemini-3.5-flash-lite") { return Price(input: 0.30, output: 2.50, cacheRead: 0.03) }
        if m.hasPrefix("gemini-3.1-flash-lite") { return Price(input: 0.25, output: 1.50, cacheRead: 0.025) }
        if m.hasPrefix("gemini-3.1-pro") { return Price(input: 2, output: 12, cacheRead: 0.20) }
        if m.hasPrefix("gemini-3-flash") { return Price(input: 0.50, output: 3, cacheRead: 0.05) }
        if m.hasPrefix("gemini-2.5-flash-lite") { return Price(input: 0.10, output: 0.40, cacheRead: 0.01) }
        if m.hasPrefix("gemini-2.5-pro") { return Price(input: 1.25, output: 10, cacheRead: 0.125) }
        return nil
    }

    /// OpenAI API, standard tier, short context (≤272k input); cache read is
    /// "cached input". https://developers.openai.com/api/docs/pricing (checked
    /// 2026-11-08). Only ids the page lists, exactly (or with a date after):
    /// gpt-5-codex and others not on it stay unknown.
    private static func openAI(_ m: String) -> Price? {
        let prices: [(String, Price)] = [
            // https://developers.openai.com/api/docs/models/gpt-6.1-sol (checked 2026-11-09)
            ("gpt-6.1-sol", Price(input: 2, output: 10, cacheRead: 0.10)),
            ("gpt-5.5", Price(input: 5, output: 30, cacheRead: 0.50)),
            ("gpt-5.4", Price(input: 2.5, output: 15, cacheRead: 0.25)),
            ("gpt-5.3-codex", Price(input: 1.75, output: 14, cacheRead: 0.175)),
            ("gpt-5.2", Price(input: 1.75, output: 14, cacheRead: 0.175)),
            ("gpt-5.1", Price(input: 1.25, output: 10, cacheRead: 0.125)),
            ("gpt-5", Price(input: 1.25, output: 10, cacheRead: 0.125)),
        ]
        return prices.first { m == $0.0 || m.hasPrefix($0.0 + "-20") }?.1
    }

    /// "claude-opus-5-5" → "Opus 5.5"; the older order too, "claude-3-5-sonnet-20241022" → "Sonnet 3.5".
    static func displayName(_ model: String) -> String {
        var parts = model.replacingOccurrences(of: "[1m]", with: "").split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        if let named = parts.firstIndex(where: { Int($0) == nil }), named > 0 { parts.insert(parts.remove(at: named), at: 0) }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}

/// Reads today's assistant usage from Claude Code transcripts
/// (~/.claude/projects/**/*.jsonl), tailing files incrementally on FSEvents.
/// One per Claude account: each listed extra account's <configDir>/projects too.
final class TokenMonitor: @unchecked Sendable {
    /// The main account's id here, as in Fetch fresh numbers' files.
    static let mainID = "claude"
    static let mainRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    /// The folders to read, one per account: the main account's, then each
    /// listed one's <configDir>/projects. A folder that is (symlinks followed)
    /// one already read is left out, so it counts once, for the first.
    /// Folders not in the list are never read.
    static func roots(main: URL = mainRoot, accounts: [ClaudeAccount]) -> [(id: String, root: URL)] {
        var out = [(id: mainID, root: main)]
        var seen: Set = [main.resolvingSymlinksInPath().path]
        for account in accounts {
            let root = account.configURL.appendingPathComponent("projects")
            if seen.insert(root.resolvingSymlinksInPath().path).inserted { out.append((account.id, root)) }
        }
        return out
    }

    private struct Entry {
        let model: String
        let project: String
        let input: Int, output: Int, write5m: Int, write1h: Int, read: Int
    }

    private let root: URL
    /// One queue for every account's monitor: passes take turns, so reading
    /// two accounts' big transcripts never needs twice the memory at once.
    private static let sharedQueue = DispatchQueue(label: "paceline.tokens", qos: .utility)
    private let queue = TokenMonitor.sharedQueue
    private let onUpdate: @Sendable (UsageSnapshot, Date?) -> Void
    // Everything below is only touched on `queue`.
    private var offsets: [String: UInt64] = [:]
    private var entries: [String: Entry] = [:]
    private var dayStart = Date.distantPast
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let chunkSize = 4 << 20

    init(root: URL = TokenMonitor.mainRoot,
         onUpdate: @escaping @Sendable (UsageSnapshot, Date?) -> Void) {
        self.root = root
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { self.scan() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TokenMonitor>.fromOpaque(info).takeUnretainedValue().scanSoon()
        }
        if FileManager.default.fileExists(atPath: root.path),
           let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                       FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
        // Safety net for missed events and the midnight rollover.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
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

    /// One synchronous pass, for `--usage`.
    func scanNow() -> UsageSnapshot {
        queue.sync {
            scanFiles()
            return snapshot()
        }
    }

    private func scan() {
        lastScan = Date()
        let latest = scanFiles()
        onUpdate(snapshot(), latest)
    }

    // On `queue` only.
    private var lastScan = Date.distantPast
    private var pending = false

    /// Claude Code appends to its transcript many times a second while it
    /// answers; each pass walks every folder in ~/.claude/projects, so passes
    /// are at most 3 s apart.
    private func scanSoon() {
        guard !pending else { return }
        pending = true
        let wait = max(0, 3 - Date().timeIntervalSince(lastScan))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.pending = false
            self?.scan()
        }
    }

    @discardableResult
    private func scanFiles() -> Date? {
        let today = Calendar.current.startOfDay(for: Date())
        if today != dayStart {
            dayStart = today
            entries = [:]
            offsets = [:]
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nil
        }
        var latestWrite: Date?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified >= dayStart,
                  let size = values.fileSize.map(UInt64.init) else { continue }
            var offset = offsets[url.path] ?? 0
            if size < offset { offset = 0 }  // file was rewritten
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            // Today's transcripts can be hundreds of MB; drain Foundation objects per chunk.
            var reading = true
            while reading, offset < size {
                autoreleasepool {
                    try? handle.seek(toOffset: offset)
                    guard let data = try? handle.read(upToCount: Self.chunkSize), !data.isEmpty else { reading = false; return }
                    guard let newline = data.lastIndex(of: 0x0A) else {
                        // An unfinished last line: wait for the rest. A single line over 4 MB is skipped.
                        if data.count == Self.chunkSize { offset += UInt64(data.count) } else { reading = false }
                        return
                    }
                    parse(data[data.startIndex...newline])
                    offset += UInt64(newline - data.startIndex + 1)
                }
            }
            offsets[url.path] = offset
            latestWrite = max(latestWrite ?? .distantPast, modified)
        }
        return latestWrite
    }

    private func parse(_ chunk: Data) {
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let end = chunk[start...].firstIndex(of: 0x0A) ?? chunk.endIndex
            let line = chunk[start..<end]
            start = end < chunk.endIndex ? end + 1 : end
            guard line.range(of: Self.usageMarker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = object["timestamp"] as? String,
                  let time = iso.date(from: stamp) ?? isoPlain.date(from: stamp), time >= dayStart else { continue }
            let model = message["model"] as? String ?? "unknown"
            if model == "<synthetic>" { continue }
            // Claude Code writes one line per content block with the same usage; keep one per request.
            let key = "\(message["id"] as? String ?? UUID().uuidString)|\(object["requestId"] as? String ?? "")"
            let creation = usage["cache_creation"] as? [String: Any]
            let written = usage["cache_creation_input_tokens"] as? Int ?? 0
            let write1h = creation?["ephemeral_1h_input_tokens"] as? Int ?? 0
            let write5m = creation == nil ? written : creation?["ephemeral_5m_input_tokens"] as? Int ?? 0
            let project = (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
            entries[key] = Entry(model: model, project: project,
                                 input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                                 write5m: write5m, write1h: write1h, read: usage["cache_read_input_tokens"] as? Int ?? 0)
        }
    }

    private func snapshot() -> UsageSnapshot {
        var s = UsageSnapshot(day: dayStart)
        for e in entries.values {
            let tokens = e.input + e.output + e.write5m + e.write1h + e.read
            var usd = 0.0
            if let p = Pricing.price(for: e.model) {
                usd = (Double(e.input) * p.input + Double(e.output) * p.output
                       + Double(e.write5m) * p.input * 1.25 + Double(e.write1h) * p.input * 2
                       + Double(e.read) * p.cacheRead) / 1_000_000
            } else {
                s.unpricedModels.insert(e.model)
            }
            s.totalTokens += tokens
            s.totalUSD += usd
            s.byModel[Pricing.displayName(e.model), default: UsageBucket()].tokens += tokens
            s.byModel[Pricing.displayName(e.model), default: UsageBucket()].usd += usd
            s.byProject[e.project, default: UsageBucket()].tokens += tokens
            s.byProject[e.project, default: UsageBucket()].usd += usd
        }
        s.messages = entries.count
        return s
    }

    static func printToday() {
        // Demo accounts' folders are made up; only the main account's is read then.
        let accounts = Demo.isOn ? [] : ClaudeAccounts.load()
        let all = roots(accounts: accounts).map { ($0.id, TokenMonitor(root: $0.root, onUpdate: { _, _ in }).scanNow()) }
        let s = UsageSnapshot.combined(all.map(\.1))
        print(String(format: "today: $%.2f API-equivalent · %@ tokens · %d requests", s.totalUSD, Format.tokens(s.totalTokens), s.messages))
        if all.count > 1 {
            for (id, a) in all {
                let name = accounts.first { $0.id == id }?.name ?? "Claude"
                print(String(format: "  account %-18@ %10@  $%.2f", name, Format.tokens(a.totalTokens), a.totalUSD))
            }
        }
        for (name, b) in s.byModel.sorted(by: { $0.value.usd > $1.value.usd }) {
            print(String(format: "  model   %-18@ %10@  $%.2f", name, Format.tokens(b.tokens), b.usd))
        }
        for (name, b) in s.byProject.sorted(by: { $0.value.usd > $1.value.usd }) {
            print(String(format: "  project %-18@ %10@  $%.2f", name, Format.tokens(b.tokens), b.usd))
        }
        if !s.unpricedModels.isEmpty { print("  unpriced: \(s.unpricedModels.sorted().joined(separator: ", "))") }
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: "\(n)"
        case ..<1_000_000: String(format: "%.1fk", Double(n) / 1000)
        default: String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }

    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
}
