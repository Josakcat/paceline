import Foundation

extension SelfTest {
    /// Settings → General → Order: the user's order of the AIs.
    static func orderTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  order: \(what)")
        }
        let builtIn = ["Claude", "Claude:work", "Codex", "Antigravity"]
        func sorted(_ saved: [String], _ items: [String] = builtIn) -> [String] { AIOrder.sorted(items, saved: saved) { $0 } }

        check(sorted([]) == builtIn, "nothing saved: the built-in order")
        check(sorted(["Antigravity", "Claude", "Codex", "Claude:work"]) == ["Antigravity", "Claude", "Codex", "Claude:work"],
              "the saved order → \(sorted(["Antigravity", "Claude", "Codex", "Claude:work"]))")
        check(sorted(["Codex", "Claude"]) == ["Codex", "Claude", "Claude:work", "Antigravity"],
              "ones not saved (new) come after, in built-in order → \(sorted(["Codex", "Claude"]))")
        check(sorted(["Claude:gone", "Antigravity", "Old"]) == ["Antigravity", "Claude", "Claude:work", "Codex"],
              "saved keys with nothing behind them are skipped → \(sorted(["Claude:gone", "Antigravity", "Old"]))")
        check(sorted(["Codex", "Codex", "Claude"]) == ["Codex", "Claude", "Claude:work", "Antigravity"], "a key saved twice counts once")

        // Moving: List.onMove's terms, and the arrows.
        let down = AIOrder.moved(builtIn, from: [0], to: 2, saved: [])
        check(down == ["Claude:work", "Claude", "Codex", "Antigravity"], "Claude down one → \(down)")
        let up = AIOrder.moved(builtIn, from: [3], to: 0, saved: [])
        check(up == ["Antigravity", "Claude", "Claude:work", "Codex"], "Antigravity to the top → \(up)")
        // Cursor has no numbers today: it stays after Codex, which it followed.
        let saved = ["Claude", "Codex", "Cursor", "Antigravity"]
        let merged = AIOrder.moved(["Claude", "Codex", "Antigravity"], from: [2], to: 0, saved: saved)
        check(merged == ["Antigravity", "Claude", "Codex", "Cursor"], "one not shown now keeps its place → \(merged)")
        check(AIOrder.merged([], saved: saved) == saved, "nothing shown: the saved order stays")

        // Dragging a row: one slot per row height, past half a row, never off the list.
        let drops = [(1, 12.0), (1, 14.0), (1, -40.0), (0, -200.0), (2, 500.0)].map { AIOrder.dropIndex(start: $0.0, offset: $0.1, rowHeight: 26, count: 4) }
        check(drops == [1, 2, 0, 0, 3], "drag: under half a row stays, past it moves, clamped at both ends → \(drops)")

        // Extra Claude accounts go by id: a rename keeps the place, a removal leaves the rest.
        let work = ClaudeAccount(id: "work", name: "Work", configDir: "/tmp/w")
        check(AIOrder.key("Work", accounts: [work]) == "Claude:work" && AIOrder.key("Codex", accounts: [work]) == "Codex",
              "keys: Claude:<id> for an extra account, else the name")
        let model = AppModel()
        check(model.aiOrder.isEmpty, "--selftest doesn't read the saved order")
        model.claudeAccounts = [work]
        model.plans = [PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 72, resets: nil)], at: Date()),
                       PlanUsage(agent: "Work", windows: [PlanWindow(label: "5h", left: 40, resets: nil)], at: Date()),
                       PlanUsage(agent: "Antigravity", group: "Gemini", windows: [PlanWindow(label: "5h", left: 90, resets: nil)], at: Date())]
        check(model.aiReadings.map(\.name) == ["Claude", "Work", "Antigravity"], "built in: Claude, its account, then the rest")
        model.aiOrder = ["Antigravity", "Claude:work"]
        check(model.aiReadings.map(\.name) == ["Antigravity", "Work", "Claude"], "the menu bar follows → \(model.aiReadings.map(\.name))")
        check(model.orderedPlans.map(\.agent) == ["Antigravity", "Work", "Claude"], "the panel's plans follow → \(model.orderedPlans.map(\.agent))")
        check(model.aiReadings.first { $0.name == "Work" }?.badge == "2", "the account keeps its badge when moved")
        model.claudeAccounts = [ClaudeAccount(id: "work", name: "Acme", configDir: "/tmp/w")]
        model.plans[1] = PlanUsage(agent: "Acme", windows: [PlanWindow(label: "5h", left: 40, resets: nil)], at: Date())
        check(model.aiReadings.map(\.name) == ["Antigravity", "Acme", "Claude"], "renamed, it keeps its place → \(model.aiReadings.map(\.name))")
        model.claudeAccounts = []
        model.plans.remove(at: 1)
        check(model.aiReadings.map(\.name) == ["Antigravity", "Claude"], "removed, the rest keep theirs")
        model.aiOrder = []
        check(model.aiReadings.map(\.name) == ["Claude", "Antigravity"], "reset: the built-in order")

        // BY CLAUDE ACCOUNT: the same order, the main account as "Claude".
        let used = UsageSnapshot(totalTokens: 110, messages: 1)
        let team = ClaudeAccount(id: "team", name: "Team", configDir: "/tmp/t")
        let byAccount = { (order: [String]) in
            AppModel.byAccount(main: used, accounts: ["work": used, "team": used], listed: [work, team], order: order).map(\.name)
        }
        check(byAccount([]) == ["Claude", "Work", "Team"], "by account: main, then list order → \(byAccount([]))")
        check(byAccount(["Claude:team", "Antigravity", "Claude"]) == ["Team", "Claude", "Work"],
              "by account: the user's order → \(byAccount(["Claude:team", "Antigravity", "Claude"]))")

        // The 7-day chart: stacked in the same order, each key keeping its colour.
        let chartKeys = ["Codex", "Claude:team", "Claude", "Claude:work", "Codex"]
        let stack = ChartColors.stackOrder(chartKeys, accounts: [work, team])
        check(stack == ["Claude", "Claude:work", "Claude:team", "Codex"], "chart: Claude's accounts at the bottom, then the rest → \(stack)")
        let moved = ChartColors.stackOrder(chartKeys, accounts: [work, team], order: ["Codex", "Claude:team"])
        check(moved == ["Codex", "Claude:team", "Claude", "Claude:work"], "chart: the user's order → \(moved)")
        let shades = { (keys: [String]) in keys.map { ChartColors.color(forKey: $0, accounts: [work, team], dark: true) } }
        check(Set(shades(stack)).count == 4 && shades(moved) == shades(["Codex", "Claude:team", "Claude", "Claude:work"]),
              "chart: four colours, each tied to its key wherever it sits")
        return failures
    }
}
