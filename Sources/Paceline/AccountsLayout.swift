import Foundation

/// Settings → Accounts without the UI: which group each AI is in, Claude's
/// added accounts under Claude, the one-line count on top, and each row's
/// short second line. Pure, so `--selftest` checks it.
enum AccountsLayout {
    enum Group: String, CaseIterable, Sendable {
        case ready = "Ready", needsSignIn = "Needs sign-in", notInstalled = "Not installed"
    }

    /// One line in the list; Claude's carries its added accounts.
    struct Row: Equatable, Identifiable, Sendable {
        let account: AccountInfo
        var extras: [AccountInfo] = []
        var id: String { account.id }
    }

    struct Section: Equatable, Identifiable, Sendable {
        let group: Group
        let rows: [Row]
        var id: String { group.rawValue }
        /// Accounts in it, added Claude accounts included.
        var count: Int { rows.reduce(0) { $0 + 1 + $1.extras.count } }
    }

    /// Signed in, or signs in with keys kept elsewhere ("Installed · VS Code", "Unknown · …"): ready.
    static func group(_ status: String) -> Group {
        switch status {
        case "Not installed": .notInstalled
        case "Not signed in", "Installed", "Unknown": .needsSignIn
        default: .ready
        }
    }

    /// The groups that have someone, in order. Within one, AIs with plan limits
    /// come first, then usage, then sign-in only, each in the table's order.
    /// Added Claude accounts (`extras`, by name) sit under Claude, which goes
    /// where the readiest of them does, so a signed-in one is never folded away.
    static func sections(_ accounts: [AccountInfo], extras: Set<String>) -> [Section] {
        let added = accounts.filter { extras.contains($0.agent) }
        var rows = accounts.filter { !extras.contains($0.agent) }.map { account in
            Row(account: account, extras: account.agent == "Claude" ? added : [])
        }
        if !added.isEmpty && !rows.contains(where: { $0.account.agent == "Claude" }) {
            rows.insert(Row(account: AccountInfo(agent: "Claude", status: "Not installed"), extras: added), at: 0)
        }
        let kinds = Provider.Group.allCases
        func kind(_ row: Row) -> Int { kinds.firstIndex(of: Providers.named(row.account.agent)?.group ?? .planLimits) ?? 0 }
        func place(_ row: Row) -> Group {
            let all = Group.allCases
            return ([row.account] + row.extras).map { group($0.status) }.min { all.firstIndex(of: $0)! < all.firstIndex(of: $1)! } ?? .ready
        }
        let sorted = rows.enumerated().sorted { (kind($0.element), $0.offset) < (kind($1.element), $1.offset) }.map(\.element)
        return Group.allCases.compactMap { group in
            let members = sorted.filter { place($0) == group }
            return members.isEmpty ? nil : Section(group: group, rows: members)
        }
    }

    /// Add Claude account… waits for Claude itself to be signed in.
    static func offersAddClaude(_ claude: AccountInfo) -> Bool { claude.isSignedIn }

    /// "4 ready · 1 needs sign-in · 9 not installed", each account once; groups with no one are left out.
    static func summary(_ accounts: [AccountInfo]) -> String {
        let counts = Dictionary(grouping: accounts) { group($0.status) }.mapValues(\.count)
        return Group.allCases.compactMap { group -> String? in
            guard let n = counts[group], n > 0 else { return nil }
            return switch group {
            case .ready: "\(n) ready"
            case .needsSignIn: n == 1 ? "1 needs sign-in" : "\(n) need sign-in"
            case .notInstalled: "\(n) not installed"
            }
        }.joined(separator: " · ")
    }

    /// The row's short second line: who it's signed in as, or where it lives.
    /// "Signed in · ChatGPT" → "ChatGPT"; an email → shortened; "Installed · VS Code" → "In VS Code".
    static func detail(_ account: AccountInfo) -> String? {
        let status = account.status
        switch group(status) {
        case .notInstalled: return nil
        case .needsSignIn: return status == "Unknown" ? "Sign-in not known" : "Not signed in"
        case .ready:
            if status.contains("@") { return shortEmail(status) }
            if status.hasPrefix("Installed · ") { return "In " + String(status.dropFirst("Installed · ".count)) }
            if status.hasPrefix("Signed in · ") { return String(status.dropFirst("Signed in · ".count)) }
            if status.hasPrefix("Unknown · ") { return "Sign-in not known" }
            return nil
        }
    }

    /// "someone.long@example.com" → "someone.l…@example.com": the name part cut to 9, the domain kept.
    static func shortEmail(_ email: String, keep: Int = 9) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let name = email[..<at]
        return name.count <= keep + 1 ? email : String(name.prefix(keep)) + "…" + String(email[at...])
    }
}
