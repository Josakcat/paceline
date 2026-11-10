import Foundation

extension SelfTest {
    /// AccountSwitch: which Claude account to switch to, and its line in plan alerts.
    static func accountSwitchTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  switch: \(what)")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000), home = "/home/test"
        let resets = now.addingTimeInterval(600)   // near the end of the round: low is low, but on pace
        let work = ClaudeAccount(id: "work", name: "Work", configDir: home + "/.claude-work")
        let odd = ClaudeAccount(id: "odd", name: "Odd", configDir: home + "/my claude")
        func plan(_ agent: String, _ five: Int, _ week: Int = 90, at: Date = now, fiveResets: Date = resets) -> PlanUsage {
            PlanUsage(agent: agent, windows: [PlanWindow(label: "5h", left: five, resets: fiveResets),
                                              PlanWindow(label: "Week", left: week, resets: now.addingTimeInterval(3 * 86400))], at: at)
        }
        func hint(_ plans: [PlanUsage], _ accounts: [ClaudeAccount] = [work], from: String? = nil) -> AccountSwitch.Hint? {
            AccountSwitch.hint(plans, accounts: accounts, now: now, from: from, home: home)
        }

        let h = hint([plan("Claude", 12), plan("Work", 80, 85)])
        check(h?.from == "Claude" && h?.to == "Work" && h?.toLeft == 80 && h?.window == "5h",
              "Claude at 12%, Work at 80% → switch to Work (\(String(describing: h)))")
        check(h?.text == "Work has 80% left — switch to it for now" && h?.why == "Claude: 12% of the 5-hour limit left", "the words")
        check(h?.command == "CLAUDE_CONFIG_DIR=~/.claude-work claude", "the command: \(h?.command ?? "nil")")
        check(h?.id == "Claude|5h|\(Int(resets.timeIntervalSince1970))", "dismissed per round: \(h?.id ?? "nil")")
        check(hint([plan("Claude", 12)]) == nil, "one account: nothing")
        check(hint([plan("Claude", 12), plan("Work", 80)], []) == nil, "Work not listed: nothing")
        check(hint([plan("Claude", 12), plan("Work", 80, at: now.addingTimeInterval(-7 * 3600))]) == nil, "Work's numbers stale: nothing")
        check(hint([plan("Claude", 12, at: now.addingTimeInterval(-7 * 3600)), plan("Work", 80)]) == nil, "the low one stale: nothing")
        check(hint([plan("Claude", 50), plan("Work", 90)]) == nil, "nobody low: nothing")
        check(hint([plan("Claude", 15), plan("Work", 30)]) == nil, "both about the same: nothing")
        check(hint([plan("Claude", 15), plan("Work", 39)]) == nil, "Work not clearly more (under 40%): nothing")
        check(hint([plan("Claude", 15), plan("Work", 90, 18)]) == nil, "Work's week low itself: nothing")
        check(hint([plan("Claude", 90, 10), plan("Work", 70, 75)])?.window == "Week", "a low week counts too")
        check(hint([plan("Work", 8), plan("Claude", 85)])?.command == "claude", "back to the main account: plain claude")
        check(hint([plan("Claude", 10), plan("Work", 60), plan("Odd", 95)], [work, odd])?.command == "CLAUDE_CONFIG_DIR='/home/test/my claude' claude",
              "the one with most left, its folder quoted")
        let reset = plan("Claude", 100, fiveResets: now.addingTimeInterval(-60))
        check(hint([PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 100, resets: nil, wasReset: true)], at: now), plan("Work", 90)]) == nil
              && hint([reset, plan("Work", 90)]) == nil, "the low round reset since: nothing")
        // 50% gone in the first two hours of five: runs out an hour before the reset.
        let fast = plan("Claude", 50, fiveResets: now.addingTimeInterval(3 * 3600))
        check(hint([fast, plan("Work", 95)])?.from == "Claude", "running out before the reset counts as low")
        check(hint([plan("Claude", 12), plan("Work", 80)], from: "Work") == nil, "from another account: nothing")

        // Plan alerts: the same alert says it; no extra alert.
        let plans = [plan("Claude", 18), plan("Work", 80, 85)]
        let alone = PlanAlerts.due(plans, sent: [], now: now).alerts
        let told = PlanAlerts.due(plans, sent: [], now: now, accounts: [work]).alerts
        check(told.count == alone.count && told.count == 1, "alerts: no more of them (\(told.count))")
        check(told.first?.body == "Resets in 10m. Work has 80% left — switch to it for now.", "alerts: the body says where to switch: \(told.first?.body ?? "nil")")
        let fine = PlanAlerts.due([plan("Claude", 18), plan("Work", 30)], sent: [], now: now, accounts: [work]).alerts
        check(fine.first?.body == "Resets in 10m.", "alerts: nothing to switch to, body as before")
        return failures
    }
}
