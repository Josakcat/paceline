import Foundation

extension SelfTest {
    /// The 7-day chart's legend and its note on AIs with no known price.
    static func chartLegendTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  chart legend: \(what)")
        }
        let work = ClaudeAccount(id: "work", name: "Work", configDir: "/tmp/paceline-selftest-work")
        let now = Date()
        var history = UsageHistory()
        let days = history.last(7, now: now).map(\.day)
        history.days[UsageHistory.key(days[5])] = [
            "Claude": DayRecord(tokens: 900, usd: 2), "Antigravity": DayRecord(tokens: 300, usd: 0.4),
            "Cline": DayRecord(tokens: 200, usd: 0),   // $0, no unpriced tokens recorded: free, not unknown
        ]
        history.days[UsageHistory.key(days[6])] = [
            "Claude": DayRecord(tokens: 1000, usd: 3, unpricedTokens: 50),   // partly unpriced, but has $
            UsageHistory.key(account: "work"): DayRecord(tokens: 400, usd: 1),
            "Codex": DayRecord(tokens: 1_960_000, usd: 0, unpricedTokens: 1_960_000),
            "OpenCode": DayRecord(low5h: 40),   // plan low only: no legend entry
        ]
        let last = history.last(7, now: now)

        let keys = UsageHistory.legendKeys(last, accounts: [work])
        check(keys == ["Claude", "Claude:work", "Antigravity", "Cline", "Codex"],
              "every key with tokens or $, Claude's accounts first, then by name → \(keys)")
        let ordered = UsageHistory.legendKeys(last, accounts: [work], order: ["Codex", "Cline", "Claude"])
        check(ordered == ["Codex", "Cline", "Claude", "Claude:work", "Antigravity"], "the user's order → \(ordered)")
        check(ChartColors.name(forKey: "Claude:work", accounts: [work]) == "Work", "an added account is named, not its id")

        let note = UsageHistory.unpricedNote(last, accounts: [work], showUSD: true)
        check(note == "Codex: 1.96M tokens · no price yet", "$: only the AI that's $0 for want of a price → \(note ?? "nil")")
        check(UsageHistory.unpricedNote(last, accounts: [work], showUSD: false) == nil, "tokens: no note")
        history.days[UsageHistory.key(days[4])] = ["Kiro": DayRecord(tokens: 3000, unpricedTokens: 3000)]
        let two = UsageHistory.unpricedNote(history.last(7, now: now), accounts: [work], order: ["Kiro"], showUSD: true)
        check(two == "Kiro: 3.0k tokens, Codex: 1.96M tokens · no price yet", "several on one line, in order → \(two ?? "nil")")

        // Recording keeps today's unpriced tokens, and a later pass that prices them clears it.
        var recorded = UsageHistory().recording(usage: ["Codex": (5000, 0)], unpriced: ["Codex": 5000], plans: [], now: now)
        check(recorded.days[UsageHistory.key(now)]?["Codex"]?.unpricedTokens == 5000, "recorded with today's figures")
        recorded = recorded.recording(usage: ["Codex": (6000, 0.5)], plans: [], now: now)
        check(recorded.days[UsageHistory.key(now)]?["Codex"]?.unpricedTokens == nil, "priced later: cleared")
        check(Pricing.price(for: "gpt-6.1-sol").map { ($0.input, $0.cacheRead, $0.output) } ?? (0, 0, 0) == (2, 0.10, 10)
              && Pricing.price(for: "gpt-6.1-terra") == nil, "gpt-6.1-sol priced from OpenAI's page, its siblings not guessed")
        return failures
    }
}
