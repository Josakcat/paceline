import AppKit

// AIs whose usage stays on their servers: who's signed in (never a token),
// the plan where a non-secret row says it, and a link to their usage page.
// Not tried against real installs: none of them was on the Mac this was written on.

private let home = FileManager.default.homeDirectoryForCurrentUser

extension AccountsReader {
    /// Whether `key` is a row of a VS Code-style state.vscdb's ItemTable. Only
    /// the key column is selected, so a secret row's value is never read.
    static func hasRow(_ key: String, in state: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: state.path), let db = SQLiteFile(state, copy: false) else { return false }
        var found = false
        db.forEachRow("SELECT key FROM ItemTable WHERE key = '\(key)'") { _ in found = true }
        return found
    }

    /// One named row's value, for rows known to hold no secret.
    static func row(_ key: String, in state: URL) -> String? {
        guard FileManager.default.fileExists(atPath: state.path), let db = SQLiteFile(state, copy: false) else { return nil }
        var value: String?
        db.forEachRow("SELECT value FROM ItemTable WHERE key = '\(key)'") { value = $0.text(0) }
        return value
    }

    // MARK: - GitHub Copilot

    /// Extension folders of VS Code and its forks.
    static let editorExtensionDirs = [".vscode", ".vscode-insiders", ".vscode-oss", ".cursor", ".windsurf", ".devin", ".kiro"]
        .map { home.appendingPathComponent("\($0)/extensions") }

    /// Copilot signs in three ways, none of which Paceline reads a token from:
    /// - JetBrains, Neovim, Xcode…: ~/.config/github-copilot/apps.json (older:
    ///   hosts.json) holds the GitHub OAuth token. Only whether it's there is checked.
    /// - Copilot CLI: ~/.copilot/config.json (or $COPILOT_HOME) lists `loggedInUsers`;
    ///   only that top-level key's presence is checked (docs.github.com, "CLI config
    ///   dir reference", read 2026-11-08). The token is in the Keychain.
    /// - VS Code: its own GitHub sign-in, in the Keychain; the extension
    ///   (github.copilot, github.copilot-chat) only says it's installed.
    static func copilot(config: URL = home.appendingPathComponent(".config/github-copilot"),
                        cli: URL = ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".copilot"),
                        extensionDirs: [URL] = editorExtensionDirs) -> AccountInfo? {
        let name = "GitHub Copilot"
        let fm = FileManager.default
        func size(_ url: URL) -> Int { (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        if ["apps.json", "hosts.json"].contains(where: { size(config.appendingPathComponent($0)) > 2 }) {
            return AccountInfo(agent: name, status: "Signed in")
        }
        let cliConfig = cli.appendingPathComponent("config.json")
        if topLevelKeys(cliConfig).contains("loggedInUsers") { return AccountInfo(agent: name, status: "Signed in · Copilot CLI") }
        let inEditor = extensionDirs.contains { dir in
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.lowercased().hasPrefix("github.copilot") }
        }
        if inEditor { return AccountInfo(agent: name, status: "Unknown · signs in through the editor") }
        // Signed out with the CLI here: Sign in starts it. Only an editor plugin's folder: sign in there.
        if fm.fileExists(atPath: cli.path) || CommandFinder.find("copilot") != nil { return AccountInfo(agent: name, status: "Not signed in") }
        return fm.fileExists(atPath: config.path) ? AccountInfo(agent: name, status: "Unknown · sign in from your editor") : nil
    }

    // MARK: - Windsurf

    /// Windsurf is now Devin Desktop: the same bundle ID, but the app is Devin.app
    /// and its data moved to ~/Library/Application Support/Devin and ~/.devin (it
    /// copies Windsurf's over on first launch). Read from the official
    /// Devin-darwin-arm64-3.12.32.zip (devin.ai/download): Info.plist and product.json
    /// (nameShort "Devin", oldNameShort "Windsurf", dataFolderName ".devin"), 2026-11-09.
    static let windsurfBundleID = "com.exafunction.windsurf"
    static let windsurfStates = ["Windsurf", "Devin"].map {
        home.appendingPathComponent("Library/Application Support/\($0)/User/globalStorage/state.vscdb")
    }

    /// The name of the one that's here: the app's own name, or with no app, whose data is
    /// here. Devin Desktop, the one to download now, when neither is.
    static func windsurfName(appName: String?, hasWindsurfData: Bool, hasDevinData: Bool) -> String {
        if let appName { return appName.hasPrefix("Windsurf") ? "Windsurf" : "Devin Desktop" }
        return hasWindsurfData && !hasDevinData ? "Windsurf" : "Devin Desktop"
    }

    /// Read once at launch; Providers' row is named by it.
    static let windsurfName = windsurfName(
        appName: NSWorkspace.shared.urlForApplication(withBundleIdentifier: windsurfBundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String },
        hasWindsurfData: FileManager.default.fileExists(atPath: windsurfStates[0].path),
        hasDevinData: FileManager.default.fileExists(atPath: windsurfStates[1].path))
    static var windsurfState: URL { windsurfStates[windsurfName == "Windsurf" ? 0 : 1] }
    /// docs.devin.ai/desktop/accounts/usage (Windsurf is now part of Devin), read 2026-11-08.
    static let windsurfUsagePage = URL(string: "https://app.devin.ai/settings/usage")!

    /// Signed in: the `windsurfAuthStatus` row exists (its value holds the API
    /// key, so only the key column is selected; Devin Desktop 3.12 keeps the same
    /// key). Plan: `planName` from `windsurf.settings.cachedPlanInfo`, which has no
    /// secret in it (as read by steipete/CodexBar, WindsurfStatusProbe.swift, main,
    /// 2026-11). Devin Desktop's code no longer has that row, so it has no plan here.
    static func windsurf(state: URL = windsurfState, name: String = windsurfName, installed: Bool? = nil) -> AccountInfo? {
        guard installed ?? (installedApp(windsurfBundleID) || FileManager.default.fileExists(atPath: state.path)) else { return nil }
        guard hasRow("windsurfAuthStatus", in: state) else { return AccountInfo(agent: name, status: "Not signed in") }
        let plan = row("windsurf.settings.cachedPlanInfo", in: state)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["planName"] as? String
        return AccountInfo(agent: name, status: "Signed in", plan: plan?.nonEmpty)
    }

    // MARK: - Kiro

    static let kiroBundleID = "dev.kiro.desktop"
    static let kiroUsagePage = URL(string: "https://app.kiro.dev")!

    /// The IDE's sign-in is ~/.aws/sso/cache/kiro-auth-token.json, and
    /// kiro-cli's is the `kirocli:odic:token` key of its data.sqlite3 `auth_kv`
    /// table; both hold tokens, so only the file and the key's presence are
    /// checked. No non-secret plan or email was found to read.
    static func kiro(token: URL = home.appendingPathComponent(".aws/sso/cache/kiro-auth-token.json"),
                     cliStore: URL = home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3"),
                     installed: Bool? = nil) -> AccountInfo? {
        let fm = FileManager.default
        guard installed ?? (installedApp(kiroBundleID) || fm.fileExists(atPath: home.appendingPathComponent(".kiro").path)
                            || fm.fileExists(atPath: cliStore.path) || CommandFinder.find("kiro-cli") != nil) else { return nil }
        if fm.fileExists(atPath: token.path) { return AccountInfo(agent: "Kiro", status: "Signed in") }
        var cli = false
        if fm.fileExists(atPath: cliStore.path), let db = SQLiteFile(cliStore, copy: false) {
            db.forEachRow("SELECT key FROM auth_kv WHERE key = 'kirocli:odic:token'") { _ in cli = true }
        }
        return AccountInfo(agent: "Kiro", status: cli ? "Signed in · kiro-cli" : "Not signed in")
    }
}

extension PlanUsageReader {
    /// Windsurf's own copy of its plan: `quotaUsage` in `windsurf.settings.cachedPlanInfo`
    /// (`dailyRemainingPercent`, `weeklyRemainingPercent`, `dailyResetAtUnix`,
    /// `weeklyResetAtUnix`), as read by steipete/CodexBar (WindsurfStatusProbe.swift).
    /// Devin Desktop 3.12 caches it elsewhere (`windsurf.reactSettings.cachedPlanInfoData:<user>`,
    /// shape unread), so it gets no % here. The percentages are taken as 0–100. When it was cached isn't recorded, so
    /// the database's last change stands in for it.
    static func windsurf(state: URL = AccountsReader.windsurfState, name: String = AccountsReader.windsurfName, now: Date = Date()) -> PlanUsage? {
        guard let text = AccountsReader.row("windsurf.settings.cachedPlanInfo", in: state),
              let info = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let quota = info["quotaUsage"] as? [String: Any] else { return nil }
        let windows: [PlanWindow] = [("daily", "Day"), ("weekly", "Week")].compactMap { key, label in
            guard let left = (quota["\(key)RemainingPercent"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (quota["\(key)ResetAtUnix"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return window(label, left: Int(percent: left), resets: resets, now: now)
        }
        let changed = [state, URL(fileURLWithPath: state.path + "-wal")].compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? now
        return usage(name, group: nil, windows: windows, at: min(changed, now), now: now)
    }
}
