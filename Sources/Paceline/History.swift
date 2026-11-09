import Foundation

/// One AI's (or account's) day: its tokens and API-equivalent $, and the
/// lowest % left seen of its 5-hour and weekly limits.
struct DayRecord: Codable, Equatable, Sendable {
    var tokens = 0
    var usd = 0.0
    var low5h: Int?
    var lowWeek: Int?
    /// Tokens of models with no known price (they count as $0); nil when none,
    /// or on days recorded before this was kept.
    var unpricedTokens: Int?
}

/// ~/Library/Application Support/Paceline/history.json:
/// `{"days": {"2026-11-08": {"Claude": {"tokens": …, "usd": …, "low5h": 31, "lowWeek": 88}, "Claude:work": …, …}}}`
/// "Claude" is the main account (always was); an extra one is "Claude:<id>",
/// its id, so renaming it keeps its days.
struct UsageHistory: Codable, Equatable, Sendable {
    var days: [String: [String: DayRecord]] = [:]

    static let keptDays = 30

    /// An extra Claude account's key.
    static func key(account id: String) -> String { "Claude:" + id }

    /// Who a key's bar is coloured as: every Claude account is Claude.
    static func agent(forKey key: String) -> String { key.hasPrefix("Claude:") ? "Claude" : key }

    /// Before keys were ids, an extra account's lows were kept under its name:
    /// those move to its id (the lower of each low is kept).
    func migrated(accounts: [ClaudeAccount]) -> UsageHistory {
        var out = self
        for (day, records) in days {
            var moved = records
            for account in accounts where Providers.named(account.name) == nil {
                guard let old = moved.removeValue(forKey: account.name) else { continue }
                var record = moved[Self.key(account: account.id)] ?? DayRecord()
                record.tokens = max(record.tokens, old.tokens)
                record.usd = max(record.usd, old.usd)
                record.low5h = [record.low5h, old.low5h].compactMap { $0 }.min()
                record.lowWeek = [record.lowWeek, old.lowWeek].compactMap { $0 }.min()
                moved[Self.key(account: account.id)] = record
            }
            out.days[day] = moved
        }
        return out
    }

    /// Today's figures folded in: tokens and $ are today's running totals so
    /// far (they replace), the lows only ever go down. Days past 30 are dropped.
    /// Old plans (6 h+) don't count as today's lows.
    /// An extra account's plan (named by the account) goes under its id.
    /// `unpriced`: each AI's tokens with no known price today.
    func recording(usage: [String: (tokens: Int, usd: Double)], unpriced: [String: Int] = [:], plans: [PlanUsage],
                   accounts: [ClaudeAccount] = [], now: Date = Date()) -> UsageHistory {
        let today = Self.key(now)
        var day = days[today] ?? [:]
        for (agent, figures) in usage where figures.tokens > 0 {
            day[agent, default: DayRecord()].tokens = figures.tokens
            day[agent, default: DayRecord()].usd = figures.usd
            day[agent, default: DayRecord()].unpricedTokens = unpriced[agent].flatMap { $0 > 0 ? $0 : nil }
        }
        for agent in Set(plans.map(\.agent)) {
            let fresh = plans.filter { $0.agent == agent && !$0.isStale(now: now) }
            func lowest(_ label: String) -> Int? {
                fresh.compactMap { $0.window(label) }.filter { !$0.wasReset }.map(\.left).min()
            }
            let key = accounts.first { $0.name == agent }.map { Self.key(account: $0.id) } ?? agent
            var record = day[key, default: DayRecord()]
            if let low5h = lowest("5h") ?? lowest("Day") { record.low5h = min(record.low5h ?? 100, low5h) }
            if let lowWeek = lowest("Week") { record.lowWeek = min(record.lowWeek ?? 100, lowWeek) }
            if record != DayRecord() { day[key] = record }
        }
        var out = self
        out.days[today] = day.isEmpty ? nil : day
        let oldest = Self.key(Self.calendar.date(byAdding: .day, value: -(Self.keptDays - 1), to: now) ?? now)
        out.days = out.days.filter { $0.key >= oldest }
        return out
    }

    /// The last `count` days, oldest first, every day there (empty ones too),
    /// each with its per-AI records.
    func last(_ count: Int, now: Date = Date()) -> [(day: Date, records: [String: DayRecord])] {
        (0..<count).reversed().compactMap { back in
            Self.calendar.date(byAdding: .day, value: -back, to: Self.calendar.startOfDay(for: now)).map { ($0, days[Self.key($0)] ?? [:]) }
        }
    }

    /// "2026-11-08", local time, Gregorian (whatever calendar the Mac uses).
    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // MARK: - Chart legend

    /// Every key with tokens or $ in these days, in the bars' order. A key
    /// with tokens but no $ (no known price) is listed too, so it isn't lost.
    static func legendKeys(_ days: [(day: Date, records: [String: DayRecord])], accounts: [ClaudeAccount],
                           order: [String] = []) -> [String] {
        let used = days.flatMap { $0.records.filter { $0.value.tokens > 0 || $0.value.usd > 0 }.map(\.key) }
        return ChartColors.stackOrder(used, accounts: accounts, order: order)
    }

    /// In $ only: the AIs whose days add up to $0 only because their models
    /// have no known price, e.g. "Codex: 1.96M tokens · no price yet".
    /// Free use (no unpriced tokens recorded) isn't listed.
    static func unpricedNote(_ days: [(day: Date, records: [String: DayRecord])], accounts: [ClaudeAccount],
                             order: [String] = [], showUSD: Bool) -> String? {
        guard showUSD else { return nil }
        let parts = legendKeys(days, accounts: accounts, order: order).compactMap { key -> String? in
            let records = days.compactMap { $0.records[key] }
            let unpriced = records.reduce(0) { $0 + ($1.unpricedTokens ?? 0) }
            guard unpriced > 0, records.reduce(0, { $0 + $1.usd }) <= 0 else { return nil }
            return "\(ChartColors.name(forKey: key, accounts: accounts)): \(Format.tokens(unpriced)) tokens"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ") + " · no price yet"
    }

    // MARK: - File

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Paceline/history.json")

    static func load() -> UsageHistory {
        guard !Demo.isOn else { return Demo.history() }
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(UsageHistory.self, from: $0) } ?? UsageHistory()
    }

    /// Never in demo mode.
    func save() {
        guard !Demo.isOn, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }
}
