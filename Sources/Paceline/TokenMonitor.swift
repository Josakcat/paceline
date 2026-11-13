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
    static let notTranscripts: Set = ["memory", "tool-results"]

    init(root: URL = TokenMonitor.mainRoot,
         onUpdate: @escaping @Sendable (UsageSnapshot, Date?) -> Void) {
        self.root = root
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { self.scan() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let events = FSEvents.read(count: count, paths: paths, flags: flags)
            Unmanaged<TokenMonitor>.fromOpaque(info).takeUnretainedValue().changed(events)
        }
        if FileManager.default.fileExists(atPath: root.path),
           let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, FSEvents.createFlags) {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
        // The midnight rollover, and a full walk every 5 minutes for missed events.
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
    /// Files FSEvents named since the last pass, read on their own.
    private var changedFiles: Set<String> = []
    /// FSEvents lost track (dropped events, a folder to rescan): walk everything next pass.
    private var mustWalk = false
    private var lastWalk = Date.distantPast
    private lazy var realRoot = root.resolvingSymlinksInPath().path

    private func changed(_ events: [FSEvents.Event]) {
        for event in events {
            if FSEvents.mustRescan(event.flags) { mustWalk = true }
            else if let path = Self.transcript(event.path, realRoot: realRoot, root: root.path) { changedFiles.insert(path) }
        }
        if mustWalk || !changedFiles.isEmpty { scanSoon() }
    }

    /// The transcript an FSEvents path names, under `root` as the walk spells it
    /// (FSEvents gives real paths, symlinks resolved); nil for anything else.
    static func transcript(_ path: String, realRoot: String, root: String) -> String? {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(realRoot + "/") else { return nil }
        let rest = path.dropFirst(realRoot.count + 1)
        if rest.split(separator: "/").dropLast().contains(where: { notTranscripts.contains(String($0)) }) { return nil }
        return root + "/" + rest
    }

    /// Claude Code appends to its transcript many times a second while it
    /// answers, so passes are at most 3 s apart.
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
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let newDay = today != dayStart
        if newDay {
            dayStart = today
            entries = [:]
            offsets = [:]
        }
        var latestWrite: Date?
        func note(_ modified: Date?) { if let modified { latestWrite = max(latestWrite ?? .distantPast, modified) } }
        guard FSEvents.walkDue(lastWalk: lastWalk, now: now, newDay: newDay, mustRescan: mustWalk) else {
            // Only the files FSEvents named, each from where the last pass stopped.
            let files = changedFiles
            changedFiles = []
            for path in files { note(read(URL(fileURLWithPath: path))) }
            return latestWrite
        }
        lastWalk = now
        mustWalk = false
        changedFiles = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in walker {
            // Notes and saved tool output, never transcripts: don't open those folders.
            if Self.notTranscripts.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard url.pathExtension == "jsonl" else { continue }
            note(read(url))
        }
        return latestWrite
    }

    /// Reads what was added to one of today's transcripts since the last pass;
    /// its modification date if it was one of today's.
    private func read(_ url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let modified = values.contentModificationDate, modified >= dayStart,
              let size = values.fileSize.map(UInt64.init) else { return nil }
        do {
            var offset = offsets[url.path] ?? 0
            if size < offset { offset = 0 }  // file was rewritten
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return modified }
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
        }
        return modified
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
        // A day has thousands of entries but a handful of models: look each one up once.
        var prices: [String: Pricing.Price?] = [:], names: [String: String] = [:]
        for e in entries.values {
            let tokens = e.input + e.output + e.write5m + e.write1h + e.read
            var usd = 0.0
            if prices[e.model] == nil { prices[e.model] = .some(Pricing.price(for: e.model)) }
            if let p = prices[e.model] ?? nil {
                usd = (Double(e.input) * p.input + Double(e.output) * p.output
                       + Double(e.write5m) * p.input * 1.25 + Double(e.write1h) * p.input * 2
                       + Double(e.read) * p.cacheRead) / 1_000_000
            } else {
                s.unpricedModels.insert(e.model)
            }
            s.totalTokens += tokens
            s.totalUSD += usd
            if names[e.model] == nil { names[e.model] = Pricing.displayName(e.model) }
            let name = names[e.model] ?? e.model
            s.byModel[name, default: UsageBucket()].tokens += tokens
            s.byModel[name, default: UsageBucket()].usd += usd
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

/// What both monitors take from FSEvents: the paths that changed, and when to
/// stop trusting them and walk every folder instead. Pure, except `read`.
enum FSEvents {
    struct Event { let path: String; let flags: FSEventStreamEventFlags }

    /// Paths as CFStrings, one event per file, and RootChanged for a watched folder that moves.
    static let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                                      | kFSEventStreamCreateFlagWatchRoot)
    /// A full walk at most this often while events keep coming, for anything they missed.
    static let walkEvery: TimeInterval = 5 * 60

    static func read(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) -> [Event] {
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        return list.prefix(count).enumerated().map { Event(path: $1, flags: flags[$0]) }
    }

    /// FSEvents lost track: the path is only "something under here changed".
    static func mustRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        let lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        return flags & FSEventStreamEventFlags(lost) != 0
    }

    /// Walk every folder: the first pass, a new day, lost events, or 5 minutes since the last walk.
    static func walkDue(lastWalk: Date, now: Date, newDay: Bool, mustRescan: Bool) -> Bool {
        newDay || mustRescan || now.timeIntervalSince(lastWalk) >= walkEvery
    }

    /// The path below the first of `roots` it is under ("" for a root itself).
    static func relative(_ path: String, roots: [String]) -> String {
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return "" }
        return String(path.dropFirst(root.count + 1))
    }

    /// Which watched folders a changed path is under (`roots[i]` are source i's
    /// folders, real paths); a path under none of them names nothing.
    static func owners(of path: String, roots: [[String]]) -> Set<Int> {
        let path = path.hasSuffix("/") ? String(path.dropLast()) : path
        return Set(roots.indices.filter { i in roots[i].contains { path == $0 || path.hasPrefix($0 + "/") } })
    }
}
