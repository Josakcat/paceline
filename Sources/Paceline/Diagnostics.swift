import Foundation

/// Report a Problem…: what Paceline would put in a bug report, shown before it's
/// copied. Only the table's AI names, fixed words for status and sources, and
/// counts: no email, account name, project, path or token. `report` is pure,
/// and `scrub` runs over it last in case anything slipped in. `--selftest` checks it.
enum Diagnostics {
    static let issueURL = URL(string: "https://github.com/Josakcat/paceline/issues/new?template=bug.yml")!

    struct AI: Equatable, Sendable {
        let name: String
        let status: String
        let found: [String]
    }

    struct Info: Sendable {
        var version: String
        var macOS: String
        var arch: String
        var homebrew: Bool
        var ais: [AI]
        var addedClaudeAccounts: Int
        var settings: [String]
    }

    /// A sign-in state in fixed words; an email or "Signed in · …" is just Ready.
    static func status(_ account: AccountInfo) -> String {
        if account.status.hasPrefix("Unknown") { return "Can't read" }
        return AccountsLayout.group(account.status).rawValue
    }

    /// One AI's line from what the model has. Added Claude accounts and anything
    /// not in the table are left out (their names are the user's own).
    static func ais(accounts: [AccountInfo], plans: [String], tokens: [String: UsageAccuracy], claudeTranscripts: Bool) -> [AI] {
        accounts.compactMap { account in
            guard let provider = Providers.named(account.agent) else { return nil }
            let name = provider.name
            var found: [String] = []
            if plans.contains(name) { found.append("plan %") }
            if name == "Claude" ? claudeTranscripts : tokens[name] != nil {
                found.append("tokens (\(name == "Claude" ? UsageAccuracy.exact.rawValue : tokens[name]!.rawValue))")
            }
            if status(account) == AccountsLayout.Group.ready.rawValue { found.append("sign-in") }
            return AI(name: name, status: status(account), found: found)
        }
    }

    static func report(_ info: Info) -> String {
        var lines = [
            "Paceline \(info.version) · from Homebrew: \(info.homebrew ? "yes" : "no")",
            "macOS \(info.macOS) · \(info.arch)",
        ]
        if info.addedClaudeAccounts > 0 { lines.append("Added Claude accounts: \(info.addedClaudeAccounts)") }
        if !info.settings.isEmpty { lines.append("Settings: " + info.settings.joined(separator: " · ")) }
        lines.append("")
        let nameWidth = max(4, info.ais.map(\.name.count).max() ?? 0) + 2
        let statusWidth = max(6, info.ais.map(\.status.count).max() ?? 0) + 2
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }
        lines.append(pad("AI", nameWidth) + pad("Status", statusWidth) + "Found")
        for ai in info.ais {
            lines.append(pad(ai.name, nameWidth) + pad(ai.status, statusWidth) + (ai.found.isEmpty ? "—" : ai.found.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    /// The last guard: home and any other home folder's paths become ~, a word with @ is
    /// hidden, and so is each of `names` (the user's account names) as a whole word.
    static func scrub(_ text: String, home: String, names: [String]) -> String {
        var out = text
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        // Anyone's home next to it (the folder of homes, never spelled out here).
        let homes = (home as NSString).deletingLastPathComponent
        if homes.count > 1 {
            out = out.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: homes) + #"/[^/\s]+"#, with: "~", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\S*@\S*"#, with: "(hidden)", options: .regularExpression)
        for name in names.map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty && Providers.named(name) == nil {
            out = out.replacingOccurrences(of: #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: name) + #"(?!\w)"#,
                                           with: "(account)", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    // MARK: - This Mac

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The report for this Mac. `accounts` comes from `AccountsReader.all()` (slow, off the main thread).
    @MainActor
    static func current(model: AppModel, accounts: [AccountInfo]) -> String {
        let info = Info(
            version: Updates.current, macOS: macOS, arch: arch, homebrew: Updates.thisInstall() == .homebrew,
            ais: ais(accounts: accounts, plans: model.plans.map(\.agent),
                     tokens: Dictionary(model.otherUsage.map { ($0.source, $0.accuracy) }, uniquingKeysWith: { a, _ in a }),
                     claudeTranscripts: model.claudeLastActive != nil),
            addedClaudeAccounts: model.claudeAccounts.count,
            settings: ["fetch when stale " + (model.fetchFresh ? "on" : "off"), "alerts " + (model.notify ? "on" : "off"),
                       "menu bar \(model.menuBarStyle.label.lowercased())"])
        return scrub(report(info), home: NSHomeDirectory(), names: model.claudeAccounts.map(\.name))
    }
}
