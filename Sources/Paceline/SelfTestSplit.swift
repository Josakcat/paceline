import Foundation

extension SelfTest {
    /// Claude's tokens and $ per account (N11 in docs/bug-audit-2026-11-08.md).
    static func splitUsageTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  split: \(what)")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("paceline-split-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let now = Date(), dayStart = Calendar.current.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = iso.string(from: max(now.addingTimeInterval(-60), dayStart))
        func transcript(_ dir: URL, requests: [(id: String, input: Int, output: Int)]) {
            let folder = dir.appendingPathComponent("projects/-x-app")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let lines = requests.map {
                #"{"type":"assistant","timestamp":"\#(stamp)","requestId":"r-\#($0.id)","cwd":"/x/app","message":{"id":"m-\#($0.id)","model":"claude-sonnet-5-5","usage":{"input_tokens":\#($0.input),"output_tokens":\#($0.output)}}}"#
            }
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("s.jsonl"))
        }
        let main = base.appendingPathComponent("main"), work = base.appendingPathComponent("work")
        let linked = base.appendingPathComponent("linked"), unlisted = base.appendingPathComponent("unlisted")
        transcript(main, requests: [("a", 1000, 100), ("b", 2000, 200)])
        transcript(work, requests: [("c", 500, 50)])
        transcript(unlisted, requests: [("d", 9000, 900)])
        try? fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: linked.appendingPathComponent("projects"), withDestinationURL: main.appendingPathComponent("projects"))

        let accounts = [ClaudeAccount(id: "work", name: "Work", configDir: work.path),
                        ClaudeAccount(id: "linked", name: "Linked", configDir: linked.path),
                        ClaudeAccount(id: "again", name: "Again", configDir: work.path + "/../work")]
        let roots = TokenMonitor.roots(main: main.appendingPathComponent("projects"), accounts: accounts)
        check(roots.map(\.id) == ["claude", "work"], "a folder linked to the main one, or another's again, is read once → \(roots.map(\.id))")
        check(!roots.contains { $0.root.path.hasPrefix(unlisted.path) }, "a folder not in the list isn't read")

        let usage = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, TokenMonitor(root: $0.root, onUpdate: { _, _ in }).scanNow()) })
        let mainUsage = usage["claude"] ?? UsageSnapshot(), workUsage = usage["work"] ?? UsageSnapshot()
        check(mainUsage.totalTokens == 3300 && mainUsage.messages == 2, "the main account's own: 3,300 tokens, 2 requests → \(mainUsage.totalTokens)")
        check(workUsage.totalTokens == 550 && workUsage.messages == 1, "Work's own: 550 tokens, 1 request → \(workUsage.totalTokens)")
        check(abs(workUsage.totalUSD - (500 * 2 + 50 * 10) / 1_000_000) < 1e-12, "Work's $ at Sonnet 5.5's price")

        let total = AppModel.claudeUsage(main: mainUsage, accounts: ["work": workUsage, "gone": workUsage], listed: Array(accounts.prefix(1)))
        check(total.totalTokens == 3850 && total.messages == 3 && total.byModel["Sonnet 5.5"]?.tokens == 3850 && total.byProject["app"]?.tokens == 3850,
              "the total is every listed account's, a removed one's left out → \(total.totalTokens)")

        // History: under the id, so a new name carries on; lows too.
        let byAI = AppModel.usageByAI(usage: mainUsage, accounts: [(accounts[0], workUsage)], other: [], now: now)
        check(byAI.keys.sorted() == ["Claude", "Claude:work"], "history keys: Claude and Claude:work → \(byAI.keys.sorted())")
        let plan = PlanUsage(agent: "Work", windows: [PlanWindow(label: "5h", left: 40, resets: now.addingTimeInterval(3600))], at: now)
        var history = UsageHistory().recording(usage: byAI, plans: [plan], accounts: [accounts[0]], now: now)
        var renamed = accounts[0]
        renamed.name = "Acme"
        let plan2 = PlanUsage(agent: "Acme", windows: [PlanWindow(label: "5h", left: 30, resets: now.addingTimeInterval(3600))], at: now)
        history = history.recording(usage: byAI, plans: [plan2], accounts: [renamed], now: now)
        let record = history.days[UsageHistory.key(now)]?["Claude:work"]
        check(record?.tokens == 550 && record?.low5h == 30 && history.days[UsageHistory.key(now)]?["Acme"] == nil
              && history.days[UsageHistory.key(now)]?["Work"] == nil, "renamed Work → Acme: one record, under its id → \(String(describing: record))")
        check(UsageHistory.agent(forKey: "Claude:work") == "Claude" && UsageHistory.agent(forKey: "Codex") == "Codex", "an extra account's bars are Claude's colour")
        var old = UsageHistory()
        old.days["2026-11-01"] = ["Claude": DayRecord(tokens: 9, usd: 1), "Work": DayRecord(low5h: 50)]
        let moved = old.migrated(accounts: [accounts[0]]).days["2026-11-01"]
        check(moved?["Claude"]?.tokens == 9 && moved?["Claude:work"]?.low5h == 50 && moved?["Work"] == nil,
              "old history: Claude stays the main account's, Work's lows move to its id")

        // Menu bar: an extra account with no plan % but used today shows its $ or tokens, badged.
        let model = AppModel()
        model.claudeAccounts = [accounts[0]]
        model.plans = []
        model.usage = mainUsage
        model.accountUsage = ["work": workUsage]
        let shown = model.aiReadings.first { $0.name == "Work" }
        let expected = model.showUSD ? Format.usd(workUsage.totalUSD) : Format.tokens(workUsage.totalTokens)   // the setting's left alone
        check(shown?.text == expected && shown?.badge == "2", "Work with no plan, used today: \(shown?.text ?? "nothing") in the menu bar, badge 2")
        check(model.totalTokens >= 3850 && model.claudeByAccount.map(\.name) == ["Claude", "Work"], "the panel's total and lines take in Work")

        // The per-account lines: only accounts used today, and none when only one was.
        let team = ClaudeAccount(id: "team", name: "Team", configDir: "/nowhere")
        let lines = AppModel.byAccount(main: mainUsage, accounts: ["work": workUsage], listed: [accounts[0], team])
        check(lines.map(\.name) == ["Claude", "Work"], "Team, unused today, has no line → \(lines.map(\.name))")
        check(AppModel.byAccount(main: UsageSnapshot(), accounts: ["work": workUsage], listed: [accounts[0], team]).isEmpty
              && AppModel.byAccount(main: mainUsage, accounts: [:], listed: [accounts[0]]).isEmpty, "only one account used today: no per-account lines")

        // History bars: each extra account Claude's a step softer, readable on its background and apart from the next.
        let claudeColor = Providers.named("Claude")?.color ?? 0
        let listed = [accounts[0], team, ClaudeAccount(id: "c", name: "C", configDir: "/c")]
        let keys = ["Claude"] + listed.map { UsageHistory.key(account: $0.id) }
        for (dark, background) in [(true, UInt32(0x1E1E1E)), (false, UInt32(0xFFFFFF))] {
            let colors = keys.map { ChartColors.color(forKey: $0, accounts: listed, dark: dark) }
            let apart = zip(colors, colors.dropFirst()).allSatisfy { ChartColors.contrast($0, $1) >= 1.2 }
            let readable = colors.allSatisfy { ChartColors.contrast($0, background) >= 3 }
            let way = colors.dropFirst().allSatisfy { dark ? ChartColors.luminance($0) > ChartColors.luminance(claudeColor) : ChartColors.luminance($0) < ChartColors.luminance(claudeColor) }
            check(colors[0] == claudeColor && apart && readable && way,
                  "\(dark ? "dark" : "light"): main Claude full, each account a step softer, 3:1 on the panel, 1.2:1 apart → \(colors.map { String($0, radix: 16) })")
        }
        check(ChartColors.color(forKey: "Claude:gone", accounts: listed, dark: true) == ChartColors.shade(claudeColor, step: 3, dark: true)
              && ChartColors.name(forKey: "Claude:work", accounts: listed) == "Work" && ChartColors.color(forKey: "Codex", accounts: listed, dark: true) == Providers.named("Codex")?.color,
              "a removed account takes the softest step; bars are named by account; other AIs keep their colour")

        // Just after midnight: yesterday's (still in a monitor) isn't today's.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!
        var staleWork = workUsage
        staleWork.day = yesterday
        let atMidnight = dayStart.addingTimeInterval(5)
        let midnight = AppModel.usageByAI(usage: mainUsage, accounts: [(accounts[0], staleWork)], other: [], now: atMidnight)
        check(midnight["Claude:work"] == nil, "00:00:05 with Work's yesterday: nothing recorded for it")
        return failures
    }
}
