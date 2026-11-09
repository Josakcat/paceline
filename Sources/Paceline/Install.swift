import AppKit
import SwiftUI

/// How to install an AI that isn't installed: its maker's own command and/or
/// download page. Settings → Accounts shows it under Install…; Paceline itself
/// installs nothing. "Install in Terminal…" opens a .command (SignInLauncher's)
/// that prints the command and waits for Return before it runs it.
struct Install: Sendable {
    /// The maker's one-line install, exactly as their docs give it.
    var command: String? = nil
    /// Its Homebrew formula, from the same docs: offered when there's brew but no npm.
    var brew: String? = nil
    /// Their download or install page.
    let page: URL
    var pageTitle = "Download page"
    /// A VS Code extension: the Marketplace page, and "Open in VS Code" when VS Code is here.
    var vsCodeExtension: String? = nil
    var note: String? = nil

    /// Every host the table may point at: the makers' own sites (and nodejs.org, brew.sh).
    static let officialHosts: Set<String> = [
        "claude.ai", "claude.com", "chatgpt.com", "developers.openai.com", "antigravity.google", "opencode.ai",
        "ampcode.com", "gh.io", "docs.github.com", "github.com", "cursor.com", "devin.ai", "kiro.dev",
        "docs.cline.bot", "kilo.ai", "marketplace.visualstudio.com", "nodejs.org", "brew.sh",
    ]

    typealias Need = (tool: String, name: String, url: URL)

    /// What a command needs first: npm or brew, by its first word.
    static func needs(_ command: String?) -> Need? {
        switch command?.split(separator: " ").first {
        case "npm": ("npm", "Node.js", URL(string: "https://nodejs.org/en/download")!)
        case "brew": ("brew", "Homebrew", URL(string: "https://brew.sh")!)
        default: nil
        }
    }

    /// The command to offer, and what's missing to run it: npm's when npm is here (or
    /// there's no formula), else brew's when brew is; with neither, both are missing.
    func choice(has: (String) -> Bool) -> (command: String?, missing: [Need]) {
        guard let need = Self.needs(command), !has(need.tool) else { return (command, []) }
        guard let brew, let homebrew = Self.needs(brew) else { return (command, [need]) }
        if has(homebrew.tool) { return (brew, []) }
        return (command, [need, homebrew])
    }

    /// The links to show, in order.
    var links: [Suggestion.Link] {
        [Suggestion.Link(title: pageTitle, url: page)]
            + (vsCodeExtension.map { [Suggestion.Link(title: "VS Code Marketplace", url: Self.marketplace($0))] } ?? [])
    }

    static func marketplace(_ id: String) -> URL { URL(string: "https://marketplace.visualstudio.com/items?itemName=\(id)")! }
    static func openInVSCode(_ id: String) -> URL { URL(string: "vscode:extension/\(id)")! }
    static var hasVSCode: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil }

    /// Every URL in it, the command's too, for the self-test.
    var allURLs: [URL] {
        links.map(\.url) + (vsCodeExtension.map { [Self.openInVSCode($0)] } ?? []) + [command, brew].compactMap { Self.needs($0)?.url }
            + (command ?? "").split(separator: " ").filter { $0.hasPrefix("https://") }.compactMap { URL(string: String($0)) }
    }

    /// The .command: says what it will run, waits for Return (Control-C or closing the
    /// window cancels; no input at all runs nothing), then runs it with bash.
    static func script(_ command: String, agent: String) -> String {
        let q = ClaudeAccounts.shellQuote
        let header = ["Paceline: install \(agent).", "This runs its maker's own installer:", "", "  " + command, "",
                      "Press Return to install, or Control-C to cancel."]
        return """
        #!/bin/sh
        rm -f -- "$0"
        clear
        printf '%s\\n' \(header.map(q).joined(separator: " "))
        read -r answer || exit 1
        /bin/bash -c \(q(command))
        printf '\\n%s\\n' \(q("Done. You can close this window."))

        """
    }

    @MainActor static func launch(_ command: String, agent: String) -> Bool {
        SignInLauncher.cleanUp()
        guard let file = try? SignInLauncher.write(text: script(command, agent: agent), prefix: "install") else { return false }
        return SignInLauncher.open(file)
    }
}

/// Install…: the command (Copy, Install in Terminal…) and the maker's pages.
struct InstallSheet: View {
    let agent: String
    let install: Install
    let controller: AppController
    let close: () -> Void
    @State private var copied = false
    /// npm, else brew: looked for once, through the login shell, when the sheet comes up.
    @State private var found: (command: String?, missing: [Install.Need])?

    var body: some View {
        let waiting = controller.model.signInWaiting.contains(agent)
        let choice = found ?? (install.command, [])
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: AILogos.listIcon(for: agent, size: 22))
                Text("Install \(agent)").font(.headline)
            }
            if let note = install.note {
                Text(note).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let command = choice.command {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Its own installer, to run in Terminal:").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") { controller.copyString(command); copied = true }.controlSize(.small)
                    }
                    .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    if !choice.missing.isEmpty {
                        HStack {
                            Text("This needs \(choice.missing.map { "\($0.name) (\($0.tool))" }.joined(separator: " or ")) first.").font(.caption)
                            ForEach(choice.missing, id: \.tool) { need in
                                Button("Get \(need.name)") { NSWorkspace.shared.open(need.url) }.controlSize(.small)
                            }
                        }
                    } else {
                        HStack {
                            Button("Install in Terminal…") { controller.install(agent, command: command) }
                                .buttonStyle(.borderedProminent).tint(PacelineMark.deepMint)
                                .help("Opens Terminal showing the command. Nothing runs until you press Return there.")
                            if waiting {
                                ProgressView().controlSize(.mini)
                                Text("Waiting for the install…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(install.links, id: \.url) { link in
                    Button(link.title) { NSWorkspace.shared.open(link.url) }.help(link.url.absoluteString)
                }
                if let id = install.vsCodeExtension, Install.hasVSCode {
                    Button("Open in VS Code") { NSWorkspace.shared.open(Install.openInVSCode(id)); controller.watchInstall(agent) }
                }
            }
            .controlSize(.small)
            Text("Paceline installs nothing itself. Once it’s installed, its row turns to Sign in… or ✓ by itself.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { found = install.choice { CommandFinder.find($0) != nil || AccountsReader.loginShellPath($0) != nil } }
    }
}
