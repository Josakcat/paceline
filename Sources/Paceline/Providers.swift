import Foundation

/// Every AI Paceline knows, in one table: what it can show, how it's drawn,
/// how to read its sign-in and usage, and what to suggest when it's signed out.
/// A new AI is a row here (plus its reader), not changes all over the app.
///
/// Claude (and its extra accounts) is listed too, but its usage and plan
/// limits come from TokenMonitor and PlanUsage, so it has no `source`.
struct Provider: Sendable {
    enum Capability: String, CaseIterable, Sendable {
        case planPercent = "Plan % left", tokens = "Tokens", cost = "$", signIn = "Sign-in", usageLink = "Usage link"
    }

    /// Settings → Accounts groups AIs by what they can show.
    enum Group: String, CaseIterable, Sendable {
        case planLimits = "Plan limits", usage = "Usage", signInOnly = "Sign-in only"
    }

    /// What to suggest for a sign-in state ("Not signed in", "Installed").
    struct Fix: Sendable {
        var title: String? = nil   // default "<name> is not signed in"
        let detail: String
        let action: Suggestion.Action
    }

    let name: String
    /// Menu bar label and letter badge: two letters, three at most.
    let short: String
    let group: Group
    let capabilities: Set<Capability>
    /// The app whose icon is its logo, and that "Open …" opens. nil: a letter badge.
    var bundleID: String? = nil
    /// Its own usage page, for AIs whose numbers stay on their servers.
    var usagePage: URL? = nil
    /// The 7-day chart's colour.
    var color: UInt32 = 0x8E8E93
    var fixes: [String: Fix] = [:]
    /// Its sign-in, or nil when it isn't installed. Slow readers run off the main thread.
    var account: (@Sendable () -> AccountInfo?)? = nil
    var source: (any UsageSource)? = nil
    /// How to install it, when it isn't (Install.swift).
    var install: Install? = nil

    func fixSuggestion(for status: String) -> Suggestion? {
        fixes[status].map { Suggestion(agent: name, title: $0.title ?? "\(name) is not signed in", detail: $0.detail, action: $0.action) }
    }

    /// "cursor.com", for "Usage is on cursor.com".
    var usageHost: String? { usagePage?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } }
}

/// Install… sources: each maker's own page, checked on 2026-11-09. Only their
/// own installers and pages; no mirrors, no third-party taps or packages.
/// - Claude: code.claude.com/docs/en/setup (native installer); app: claude.com/download.
/// - Codex: learn.chatgpt.com/docs/codex/cli and github.com/openai/codex README; app: developers.openai.com/codex/app.
/// - Antigravity: antigravity.google/download (app, and the agy CLI's installer).
/// - OpenCode: opencode.ai/docs. Amp: ampcode.com/docs/cli.
/// - Copilot CLI: docs.github.com …/install-copilot-cli (gh.io/copilot-install is GitHub's own link to its script).
/// - Gemini CLI: github.com/google-gemini/gemini-cli README (personal access moved to Antigravity, 2026-06-18).
/// - Cline: docs.cline.bot (extension saoudrizwan.claude-dev). Kilo Code: kilo.ai/install (kilocode.Kilo-Code).
/// - Roo Code: none. Its Marketplace listing is gone and github.com/RooCodeInc/Roo-Code is archived
///   (last release 2026-05-15), so it's listed only where it's installed.
/// - Cursor: cursor.com/download. Kiro: kiro.dev/downloads. Windsurf / Devin Desktop: devin.ai/download
///   (windsurf.com/download redirects there).
/// - Gemini CLI's Homebrew formula: gemini-cli in homebrew/core (formulae.brew.sh), and in its README.
enum Providers {
    static let all: [Provider] = [
        Provider(name: "Claude", short: "CC", group: .planLimits, capabilities: [.planPercent, .tokens, .cost, .signIn],
                 bundleID: "com.anthropic.claudefordesktop", color: 0xD97757,
                 fixes: ["Not signed in": .init(title: "Claude Code is not signed in", detail: "Sign in opens Terminal and runs claude auth login.",
                                                action: .signIn(.init("claude auth login")))],
                 install: .init(command: "curl -fsSL https://claude.ai/install.sh | bash", page: URL(string: "https://claude.com/download")!,
                                pageTitle: "Claude app")),
        Provider(name: "Codex", short: "CX", group: .planLimits, capabilities: [.planPercent, .tokens, .cost, .signIn],
                 bundleID: "com.openai.codex", color: 0x0A98AE,
                 fixes: ["Not signed in": .init(detail: "Sign in opens Terminal and runs codex login.", action: .signIn(.init("codex login"))),
                         "Installed": .init(title: "Codex: sign in to see its usage", detail: "Open the Codex app and sign in on its first screen.",
                                            action: .openApp(bundleID: "com.openai.codex"))],
                 account: { AccountsReader.codex() }, source: CodexSource(),
                 install: .init(command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
                                page: URL(string: "https://developers.openai.com/codex/app")!, pageTitle: "Codex app")),
        Provider(name: "Antigravity", short: "AG", group: .planLimits, capabilities: [.planPercent, .tokens, .cost, .signIn],
                 bundleID: "com.google.antigravity", color: 0x4F8DF7,
                 fixes: ["Installed": .init(detail: "Open Antigravity and sign in with Google on its first screen.",
                                            action: .openApp(bundleID: "com.google.antigravity")),
                         "Unknown · agy": .init(title: "Antigravity: agy’s sign-in is unknown",
                                                detail: "Paceline can’t tell whether agy is signed in. Sign in opens Terminal and starts agy, which asks if it needs to.",
                                                action: .signIn(.init("agy", then: "Sign in when agy asks.")))],
                 account: { AccountsReader.antigravity() }, source: AntigravitySource(),
                 install: .init(command: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
                                page: URL(string: "https://antigravity.google/download")!, pageTitle: "Antigravity app")),
        Provider(name: "OpenCode", short: "OC", group: .usage, capabilities: [.tokens, .cost, .signIn], color: 0xA78BFA,
                 fixes: ["Not signed in": .init(title: "OpenCode has no saved sign-in",
                                                detail: "Sign in opens Terminal and runs opencode auth login (skip this if you use API keys from your shell).",
                                                action: .signIn(.init("opencode auth login")))],
                 account: { AccountsReader.openCode() }, source: OpenCodeSource(),
                 install: .init(command: "curl -fsSL https://opencode.ai/v2/install | bash", page: URL(string: "https://opencode.ai/docs/")!,
                                pageTitle: "OpenCode docs")),
    ] + VSCodeAgents.providers + [
        Provider(name: "Gemini CLI", short: "GE", group: .usage, capabilities: [.tokens, .cost, .signIn], color: 0x34A8EB,
                 fixes: ["Not signed in": .init(detail: "Personal Google sign-in ended — use a GEMINI_API_KEY or Antigravity.",
                                                action: .links([.init(title: "Get an API key", url: URL(string: "https://aistudio.google.com/apikey")!),
                                                                .init(title: "Antigravity", url: URL(string: "https://antigravity.google")!)]))],
                 account: { AccountsReader.geminiCLI() }, source: GeminiCLISource(),
                 install: .init(command: "npm install -g @google/gemini-cli", brew: "brew install gemini-cli",
                                page: URL(string: "https://github.com/google-gemini/gemini-cli")!, pageTitle: "Gemini CLI on GitHub",
                                note: "Personal Google sign-in ended — use a GEMINI_API_KEY or Antigravity.")),
        Provider(name: "Amp", short: "AM", group: .usage, capabilities: [.tokens, .cost, .signIn, .usageLink],
                 usagePage: URL(string: "https://ampcode.com/settings"), color: 0xF472B6,
                 fixes: ["Not signed in": .init(detail: "Sign in opens Terminal and runs amp login.", action: .signIn(.init("amp login")))],
                 account: { AccountsReader.amp() }, source: AmpSource(),
                 install: .init(command: "curl -fsSL https://ampcode.com/install.sh | bash", page: URL(string: "https://ampcode.com/docs/cli")!,
                                pageTitle: "Amp docs")),
        Provider(name: "Cursor", short: "Cu", group: .signInOnly, capabilities: [.signIn, .usageLink],
                 bundleID: AccountsReader.cursorBundleID, usagePage: AccountsReader.cursorUsagePage,
                 fixes: ["Not signed in": .init(detail: "Open Cursor and sign in on its first screen or in Cursor Settings.",
                                                action: .openApp(bundleID: AccountsReader.cursorBundleID))],
                 account: { AccountsReader.cursor() }, install: .init(page: URL(string: "https://cursor.com/download")!)),
        Provider(name: "GitHub Copilot", short: "CP", group: .signInOnly, capabilities: [.signIn, .usageLink],
                 usagePage: URL(string: "https://github.com/settings/copilot"),
                 fixes: ["Not signed in": .init(detail: "Sign in opens Terminal and starts copilot; type /login there.",
                                                action: .signIn(.init("copilot", then: "Type /login, then follow the steps.")))],
                 account: { AccountsReader.copilot() },
                 install: .init(command: "curl -fsSL https://gh.io/copilot-install | bash",
                                page: URL(string: "https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli")!,
                                pageTitle: "GitHub docs")),
        // Windsurf, or Devin Desktop (its new name) when that's the one here.
        Provider(name: AccountsReader.windsurfName, short: AccountsReader.windsurfName == "Windsurf" ? "WS" : "DV", group: .planLimits,
                 capabilities: [.planPercent, .signIn, .usageLink],
                 bundleID: AccountsReader.windsurfBundleID, usagePage: AccountsReader.windsurfUsagePage,
                 fixes: ["Not signed in": .init(detail: "Open \(AccountsReader.windsurfName) and sign in on its first screen.",
                                                action: .openApp(bundleID: AccountsReader.windsurfBundleID))],
                 account: { AccountsReader.windsurf() },
                 install: .init(page: URL(string: "https://devin.ai/download")!, note: "Windsurf is now Devin Desktop.")),
        Provider(name: "Kiro", short: "KI", group: .signInOnly, capabilities: [.signIn, .usageLink],
                 bundleID: AccountsReader.kiroBundleID, usagePage: AccountsReader.kiroUsagePage,
                 fixes: ["Not signed in": .init(detail: "Open Kiro and sign in on its first screen.",
                                                action: .openApp(bundleID: AccountsReader.kiroBundleID))],
                 account: { AccountsReader.kiro() }, install: .init(page: URL(string: "https://kiro.dev/downloads/")!)),
    ]

    static func named(_ name: String) -> Provider? { all.first { $0.name == name } }

    static var sources: [any UsageSource] { all.compactMap(\.source) }

    /// The chart's colours, in table order.
    static var chartColors: (names: [String], colors: [UInt32]) { (all.map(\.name), all.map(\.color)) }
}
