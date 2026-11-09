import Foundation

/// Something Paceline can't read yet and how to fix it: an AI that's installed
/// but signed out, or a signed-in Claude folder that isn't in the list.
struct Suggestion: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case signIn(SignInCommand)              // Sign in… runs it in Terminal
        case openApp(bundleID: String)          // the app signs in itself
        case addAccount(dir: String, name: String)
        case links([Link])                      // nothing to run here: where to go instead
    }

    struct Link: Equatable, Sendable {
        let title: String
        let url: URL
    }

    let agent: String
    let title: String       // "Codex is not signed in"
    let detail: String
    let action: Action

    /// Also what "dismissed" remembers, so it's tied to this state.
    var id: String {
        switch action {
        case .signIn: "signin|\(agent)"
        case .openApp: "open|\(agent)"
        case .links: "links|\(agent)"
        case .addAccount(let dir, _): "add|\(dir)"
        }
    }
}

enum Suggestions {
    /// From the accounts' sign-in states and the Claude folders found
    /// unlisted. Not installed says nothing, and neither does a sign-in that's
    /// only unknown (agy's): that would never go away. Settings still offers its fix.
    static func make(accounts: [AccountInfo], found: [(dir: String, email: String)], listed: [ClaudeAccount] = []) -> [Suggestion] {
        var out: [Suggestion] = []
        // Each AI's fix for its state, from the table; an extra Claude account's is Claude's, in its folder.
        out += accounts.compactMap { account in
            if let extra = listed.first(where: { $0.name == account.agent }) {
                guard account.status == "Not signed in" else { return nil }
                return Suggestion(agent: extra.name, title: "\(extra.name) (Claude) is not signed in",
                                  detail: "Sign in opens Terminal and runs claude auth login with this account’s folder.",
                                  action: .signIn(.init("claude auth login", configDir: extra.configDir)))
            }
            guard AccountsLayout.group(account.status) == .needsSignIn else { return nil }
            return Providers.named(account.agent)?.fixSuggestion(for: account.status)
        }
        for (dir, email) in found {
            out.append(Suggestion(agent: "Claude", title: "Found another Claude account",
                                  detail: "\(ClaudeAccounts.tilde(dir)), signed in as \(email).",
                                  action: .addAccount(dir: dir, name: defaultName(for: dir))))
        }
        return out
    }

    /// What's left to show, and the dismissed ids worth keeping: a dismissal
    /// lasts while its suggestion does, so the same problem coming back later shows again.
    static func visible(_ suggestions: [Suggestion], dismissed: Set<String>) -> (shown: [Suggestion], dismissed: Set<String>) {
        let ids = Set(suggestions.map(\.id))
        return (suggestions.filter { !dismissed.contains($0.id) }, dismissed.intersection(ids))
    }

    /// ".claude-work" → "Work".
    static func defaultName(for dir: String) -> String {
        let last = (dir as NSString).lastPathComponent
        let rest = last.hasPrefix(".claude-") ? String(last.dropFirst(".claude-".count)) : last
        return rest.isEmpty ? "Claude" : rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// Folders right under home named ".claude-*" that are signed in and not
    /// listed. Reads only their .claude.json's oauthAccount (no tokens are in it).
    static func foundClaude(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            listed: [ClaudeAccount]) -> [(dir: String, email: String)] {
        if Demo.isOn { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.compactMap { url -> (dir: String, email: String)? in
            guard url.lastPathComponent.hasPrefix(".claude-"),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  ClaudeAccounts.account(forConfigDir: url.path, in: listed) == nil else { return nil }
            let info = AccountsReader.claude(url.appendingPathComponent(".claude.json"), agent: "")
            return info.status == "Not signed in" ? nil : (url.standardizedFileURL.path, info.status)
        }
        .sorted { $0.dir < $1.dir }
    }
}
