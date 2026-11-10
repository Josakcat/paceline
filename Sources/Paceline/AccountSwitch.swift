import Foundation

/// With more than one Claude account: when one runs low and another clearly
/// has more, which to switch to. Pure, so it can be tested.
enum AccountSwitch {
    struct Hint: Equatable, Sendable {
        let from: String        // the low account's name ("Claude" is the main one)
        let window: String      // the window that's low: "5h" or "Week"
        let fromLeft: Int
        let to: String
        let toLeft: Int         // the lower of its windows
        let command: String     // opens Claude Code with that account
        let id: String          // "<from>|<window>|<reset, epoch seconds>": dismissing lasts this round

        /// "Work has 80% left — switch to it for now"
        var text: String { "\(to) has \(toLeft)% left — switch to it for now" }
        /// "Claude: 12% of the 5-hour limit left"
        var why: String { "\(from): \(fromLeft)% of the \(PlanWindow.spokenName(window)) limit left" }
    }

    /// Low: 20% or less, or on course to run out before the reset.
    static let lowAt = 20
    /// "Clearly more": the other account's lower window at least this many points
    /// above the low one, and not under `enough` itself.
    static let margin = 30
    static let enough = 40

    /// The hint, if any. Only fresh Claude plans count, main and listed accounts.
    /// `from`: only a hint for that account (a plan alert's).
    static func hint(_ plans: [PlanUsage], accounts: [ClaudeAccount], now: Date = Date(), from: String? = nil,
                     home: String = NSHomeDirectory()) -> Hint? {
        let names = ["Claude"] + accounts.map(\.name)
        let fresh = names.compactMap { name in
            plans.first { $0.agent == name && $0.group == nil && !$0.isStale(now: now) && !$0.windows.isEmpty }
        }
        guard fresh.count >= 2 else { return nil }
        func headroom(_ plan: PlanUsage) -> Int { plan.windows.filter { !$0.isModelScoped }.map(\.left).min() ?? 0 }
        /// The window that makes a plan low, the emptiest first.
        func lowWindow(_ plan: PlanUsage) -> PlanWindow? {
            plan.windows.filter { w in
                guard !w.isModelScoped, !w.wasReset, w.resets.map({ $0 > now }) ?? true else { return false }
                if w.left <= lowAt { return true }
                if case .runsOut? = plan.pace(w, now: now) { return true }
                return false
            }.min { $0.left < $1.left }
        }
        let low = fresh.compactMap { plan in lowWindow(plan).map { (plan, $0) } }
            .filter { from == nil || $0.0.agent == from }
            .min { $0.1.left < $1.1.left }
        guard let (plan, window) = low else { return nil }
        let floor = max(window.left + margin, enough)
        let target = fresh.filter { $0.agent != plan.agent && lowWindow($0) == nil && headroom($0) >= floor }
            .max { headroom($0) < headroom($1) }
        guard let target else { return nil }
        let command = accounts.first { $0.name == target.agent }
            .map { "CLAUDE_CONFIG_DIR=\(ClaudeAccounts.shellPath($0.configDir, home: home)) claude" } ?? "claude"
        let reset = window.resets.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return Hint(from: plan.agent, window: window.label, fromLeft: window.left, to: target.agent, toLeft: headroom(target),
                    command: command, id: "\(plan.agent)|\(window.label)|\(reset)")
    }
}
