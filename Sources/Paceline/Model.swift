import AppKit
import Observation

/// What the menu bar icon reads: every AI side by side, or only the one used last.
enum MenuBarShows: String, CaseIterable, Sendable {
    case all, latest
    var label: String { self == .all ? "All AIs" : "Latest used AI" }
}

/// How each AI's reading is drawn: one number, or the five hours over the week.
enum MenuBarStyle: String, CaseIterable, Sendable {
    case compact, twoRows = "tworows"
    var label: String { self == .compact ? "Compact" : "Two rows" }
}

/// This app was AgentPet. Only on a Mac that had it: its settings, its
/// second Claude account and its plan files come along.
enum Legacy {
    static let agentPetWasHere = UserDefaults.standard.persistentDomain(forName: DefaultsMigration.legacyDomain) != nil
}

/// AgentPet's settings come along once.
enum DefaultsMigration {
    static let legacyDomain = "com.josakcat.agentpet"
    static let doneKey = "migratedFromAgentPet"
    /// Only what Paceline still uses: the old domain also holds the cat's and the PII scrubber's settings.
    static let keys: Set = ["showUSD", "menuBarShows", "menuBarStyle", "hideFromSharing", "appearance"]

    /// Copies each old setting in `keys` that `domain` doesn't have saved yet,
    /// then marks it done so it never runs again. Looks at what's saved in
    /// `domain` only: registered defaults would read as already set.
    static func run(from old: [String: Any]?, to new: UserDefaults, domain: String) {
        let saved = new.persistentDomain(forName: domain) ?? [:]
        guard saved[doneKey] as? Bool != true else { return }
        for (key, value) in old ?? [:] where keys.contains(key) && saved[key] == nil {
            new.set(value, forKey: key)
        }
        new.set(true, forKey: doneKey)
    }
}

/// The user's order of the AIs, for the menu bar and the panel ("aiOrder"):
/// stable keys, the AI's name or "Claude:<id>" for an extra Claude account,
/// so a rename keeps its place. Empty is the built-in order.
enum AIOrder {
    static let defaultsKey = "aiOrder"

    /// An AI's key: an extra Claude account goes by its id, the rest by name.
    static func key(_ name: String, accounts: [ClaudeAccount]) -> String {
        accounts.first { $0.name == name }.map { UsageHistory.key(account: $0.id) } ?? name
    }

    /// `items` in the saved order; those not in it (new, or a new account) come
    /// after, keeping their built-in order. Saved keys with nothing behind them
    /// (a removed account) are skipped.
    static func sorted<T>(_ items: [T], saved: [String], key: (T) -> String) -> [T] {
        guard !saved.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (i, k) in saved.enumerated() where rank[k] == nil { rank[k] = i }
        return items.enumerated().sorted { a, b in
            let (x, y) = (rank[key(a.element)] ?? saved.count + a.offset, rank[key(b.element)] ?? saved.count + b.offset)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// What to save once the shown keys are put in `shown` order. A saved key
    /// not shown now (no numbers today) stays right after the one it followed.
    static func merged(_ shown: [String], saved: [String]) -> [String] {
        guard !shown.isEmpty else { return saved }
        let visible = Set(shown)
        var after: [String: [String]] = [:], leading: [String] = []
        var anchor: String?
        for k in saved {
            if visible.contains(k) { anchor = k; continue }
            if let anchor { after[anchor, default: []].append(k) } else { leading.append(k) }
        }
        var out = leading
        for k in shown { out.append(k); out += after[k] ?? [] }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The slot a row dragged `offset` points from `start` lands in: one slot per
    /// `rowHeight`, past half a row, kept inside the list.
    static func dropIndex(start: Int, offset: Double, rowHeight: Double, count: Int) -> Int {
        min(max(start + Int((offset / rowHeight).rounded()), 0), count - 1)
    }

    /// `shown` with the rows at `from` moved before `to` (List.onMove's terms), merged into `saved`.
    static func moved(_ shown: [String], from: IndexSet, to: Int, saved: [String]) -> [String] {
        var keys = shown
        let moving = from.sorted().map { keys[$0] }
        let before = from.filter { $0 < to }.count
        for i in from.sorted(by: >) { keys.remove(at: i) }
        keys.insert(contentsOf: moving, at: min(max(to - before, 0), keys.count))
        return merged(keys, saved: saved)
    }
}

@MainActor @Observable
final class AppModel {
    @ObservationIgnored private let defaults = Demo.defaults

    // Settings (UserDefaults, domain com.josakcat.paceline)
    var showUSD: Bool { didSet { defaults.set(showUSD, forKey: "showUSD") } }
    var menuBarShows: MenuBarShows { didSet { defaults.set(menuBarShows.rawValue, forKey: "menuBarShows") } }
    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    var hideFromScreenSharing: Bool { didSet { defaults.set(hideFromScreenSharing, forKey: "hideFromSharing") } }
    var notify: Bool { didSet { defaults.set(notify, forKey: "notify") } }
    var fetchFresh: Bool { didSet { defaults.set(fetchFresh, forKey: "fetchFresh") } }   // FreshLimits, off by default
    var appearance: GlassAppearance {
        didSet { if let data = try? JSONEncoder().encode(appearance) { defaults.set(data, forKey: "appearance") } }
    }
    /// The user's order of the AIs (AIOrder); `--selftest` neither reads nor saves it.
    var aiOrder: [String] {
        didSet {
            guard keepsOrder else { return }
            if aiOrder.isEmpty { defaults.removeObject(forKey: AIOrder.defaultsKey) } else { defaults.set(aiOrder, forKey: AIOrder.defaultsKey) }
        }
    }
    @ObservationIgnored private let keepsOrder = !CommandLine.arguments.contains("--selftest")
    /// Read once at launch.
    let debugEndpoints: Bool

    // Live state
    var usage = UsageSnapshot()          // Claude Code, main account (TokenMonitor.swift)
    var accountUsage: [String: UsageSnapshot] = [:]   // extra Claude accounts', by id
    var accountLastActive: [String: Date] = [:]       // their newest transcript writes
    var otherUsage: [SourceUsage] = []   // Antigravity etc. (UsageSources.swift)
    var plans: [PlanUsage] = []          // subscription limits left (PlanUsage.swift)
    var claudeLastActive: Date?          // newest Claude Code transcript write, for "latest used"
    var settingsTab: SettingsTab = .general
    var orderExpanded = false                     // Settings → General → Order, unfolded
    var claudeAccounts = ClaudeAccounts.load()   // extra Claude accounts (ClaudeAccounts.swift)
    var history = UsageHistory()                  // the last 30 days (History.swift)
    var addAccountStep: Int?                      // the "Add Claude account…" sheet, when it's up
    var addAccountSample = ""                     // a name to start it with (`--debug add-account`)
    var suggestions: [Suggestion] = []            // sign-ins and found accounts (Suggestions.swift), all of them
    var shownSuggestions: [Suggestion] = []       // the panel's card: those not dismissed
    var pendingFound: Suggestion?                 // a found Claude folder waiting for its name in Settings
    var signInWaiting: Set<String> = []           // AIs whose Sign in… was pressed, watched until signed in
    var signInDone: Set<String> = []              // signed in since: a ✓ in the card for a while
    var signInsChanged = 0                        // bumped when one signs in, so Settings reads them again
    var installGuide: String?                     // the AI whose Install… sheet is up
    var accountDetails: String?                   // the AI whose ⓘ popover is open in Settings → Accounts

    init() {
        defaults.register(defaults: [
            "showUSD": true, "menuBarShows": MenuBarShows.all.rawValue, "menuBarStyle": MenuBarStyle.compact.rawValue,
            "hideFromSharing": true, "notify": false, "fetchFresh": false, "debugEndpoints": false,
        ])
        showUSD = defaults.bool(forKey: "showUSD")
        menuBarShows = MenuBarShows(rawValue: defaults.string(forKey: "menuBarShows") ?? "") ?? .all
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .compact
        hideFromScreenSharing = defaults.bool(forKey: "hideFromSharing")
        notify = defaults.bool(forKey: "notify")
        fetchFresh = defaults.bool(forKey: "fetchFresh")
        appearance = defaults.data(forKey: "appearance").flatMap { try? JSONDecoder().decode(GlassAppearance.self, from: $0) } ?? .standard
        debugEndpoints = defaults.bool(forKey: "debugEndpoints")
        aiOrder = keepsOrder ? defaults.stringArray(forKey: AIOrder.defaultsKey) ?? [] : []
    }

    /// An AI's key in `aiOrder`.
    func orderKey(_ name: String) -> String { AIOrder.key(name, accounts: claudeAccounts) }
    /// The panel's plans, in the user's order (PlanSection keeps first-seen order).
    var orderedPlans: [PlanUsage] { AIOrder.sorted(plans, saved: aiOrder) { orderKey($0.agent) } }

    /// Claude Code plus exact counts from other tools. Estimates never count toward the totals.
    private var exactOther: [SourceUsage] { otherUsage.filter { $0.accuracy == .exact } }
    var spend: Double { claudeUsage.totalUSD + exactOther.reduce(0) { $0 + $1.usd } }
    var totalTokens: Int { claudeUsage.totalTokens + exactOther.reduce(0) { $0 + $1.total.total } }
    /// Every listed Claude account's today as one.
    var claudeUsage: UsageSnapshot { Self.claudeUsage(main: usage, accounts: accountUsage, listed: claudeAccounts) }
    /// A removed account's last numbers (until its monitor's gone) never count.
    static func claudeUsage(main: UsageSnapshot, accounts: [String: UsageSnapshot], listed: [ClaudeAccount]) -> UsageSnapshot {
        accounts.isEmpty ? main : .combined([main] + listed.compactMap { accounts[$0.id] })
    }
    /// The panel's per-account lines: the main account, then each listed one
    /// (or in the user's order), only those used today; none when that's one
    /// (the Claude total says it).
    var claudeByAccount: [(name: String, usage: UsageSnapshot)] {
        Self.byAccount(main: usage, accounts: accountUsage, listed: claudeAccounts, order: aiOrder)
    }

    static func byAccount(main: UsageSnapshot, accounts: [String: UsageSnapshot], listed: [ClaudeAccount],
                          order: [String] = []) -> [(name: String, usage: UsageSnapshot)] {
        let all = [("Claude", "Claude", main)] + listed.map { (UsageHistory.key(account: $0.id), $0.name, accounts[$0.id] ?? UsageSnapshot()) }
        let used = AIOrder.sorted(all.filter { $0.2.totalTokens > 0 }, saved: order) { $0.0 }.map { (name: $0.1, usage: $0.2) }
        return used.count > 1 ? used : []
    }
    /// Other AIs with something today, for the panel.
    var usedToday: [SourceUsage] {
        AIOrder.sorted(otherUsage.filter { $0.total.messages > 0 || $0.note != nil }, saved: aiOrder) { orderKey($0.source) }
    }
    /// Today's tokens and $ per AI, for the history.
    var usageByAI: [String: (tokens: Int, usd: Double)] {
        Self.usageByAI(usage: usage, accounts: claudeAccounts.compactMap { a in accountUsage[a.id].map { (a, $0) } }, other: exactOther)
    }

    /// Only numbers counted for today: just after midnight a monitor can still
    /// hold yesterday's until its next pass, and those mustn't become today's.
    /// Extra accounts go under their id (UsageHistory.key(account:)), not their name.
    static func usageByAI(usage: UsageSnapshot, accounts: [(ClaudeAccount, UsageSnapshot)] = [], other: [SourceUsage],
                          now: Date = Date()) -> [String: (tokens: Int, usd: Double)] {
        let today = Calendar.current.startOfDay(for: now)
        var out: [String: (tokens: Int, usd: Double)] = [:]
        if usage.day == nil || usage.day == today { out["Claude"] = (usage.totalTokens, usage.totalUSD) }
        for (account, u) in accounts where u.day == nil || u.day == today {
            out[UsageHistory.key(account: account.id)] = (u.totalTokens, u.totalUSD)
        }
        for source in other where source.day == nil || source.day == today { out[source.source] = (source.total.total, source.usd) }
        return out
    }

    /// Today's tokens with no known price per AI, for the history (same keys and day check as usageByAI).
    var unpricedByAI: [String: Int] {
        Self.unpricedByAI(usage: usage, accounts: claudeAccounts.compactMap { a in accountUsage[a.id].map { (a, $0) } }, other: exactOther)
    }

    static func unpricedByAI(usage: UsageSnapshot, accounts: [(ClaudeAccount, UsageSnapshot)] = [], other: [SourceUsage],
                             now: Date = Date()) -> [String: Int] {
        let today = Calendar.current.startOfDay(for: now)
        func unpriced(_ u: UsageSnapshot) -> Int {
            Set(u.unpricedModels.map(Pricing.displayName)).reduce(0) { $0 + (u.byModel[$1]?.tokens ?? 0) }
        }
        var out: [String: Int] = [:]
        if usage.day == nil || usage.day == today { out["Claude"] = unpriced(usage) }
        for (account, u) in accounts where u.day == nil || u.day == today { out[UsageHistory.key(account: account.id)] = unpriced(u) }
        for source in other where source.day == nil || source.day == today {
            out[source.source] = source.unpricedModels.reduce(0) { $0 + (source.byModel[$1]?.total ?? 0) }
        }
        return out.filter { $0.value > 0 }
    }

    /// Some of today's tokens have no known price (they count as $0).
    var hasUnpriced: Bool { !claudeUsage.unpricedModels.isEmpty || exactOther.contains { !$0.unpricedModels.isEmpty } }
    var totalRequests: Int { claudeUsage.messages + exactOther.reduce(0) { $0 + $1.total.messages } }
    var claudePlan: PlanUsage? { plans.first { $0.agent == "Claude" } }
    /// Claude's five-hour window is nearly used up.
    var planLow: Bool { (claudePlan?.window("5h")?.left ?? 100) <= 20 }

    /// One reading per AI for the menu bar: plan % left when known (that's
    /// what a subscription runs out of), else today's $ or tokens. In the
    /// user's order (Settings → General → Order), else Claude and its accounts first.
    var aiReadings: [AIReading] { AIOrder.sorted(builtInReadings, saved: aiOrder) { orderKey($0.name) } }

    private var builtInReadings: [AIReading] {
        var readings: [AIReading] = []
        let claude = claudePlan?.shortWindow ?? claudePlan?.window("Week")
        if claude != nil || usage.totalTokens > 0 {
            readings.append(AIReading(name: "Claude", text: claude.map { "\($0.left)%" } ?? amount(usage.totalUSD, usage.totalTokens),
                                      low: planLow, lastActive: [claudeLastActive, Self.usedAt([claudePlan].compactMap { $0 })].compactMap { $0 }.max(),
                                      rows: Self.planRows([claudePlan].compactMap { $0 }),
                                      staleNote: claude == nil ? nil : Self.staleNote([claudePlan].compactMap { $0 })))
        }
        // Extra Claude accounts sit next to the first, in list order: plan % left,
        // else today's $ or tokens like the first.
        readings += claudeAccounts.enumerated().compactMap { i, account in
            let used = accountUsage[account.id] ?? UsageSnapshot()
            let plan = planReading(account.name)
            guard plan != nil || used.totalTokens > 0 else { return nil }
            var reading = AIReading(name: account.name, text: plan?.text ?? amount(used.totalUSD, used.totalTokens), low: plan?.low ?? false,
                                    lastActive: [plan?.lastActive, accountLastActive[account.id]].compactMap { $0 }.max(),
                                    rows: plan?.rows ?? [], staleNote: plan?.staleNote)
            reading.badge = String(i + 2)
            return reading
        }
        for source in exactOther {
            // Several model groups (Gemini, Claude…): the one closest to running out.
            let windows = plans.filter { $0.agent == source.source }.compactMap { $0.shortWindow ?? $0.window("Week") }
            let tightest = windows.min { $0.left < $1.left }
            guard tightest != nil || source.total.total > 0 else { continue }
            readings.append(AIReading(name: source.source, text: tightest.map { "\($0.left)%" } ?? amount(source.usd, source.total.total),
                                      low: (tightest?.left ?? 100) <= 20,
                                      lastActive: [source.lastActivity, Self.usedAt(plans.filter { $0.agent == source.source })].compactMap { $0 }.max(),
                                      rows: Self.planRows(plans.filter { $0.agent == source.source }),
                                      staleNote: tightest == nil ? nil : Self.staleNote(plans.filter { $0.agent == source.source })))
        }
        // A plan read from disk with no usage today (e.g. Antigravity via Pixpaw) still counts.
        for agent in Set(plans.map(\.agent)).sorted() where !readings.contains(where: { $0.name == agent }) {
            if let reading = planReading(agent) { readings.append(reading) }
        }
        return readings
    }

    /// When these plans were last saved by using the AI (not by Paceline asking): for "latest used".
    static func usedAt(_ plans: [PlanUsage]) -> Date? { plans.filter { !$0.fetched }.map(\.at).max() }

    /// The tightest window of an agent's plan, from disk alone.
    private func planReading(_ agent: String) -> AIReading? {
        let windows = plans.filter { $0.agent == agent }
        guard let tightest = windows.compactMap({ $0.shortWindow ?? $0.window("Week") }).min(by: { $0.left < $1.left }) else { return nil }
        return AIReading(name: agent, text: "\(tightest.left)%", low: tightest.left <= 20, lastActive: Self.usedAt(windows),
                         rows: Self.planRows(windows), staleNote: Self.staleNote(windows))
    }

    /// Two rows: % left of the five hours, then of the week, each the tightest
    /// across model groups. A window nobody reports is left out.
    static func planRows(_ plans: [PlanUsage], now: Date = Date()) -> [AIReading.Row] {
        ["5h", "Day", "Week"].compactMap { label in
            let tightest = plans.compactMap { plan in plan.window(label).map { (plan, $0) } }.min { $0.1.left < $1.1.left }
            return tightest.map { plan, window in
                var runsOut: TimeInterval?
                if case .runsOut(let t)? = plan.pace(window, now: now) { runsOut = t }
                return AIReading.Row(text: "\(window.left)", low: window.left <= 20, window: label, runsOut: runsOut)
            }
        }
    }

    /// "5h 59% · Week 38% left", for Settings → Accounts.
    static func planSummary(_ plans: [PlanUsage]) -> String? {
        let rows = planRows(plans)
        return rows.isEmpty ? nil : rows.map { "\($0.window) \($0.text)%" }.joined(separator: " · ") + " left"
    }

    /// "as of 7 h ago" when the newest of these plans is stale.
    static func staleNote(_ plans: [PlanUsage], now: Date = Date()) -> String? {
        guard let newest = plans.max(by: { $0.at < $1.at }), newest.isStale(now: now) else { return nil }
        return newest.age(now: now)
    }

    private func amount(_ usd: Double, _ tokens: Int) -> String { showUSD ? Format.usd(usd) : Format.tokens(tokens) }
}
