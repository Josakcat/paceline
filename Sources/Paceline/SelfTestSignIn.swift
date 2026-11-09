import Foundation

extension SelfTest {
    /// Sign in…: each AI's command, the .command file, and that odd names stay words.
    static func signInTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  sign in: \(what)")
        }
        func command(_ agent: String, _ status: String = "Not signed in") -> SignInCommand? {
            if case .signIn(let command)? = Providers.named(agent)?.fixSuggestion(for: status)?.action { return command }
            return nil
        }

        // The table's commands, as each tool's --help or docs say.
        check(command("Claude") == SignInCommand("claude auth login") && command("Claude")?.arguments == ["auth", "login"],
              "Claude Code → claude auth login")
        check(command("Codex")?.display == "codex login", "Codex → codex login")
        check(command("OpenCode")?.display == "opencode auth login", "OpenCode → opencode auth login")
        check(command("Amp")?.display == "amp login", "Amp → amp login")
        check(command("GitHub Copilot")?.display == "copilot" && command("GitHub Copilot")?.then?.contains("/login") == true,
              "Copilot CLI → copilot, then /login")
        check(command("Antigravity", "Unknown · agy")?.display == "agy" && command("Antigravity", "Installed") == nil,
              "agy alone (sign-in unknown) → agy; the app → open it, no command")
        let gemini = Providers.named("Gemini CLI")?.fixSuggestion(for: "Not signed in")
        if case .links(let links)? = gemini?.action {
            check(links.map(\.url.absoluteString) == ["https://aistudio.google.com/apikey", "https://antigravity.google"]
                  && gemini?.detail.contains("GEMINI_API_KEY") == true, "Gemini CLI: no Google sign-in; an API key or Antigravity")
        } else { check(false, "Gemini CLI: links, not a sign-in") }
        check(["Cursor", AccountsReader.windsurfName, "Kiro"].allSatisfy { agent in
            if case .openApp? = Providers.named(agent)?.fixSuggestion(for: "Not signed in")?.action { return true }
            return false
        }, "Cursor, Windsurf, Kiro → open the app")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-signin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gHome = dir.appendingPathComponent("gemini")
        try? FileManager.default.createDirectory(at: gHome, withIntermediateDirectories: true)
        check(AccountsReader.geminiCLI(home: gHome, installed: true, apiKey: { true })?.status == "Signed in · API key"
              && AccountsReader.geminiCLI(home: gHome, installed: true, apiKey: { false })?.status == "Not signed in",
              "Gemini CLI: GEMINI_API_KEY in the shell counts as signed in")

        // Copilot's folder from an editor plugin, no CLI: there's nothing to run here.
        let plugin = dir.appendingPathComponent("github-copilot")
        try? FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let pluginOnly = AccountsReader.copilot(config: plugin, cli: dir.appendingPathComponent("no-cli"), extensionDirs: [])
        check(CommandFinder.find("copilot") != nil || (pluginOnly?.status == "Unknown · sign in from your editor"
              && Providers.named("GitHub Copilot")?.fixSuggestion(for: pluginOnly?.status ?? "") == nil),
              "Copilot without its CLI: sign in from the editor, no button")

        // An extra Claude account signs in in its own folder; not installed suggests nothing.
        let work = ClaudeAccount(id: "work", name: "Work", configDir: "/tmp/home/my work")
        let made = Suggestions.make(accounts: [AccountInfo(agent: "Work", status: "Not signed in"), AccountInfo(agent: "Amp", status: "Not installed")],
                                    found: [], listed: [work])
        check(made.map(\.id) == ["signin|Work"] && made.first?.action == .signIn(.init("claude auth login", configDir: "/tmp/home/my work")),
              "extra account → claude auth login with its CLAUDE_CONFIG_DIR → \(made.map(\.id))")
        check(SignInCommand("claude auth login", configDir: "/tmp/home/my work").display == "CLAUDE_CONFIG_DIR='/tmp/home/my work' claude auth login",
              "Copy command: the folder quoted")
        check(Suggestions.make(accounts: [AccountInfo(agent: "Work", status: "you@example.com")], found: [], listed: [work]).isEmpty,
              "extra account signed in: nothing")
        check(AccountInfo(agent: "X", status: "Signed in · agy").isSignedIn && !AccountInfo(agent: "X", status: "Not signed in").isSignedIn
              && !AccountInfo(agent: "X", status: "Installed").isSignedIn && !AccountInfo(agent: "X", status: "Unknown · sign in from your editor").isSignedIn,
              "what counts as signed in for the watch")

        // The script, run for real with a stand-in tool: odd names stay one word each.
        let odd = "it's; $(touch PWNED) `touch PWNED` & \"x\" \\ end"
        let toolDir = dir.appendingPathComponent("bin \(odd)")
        try? FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        let tool = toolDir.appendingPathComponent("fake tool")
        try? Data("#!/bin/sh\nprintf '[%s]' \"$@\"; printf '{%s}' \"$CLAUDE_CONFIG_DIR\"\n".utf8).write(to: tool)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let folder = dir.appendingPathComponent("out")
        let weird = SignInCommand("claude auth login", configDir: "/tmp/\(odd)", then: "Type /login; $(touch PWNED)")
        let file = try? SignInLauncher.write(weird, agent: "Work \(odd)", path: tool.path, in: folder)
        let attributes = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let folderMode = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.posixPermissions] as? Int
        check(file?.pathExtension == "command" && attributes?[.posixPermissions] as? Int == 0o700 && folderMode == 0o700
              && file?.lastPathComponent.hasPrefix("signin-") == true,
              ".command written, owner-only, in an owner-only folder, named without the account's name")
        let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check(text.hasPrefix("#!/bin/sh\n") && text.contains("Paceline: signing in to Work") && text.contains("You can close this window"),
              "it says what it's doing and when it's done")
        if let file {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [file.path]
            process.currentDirectoryURL = dir
            process.environment = ["PATH": "/usr/bin:/bin", "TERM": "dumb"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            check(out.contains("[auth][login]{/tmp/\(odd)}"), "the tool gets auth, login and the folder exactly")
            check(out.contains("Work \(odd)") && out.contains("Type /login; $(touch PWNED)"), "the header prints the names as they are")
            check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("PWNED").path), "nothing in a name ran")
            check(!FileManager.default.fileExists(atPath: file.path), "the file removes itself when it runs")
        }

        // Left over (its window closed first): removed next time, once 10 minutes old.
        let old = try? SignInLauncher.write(SignInCommand("codex login"), agent: "Codex", path: "/bin/echo", in: folder)
        let fresh = try? SignInLauncher.write(SignInCommand("codex login"), agent: "Codex", path: "/bin/echo", in: folder)
        if let old { try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-700)], ofItemAtPath: old.path) }
        SignInLauncher.cleanUp(in: folder)
        check(old.map { !FileManager.default.fileExists(atPath: $0.path) } == true
              && fresh.map { FileManager.default.fileExists(atPath: $0.path) } == true, "left-over files removed; a new one kept")
        return failures
    }
}
