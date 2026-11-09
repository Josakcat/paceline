import AppKit

/// Who an AI is signed in as, for Settings → Accounts.
struct AccountInfo: Equatable, Identifiable, Sendable {
    let agent: String
    let status: String      // email, or "Not signed in" / "Installed" / "Not installed"
    var plan: String?

    var id: String { agent }

    /// Signed in, or signs in with keys kept elsewhere ("Installed · VS Code").
    var isSignedIn: Bool {
        !["Not installed", "Not signed in", "Installed", "Unknown"].contains(status) && !status.hasPrefix("Unknown")
    }
}

/// Sign-in state from files on this Mac, never tokens:
/// - Claude: `oauthAccount` in ~/.claude.json; an extra account's in <its folder>/.claude.json.
/// - Codex: the line `codex login status` prints (auth.json is never opened).
/// - Antigravity: the `userStatus` row of the IDE's state.vscdb (email and plan
///   name only; the `oauthToken` row next to it is never selected).
enum AccountsReader {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Slow (reads ~/.claude.json, runs codex): call off the main thread.
    static func all() -> [AccountInfo] {
        if Demo.isNewUser {
            // Added accounts are made-up folders; their own .claude.json is read.
            return Demo.newUserSignIns.prefix(1) + ClaudeAccounts.load().map { claude($0.configURL.appendingPathComponent(".claude.json"), agent: $0.name) }
                + Demo.newUserSignIns.dropFirst()
        }
        if Demo.isOn { return Demo.signIns }
        var main = claude(home.appendingPathComponent(".claude.json"), agent: "Claude")
        if main.status == "Not signed in" && !claudeInstalled { main = AccountInfo(agent: "Claude", status: "Not installed") }
        var accounts = [main]
        accounts += ClaudeAccounts.load().map { claude($0.configURL.appendingPathComponent(".claude.json"), agent: $0.name) }
        // The rest, from the table.
        return accounts + Providers.all.compactMap { provider in provider.account.flatMap { listed(provider, $0()) } }
    }

    /// A reader's nil is "Not installed", unless there's no way to install it any
    /// more (Roo Code): then it's listed only where it's installed.
    static func listed(_ provider: Provider, _ read: AccountInfo?) -> AccountInfo? {
        read ?? (provider.install == nil ? nil : AccountInfo(agent: provider.name, status: "Not installed"))
    }

    // MARK: - Claude

    /// Claude Code is here: its folder, or the CLI where its installers put it.
    static var claudeInstalled: Bool {
        ([".claude", ".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]).contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func claude(_ file: URL, agent: String) -> AccountInfo {
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AccountInfo(agent: agent, status: "Not signed in")
        }
        return claude(json, agent: agent)
    }

    static func claude(_ json: [String: Any], agent: String) -> AccountInfo {
        guard let oauth = json["oauthAccount"] as? [String: Any], let email = oauth["emailAddress"] as? String, !email.isEmpty else {
            return AccountInfo(agent: agent, status: "Not signed in")
        }
        // A personal account's organisation is just "<email>'s Organization".
        let org = (oauth["organizationName"] as? String).flatMap { $0.hasSuffix("’s Organization") || $0.hasSuffix("'s Organization") ? nil : $0.nonEmpty }
        return AccountInfo(agent: agent, status: email, plan: [claudePlan(oauth), org].compactMap { $0 }.joined(separator: " · ").nonEmpty)
    }

    /// "Max 5x", "Pro", "Team"… from organizationType, the rate limit tier and seatTier.
    static func claudePlan(_ oauth: [String: Any]) -> String? {
        func string(_ key: String) -> String? { (oauth[key] as? String)?.nonEmpty }
        let tier = string("organizationRateLimitTier") ?? string("userRateLimitTier") ?? ""
        let multiple = tier.range(of: #"\d+x$"#, options: .regularExpression).map { " " + tier[$0] } ?? ""
        let plan: String? = switch string("organizationType") {
        case "claude_max": "Max" + multiple
        case "claude_pro": "Pro"
        case "claude_team": "Team"
        case "claude_enterprise": "Enterprise"
        case let other?: other.replacingOccurrences(of: "claude_", with: "").capitalized
        case nil: nil
        }
        let seat = string("seatTier").map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return [plan, seat].compactMap { $0 }.joined(separator: " · ").nonEmpty
            ?? (string("billingType") == "stripe_subscription" ? "Subscription" : nil)
    }

    // MARK: - Codex

    static func codex() -> AccountInfo {
        guard let binary = codexBinary() else {
            return AccountInfo(agent: "Codex", status: installed("com.openai.codex") ? "Installed" : "Not installed")
        }
        let output = run(binary, ["login", "status"]) ?? ""
        let line = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let status = line.map(codexStatus) ?? "Unknown"
        let plan = status.hasPrefix("Signed in") && !status.contains("API key") ? PlanUsageReader.codex()?.planName : nil
        return AccountInfo(agent: "Codex", status: status, plan: plan)
    }

    /// Codex's words in ours: "Logged in using ChatGPT" → "Signed in · ChatGPT",
    /// "Not logged in" → "Not signed in". Anything after " - " (a key) is dropped.
    static func codexStatus(_ line: String) -> String {
        let head = line.components(separatedBy: " - ").first ?? line
        if head.lowercased().hasPrefix("not logged in") { return "Not signed in" }
        if head.hasPrefix("Logged in using ") {
            let how = head.dropFirst("Logged in using ".count)
            return "Signed in · " + (how.localizedCaseInsensitiveContains("api key") ? "API key" : String(how.prefix(40)))
        }
        if head.hasPrefix("Logged in") || head.contains("sk-") { return "Signed in" }
        return String(head.prefix(60))
    }

    private static func codexBinary() -> String? {
        let fixed = [".local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map {
            $0.hasPrefix("/") ? $0 : home.appendingPathComponent($0).path
        }
        if let path = fixed.first(where: FileManager.default.isExecutableFile) { return path }
        return loginShellPath("codex")
    }

    /// Whatever the login shell's PATH finds for `tool` (a name from Paceline's own table).
    static func loginShellPath(_ tool: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let found = run(shell, ["-lc", "command -v " + ClaudeAccounts.shellQuote(tool)])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: found) ? found : nil
    }

    /// Whether the user's shell sets `variable` (to anything). Only "set" or
    /// nothing comes back: the value is never printed.
    static func loginShellHas(_ variable: String) -> Bool {
        if ProcessInfo.processInfo.environment[variable]?.isEmpty == false { return true }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let test = "[ -n \"${\(variable)-}\" ] && echo PACELINE_SET"
        return run(shell, ["-lic", test])?.contains("PACELINE_SET") == true
    }

    /// One AI's sign-in now, for the watch after Sign in is pressed.
    static func one(_ agent: String, listed: [ClaudeAccount]) -> AccountInfo? {
        if agent == "Claude" {
            let main = claude(home.appendingPathComponent(".claude.json"), agent: agent)
            return main.status == "Not signed in" && !claudeInstalled ? AccountInfo(agent: agent, status: "Not installed") : main
        }
        if let extra = listed.first(where: { $0.name == agent }) {
            return claude(extra.configURL.appendingPathComponent(".claude.json"), agent: agent)
        }
        return Providers.named(agent)?.account?()
    }

    /// stdout and stderr, or nil if it didn't finish within 10 seconds.
    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let (data, timedOut) = PipeReader.read(pipe.fileHandleForReading, until: Date().addingTimeInterval(10))
        if timedOut {
            ProcessDeadline.end(process)
            return nil
        }
        process.waitUntilExit()
        return process.terminationReason == .exit ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: - Antigravity

    static let antigravityStates = ["Antigravity IDE", "Antigravity"].map {
        home.appendingPathComponent("Library/Application Support/\($0)/User/globalStorage/state.vscdb")
    }

    static func antigravity() -> AccountInfo {
        for file in antigravityStates where FileManager.default.fileExists(atPath: file.path) {
            guard let db = SQLiteFile(file, copy: false) else { continue }
            var status: String?
            db.forEachRow("SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.userStatus'") { status = $0.text(0) }
            if let status, let account = antigravity(userStatus: status) { return account }
        }
        if installed("com.google.antigravity") { return AccountInfo(agent: "Antigravity", status: "Installed") }
        guard FreshLimits.agyCommand != nil else { return AccountInfo(agent: "Antigravity", status: "Not installed") }
        return agy()
    }

    /// agy without the app. Its sign-in looks to be ~/.gemini/jetski-standalone-oauth-token
    /// ("jetski" is the name in agy's own files); only whether it's there is checked. That
    /// isn't sure enough to say it's signed out, so without it: Unknown (Sign in… still offered).
    static func agy(token: URL = home.appendingPathComponent(".gemini/jetski-standalone-oauth-token")) -> AccountInfo {
        AccountInfo(agent: "Antigravity", status: FileManager.default.fileExists(atPath: token.path) ? "Signed in · agy" : "Unknown · agy")
    }

    /// base64 → field 1.2.1 (base64 again) → email at 7, plan name at 36.2.
    static func antigravity(userStatus: String) -> AccountInfo? {
        guard let outer = Data(base64Encoded: userStatus.trimmingCharacters(in: .whitespacesAndNewlines)),
              let wrapped = Proto.bytes(outer, path: [1, 2, 1]),
              let inner = Data(base64Encoded: String(decoding: wrapped, as: UTF8.self)),
              let email = Proto.bytes(inner, path: [7]).map({ String(decoding: $0, as: UTF8.self) }), email.contains("@") else { return nil }
        let plan = Proto.bytes(inner, path: [36, 2]).map { String(decoding: $0, as: UTF8.self) }
        return AccountInfo(agent: "Antigravity", status: email, plan: plan?.nonEmpty)
    }

    static func installedApp(_ bundleID: String) -> Bool { installed(bundleID) }

    private static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
