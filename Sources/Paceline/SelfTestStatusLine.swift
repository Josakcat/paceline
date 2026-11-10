import Foundation

extension SelfTest {
    /// `--statusline`: the same text as before with the pace off, "runs out in …" only when it's on and due.
    static func statusLineTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  statusline: \(what)")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func session(five: Double?, fiveResetsIn: TimeInterval = 2 * 3600, week: Double? = 29) -> [String: Any] {
            var limits: [String: Any] = [:]
            if let five { limits["five_hour"] = ["used_percentage": five, "resets_at": now.timeIntervalSince1970 + fiveResetsIn] }
            if let week { limits["seven_day"] = ["used_percentage": week, "resets_at": now.timeIntervalSince1970 + 3 * 86400] }
            return ["model": ["display_name": "Opus 5.5"], "context_window": ["used_percentage": 40], "rate_limits": limits]
        }
        func text(_ json: [String: Any], pace: Bool) -> String { PlanUsageReader.statusLineText(json, pace: pace, now: now) }

        // 80% of the five hours in 3h: 20% left lasts 45m, 75m before the reset.
        let fast = session(five: 80)
        check(text(fast, pace: false) == "Opus 5.5 · ctx 40% · 5h 20% · Week 71% left", "pace off: as before → \(text(fast, pace: false))")
        check(text(fast, pace: true) == "Opus 5.5 · ctx 40% · 5h 20% · Week 71% left · 5h runs out in 45m", "pace on: the warning → \(text(fast, pace: true))")
        let calm = session(five: 38)
        check(text(calm, pace: true) == "Opus 5.5 · ctx 40% · 5h 62% · Week 71% left", "on pace: no warning → \(text(calm, pace: true))")
        // Too early in the round to tell: no call before 25% of it.
        check(!text(session(five: 20, fiveResetsIn: 4.5 * 3600), pace: true).contains("runs out"), "too early in the round: no warning")
        check(text([:], pace: true) == "Claude", "empty or broken stdin: just \"Claude\"")
        check(text(["rate_limits": "nope", "model": 3], pace: true) == "Claude", "wrong types: just \"Claude\"")
        check(text(session(five: nil, week: nil), pace: true) == "Opus 5.5 · ctx 40%", "no limits yet: model and context only")
        check(PlanUsageReader.paceWarning([:], now: now) == nil, "no windows: no warning")
        // Both running out: the sooner one.
        let both: [String: Any] = ["five_hour": ["used": 80, "resets_at": now.timeIntervalSince1970 + 2 * 3600],
                                   "seven_day": ["used": 90, "resets_at": now.timeIntervalSince1970 + 3 * 86400]]
        check(PlanUsageReader.paceWarning(both, now: now) == "5h runs out in 45m", "two running out: the sooner → \(PlanUsageReader.paceWarning(both, now: now) ?? "nil")")
        return failures
    }
}
