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

        // The legend's 7-day totals, in the unit shown.
        let tokenTotals = UsageHistory.totals(last, showUSD: false), usdTotals = UsageHistory.totals(last, showUSD: true)
        check(tokenTotals["Claude"] == "1.9k" && tokenTotals["Codex"] == "1.96M" && tokenTotals["OpenCode"] == nil,
              "tokens: each AI's 7 days added up, plan lows left out → \(tokenTotals.sorted { $0.key < $1.key })")
        check(usdTotals["Claude"] == "$5.00" && usdTotals["Cline"] == "$0.00" && usdTotals["Codex"] == "$?",
              "$: free is $0.00, no price yet is $? → \(usdTotals.sorted { $0.key < $1.key })")

        // Small AIs still show: at least 2.5 pt, the tallest day keeps its height, order kept.
        let plot = 34.0, real = [[190e6, 258e6, 5.7e6], [100e6, 0, 0.2e6], [], [0, 0, 0]]
        let drawn = ChartHeights.drawn(real, plotHeight: plot)
        let top = real.map { $0.reduce(0, +) }.max()!, point = top / plot
        let shape = drawn.map(\.count) == real.map(\.count)
        check(shape && drawn[0][2] / point >= 2.5 - 1e-9 && drawn[1][1] == 0 && drawn[1][2] / point >= 2.5 - 1e-9,
              "a 1% AI is raised to 2.5 pt (\(String(format: "%.2f", drawn[0][2] / point)) pt), 0 stays 0")
        check(drawn.allSatisfy { $0.reduce(0, +) <= top * (1 + 1e-9) } && abs(drawn[0].reduce(0, +) - top) < 1,
              "no day overflows the plot; the tallest keeps the top → \(drawn.map { Int($0.reduce(0, +) / 1e6) })M")
        check(drawn[0][1] > drawn[0][0] && drawn[0][0] > drawn[0][2] && abs(drawn[0][0] / real[0][0] - 1) < 0.1 && drawn[1][0] == real[1][0],
              "big segments keep their order and stay within 10%; a day with room is left alone")
        let crowded = ChartHeights.drawn([[10, 0.01, 0.01, 0.01, 0.01, 0.01]], plotHeight: 34)[0]
        check(abs(crowded.reduce(0, +) - 10.05) < 1e-9 && crowded.dropFirst().allSatisfy { $0 >= 2.5 * 10.05 / 34 - 1e-9 }
              && crowded[0] > crowded[1], "many small ones on the tallest day: the big one gives up the room → \(crowded)")
        let tight = ChartHeights.drawn([[5, 5, 5, 5, 5]], plotHeight: 10)[0]
        check(tight.allSatisfy { abs($0 - 5) < 1e-9 }, "too many for the plot: shared evenly, never past the top")
        check(ChartHeights.drawn([[0, 0]], plotHeight: 34) == [[0, 0]] && ChartHeights.drawn([[1]], plotHeight: 0) == [[1]], "nothing used: unchanged")

        // Colours: Codex and AIs with no colour of their own are clear on both panels and not grey.
        for (dark, background) in [(true, UInt32(0x1E1E1E)), (false, UInt32(0xFFFFFF))] {
            let colors = ["Codex", "Kiro", "Unknown AI"].map { ChartColors.color(forKey: $0, accounts: [], dark: dark) }
            let ratios = colors.map { ChartColors.contrast($0, background) }
            check(ratios.allSatisfy { $0 >= 3 } && !colors.contains(ChartColors.gray) && !colors.contains(Providers.named("Claude")!.color),
                  "\(dark ? "dark" : "light"): Codex and unbranded AIs 3:1 on the panel → \(ratios.map { String(format: "%.2f", $0) })")
        }
        return failures
    }
}
