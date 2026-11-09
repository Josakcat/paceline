import AppKit

/// A CLI's own sign-in, as Paceline runs it in Terminal. Each was checked
/// against the tool's `--help` or docs (2026-11-09):
/// - Claude Code 2.1: `claude auth login` (no chat session needed).
/// - Codex: `codex login`. OpenCode: `opencode auth login`. Amp: `amp login`.
/// - Copilot CLI: no login command; it's `copilot`, then /login (docs.github.com).
/// - agy: no login command in its help; it asks when it starts.
struct SignInCommand: Equatable, Sendable {
    let tool: String
    let arguments: [String]
    /// CLAUDE_CONFIG_DIR, for an extra Claude account.
    var configDir: String? = nil
    /// What to do once it opens, when the tool has no login command: "Type /login."
    var then: String? = nil

    /// "codex login": words split on spaces (the table's commands have no quotes).
    init(_ line: String, configDir: String? = nil, then: String? = nil) {
        let words = line.split(separator: " ").map(String.init)
        tool = words.first ?? ""
        arguments = Array(words.dropFirst())
        self.configDir = configDir
        self.then = then
    }

    /// What Copy copies: the same command, to type in any shell.
    var display: String {
        (configDir.map { "CLAUDE_CONFIG_DIR=\(ClaudeAccounts.shellPath($0)) " } ?? "")
            + ([tool] + arguments.map { ClaudeAccounts.shellPath($0) }).joined(separator: " ")
    }
}

/// Opens Terminal running a sign-in: a .command file in Paceline's own temp
/// folder (owner-only), opened with Terminal. No AppleScript, so no
/// Automation permission. Every word in it is single-quoted, so an account's
/// name or folder can't add a command. The file removes itself when it runs,
/// and anything left over is removed the next time.
enum SignInLauncher {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Paceline-signin", isDirectory: true)

    /// The script: a header saying what's happening, the command, and a last line saying it's done.
    static func script(_ command: SignInCommand, agent: String, path: String) -> String {
        let q = ClaudeAccounts.shellQuote
        let run = (command.configDir.map { "CLAUDE_CONFIG_DIR=\(q($0)) " } ?? "") + ([path] + command.arguments).map(q).joined(separator: " ")
        let header = ["Paceline: signing in to \(agent).", "Running: \(command.display)"] + (command.then.map { [$0] } ?? []) + [""]
        return """
        #!/bin/sh
        rm -f -- "$0"
        clear
        printf '%s\\n' \(header.map(q).joined(separator: " "))
        \(run)
        printf '\\n%s\\n' \(q("Done. You can close this window."))

        """
    }

    /// Writes it (700, in a 700 folder), and returns where.
    static func write(_ command: SignInCommand, agent: String, path: String, in folder: URL = folder) throws -> URL {
        try write(text: script(command, agent: agent, path: path), prefix: "signin", in: folder)
    }

    /// Any script (Install's too), the same way: "<prefix>-<uuid>.command".
    static func write(text: String, prefix: String, in folder: URL = folder) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent("\(prefix)-\(UUID().uuidString).command")
        try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    /// Files left from earlier (a window closed before it ran), older than `age`.
    static func cleanUp(in folder: URL = folder, olderThan age: TimeInterval = 600, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "command" {
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(changed) >= age { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The tool where its installers put it, else the login shell's PATH, else its bare name.
    static func path(of tool: String) -> String {
        CommandFinder.find(tool) ?? AccountsReader.loginShellPath(tool) ?? tool
    }

    @MainActor static func launch(_ command: SignInCommand, agent: String) -> Bool {
        cleanUp()
        guard let file = try? write(command, agent: agent, path: path(of: command.tool)) else { return false }
        return open(file)
    }

    /// Opens a written .command with Terminal.
    @MainActor static func open(_ file: URL) -> Bool {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
