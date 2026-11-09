import Foundation

extension SelfTest {
    /// Windsurf or Devin Desktop, Roo Code only where installed, Gemini CLI's npm or brew,
    /// Open <editor>, Add Claude account after Claude, and agy's unknown sign-in.
    static func followupTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  followups: \(what)")
        }

        // Windsurf / Devin Desktop: the app's own name decides; without it, whose data is here.
        let name = AccountsReader.windsurfName(appName:hasWindsurfData:hasDevinData:)
        check(name("Devin", true, true) == "Devin Desktop"
              && name("Windsurf", true, false) == "Windsurf"
              && name("Windsurf - Next", false, true) == "Windsurf",
              "the app here names it: Devin → Devin Desktop, Windsurf → Windsurf")
        check(name(nil, true, false) == "Windsurf" && name(nil, true, true) == "Devin Desktop" && name(nil, false, false) == "Devin Desktop",
              "no app: Windsurf's data alone → Windsurf; else Devin Desktop, the one to get now")
        let row = Providers.named(AccountsReader.windsurfName)
        check(row?.bundleID == "com.exafunction.windsurf" && row?.install?.page.absoluteString == "https://devin.ai/download"
              && AccountsReader.windsurfStates.map(\.path).allSatisfy { $0.hasSuffix("/User/globalStorage/state.vscdb") }
              && AccountsReader.windsurfStates.map { $0.pathComponents.dropLast(3).last } == ["Windsurf", "Devin"],
              "one row for both: the shared bundle ID, both data folders, devin.ai/download")

        // Roo Code: ended, so it has no Install… and isn't listed as not installed.
        let roo = Providers.named("Roo Code")
        check(roo != nil && roo?.install == nil && AccountsReader.listed(roo!, nil) == nil
              && AccountsReader.listed(roo!, AccountInfo(agent: "Roo Code", status: "Installed · VS Code"))?.status == "Installed · VS Code",
              "Roo Code: listed where installed, never under Not installed")
        check(Providers.named("Kilo Code").map { AccountsReader.listed($0, nil)?.status == "Not installed" } == true,
              "Kilo Code still shows as not installed, with its Install…")

        // Gemini CLI: npm when it's here, else brew, else both are missing.
        let gemini = Providers.named("Gemini CLI")!.install!
        func pick(_ tools: Set<String>) -> (String?, [String]) {
            let choice = gemini.choice { tools.contains($0) }
            return (choice.command, choice.missing.map(\.tool))
        }
        check(pick(["npm", "brew"]) == ("npm install -g @google/gemini-cli", []) && pick(["npm"]) == ("npm install -g @google/gemini-cli", []),
              "Gemini CLI: npm when there's npm")
        check(pick(["brew"]) == ("brew install gemini-cli", []), "Gemini CLI: brew install gemini-cli when there's brew but no npm")
        check(pick([]) == ("npm install -g @google/gemini-cli", ["npm", "brew"]), "Gemini CLI: neither → get Node.js or Homebrew first")
        let amp = Providers.named("Amp")!.install!
        check(amp.choice { _ in false }.missing.isEmpty, "a curl installer needs neither")

        // Open <editor>: the first place in the row whose app is here.
        let here: Set<String> = [AccountsReader.cursorBundleID, AccountsReader.windsurfBundleID]
        let open = { (status: String, app: String) in VSCodeAgents.openEditor(status, appName: app, isInstalled: here.contains)?.name }
        check(open("Installed · VS Code, Cursor", "Windsurf") == "Cursor", "VS Code isn't here → Open Cursor")
        check(open("Installed · Devin Desktop", "Devin Desktop") == "Devin Desktop" && open("Installed · Windsurf, Cline CLI", "Devin Desktop") == "Devin Desktop",
              "Windsurf's or Devin's folder → whichever of the two app is here")
        check(open("Installed · Cline CLI", "Windsurf") == nil && open("Installed · VSCodium", "Windsurf") == nil && open("Signed in", "Windsurf") == nil,
              "no editor app here, or not an extension's row → no Open button")
        let insiders = { (status: String) in VSCodeAgents.openEditor(status, isInstalled: { _ in true }).map { "\($0.name) \($0.bundleID)" } }
        check(insiders("Installed · Code - Insiders") == nil && insiders("Installed · VSCodium") == "VSCodium com.vscodium",
              "Code - Insiders has no checked bundle ID → no Open; VSCodium opens com.vscodium")
        check(VSCodeAgents.signInHint("Cline").contains("Cline panel"), "says where to sign in")

        // Add Claude account… only once Claude is signed in.
        check(!AccountsLayout.offersAddClaude(AccountInfo(agent: "Claude", status: "Not signed in"))
              && !AccountsLayout.offersAddClaude(AccountInfo(agent: "Claude", status: "Not installed"))
              && AccountsLayout.offersAddClaude(AccountInfo(agent: "Claude", status: "you@example.com")),
              "Add Claude account… waits for Claude's own sign-in")

        // agy: the file there → signed in; not there → Unknown, not "needs sign-in", no card, but Sign in… in Settings.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-agy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let token = dir.appendingPathComponent("jetski-standalone-oauth-token")
        let unknown = AccountsReader.agy(token: token)
        check(unknown.status == "Unknown · agy" && AccountsLayout.group(unknown.status) != .needsSignIn && !unknown.isSignedIn,
              "agy, no file → Unknown, not counted as needing sign-in")
        check(Suggestions.make(accounts: [unknown], found: []).isEmpty, "agy Unknown: no card in the panel")
        if case .signIn(let command)? = Providers.named("Antigravity")?.fixSuggestion(for: unknown.status)?.action {
            check(command.display == "agy", "agy Unknown: its row still has Sign in… (agy)")
        } else { check(false, "agy Unknown: its row still has Sign in…") }
        FileManager.default.createFile(atPath: token.path, contents: Data())
        check(AccountsReader.agy(token: token).status == "Signed in · agy", "agy, file there → signed in (not opened)")
        return failures
    }
}
