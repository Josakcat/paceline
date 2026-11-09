import AppKit
import SwiftUI

/// "Add Claude account…": name and folder, sign in, then plan limits.
/// Nothing is saved until Done, except when the user asks Paceline to add a
/// status line (then the account is kept, since its settings.json now points here).
struct AddAccountSheet: View {
    let model: AppModel
    let controller: AppController
    let close: () -> Void

    @State private var step: Int
    @State private var name: String
    @State private var dir: String
    @State private var dirChosen = false
    @State private var signedIn: AccountInfo?
    @State private var limitsArrived = false
    @State private var confirmStatusLine = false
    @State private var statusLineResult: ClaudeAccounts.StatusLineResult?
    @State private var saved: ClaudeAccount?      // once the status line went in
    @State private var copied: String?

    /// Shown as "~" too, so the demo's temporary home reads like a real one.
    private static let home = Demo.home

    init(model: AppModel, controller: AppController, step: Int, name: String = "", close: @escaping () -> Void) {
        self.model = model
        self.controller = controller
        self.close = close
        _step = State(initialValue: step)
        _name = State(initialValue: name)
        _dir = State(initialValue: name.isEmpty ? "" : Self.home + "/.claude-" + ClaudeAccounts.slug(name))
    }

    private var account: ClaudeAccount {
        saved ?? ClaudeAccount(id: ClaudeAccounts.newID(for: name, existing: model.claudeAccounts),
                               name: name.trimmingCharacters(in: .whitespaces), configDir: ClaudeAccounts.standardized(dir))
    }

    /// Why step 1 can't go on yet, if it can't.
    private var problem: String? {
        if saved != nil { return nil }   // kept already: its own name and folder aren't "taken"
        if let problem = ClaudeAccounts.nameProblem(name, existing: model.claudeAccounts) { return problem }
        return ClaudeAccounts.folderProblem(dir, existing: model.claudeAccounts, home: Self.home)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Claude account").font(.headline)
            Text("Step \(step) of 3").font(.caption).foregroundStyle(.secondary)
            switch step {
            case 1: nameStep
            case 2: signInStep
            default: limitsStep
            }
            HStack {
                if saved == nil { Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction) }
                Spacer()
                // Once the status line went in, the account is kept: no going back to rename it.
                if step > 1 && saved == nil { Button("Back") { step -= 1 } }
                if step < 3 {
                    Button("Next") { step += 1 }.keyboardShortcut(.defaultAction).disabled(problem != nil)
                        .buttonStyle(.borderedProminent).tint(PacelineMark.deepMint)
                } else {
                    Button {
                        if saved == nil { controller.addClaudeAccount(account) }
                        close()
                    } label: { Text("Done") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(PacelineMark.deepMint)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .tint(PacelineMark.mint)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: step) { await watch() }
        // "Sign in first" is checked again on coming back to step 3.
        .onChange(of: step) { if statusLineResult == .noFolder { statusLineResult = nil } }
        .alert("Add a status line to this account?", isPresented: $confirmStatusLine) {
            Button("Add") { addStatusLine() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paceline will add a statusLine entry to \(ClaudeAccounts.tilde(account.configDir, home: Self.home))/settings.json. Nothing else in the file changes, and it won’t replace a status line that’s already there.")
        }
    }

    // MARK: Steps

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each Claude Code account keeps its sign-in and settings in its own folder; Claude Code uses it when CLAUDE_CONFIG_DIR points there.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("Work"))
                .onChange(of: name) { _, new in
                    if !dirChosen { dir = new.trimmingCharacters(in: .whitespaces).isEmpty ? "" : Self.home + "/.claude-" + ClaudeAccounts.slug(new) }
                }
            HStack {
                Text(dir.isEmpty ? "Folder" : ClaudeAccounts.tilde(dir, home: Self.home)).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(dir.isEmpty ? .tertiary : .primary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            if let problem, !name.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var signInStep: some View {
        let folder = ClaudeAccounts.shellPath(account.configDir, home: Self.home)
        let alias = "claude-" + account.id
        return VStack(alignment: .leading, spacing: 10) {
            Text("In Terminal, start Claude Code with this folder, then type /login:")
                .font(.callout).foregroundStyle(.secondary)
            copyRow("CLAUDE_CONFIG_DIR=\(folder) claude")
            Text("To make it a command, add this line to ~/.zshrc yourself:")
                .font(.callout).foregroundStyle(.secondary)
            copyRow("alias \(alias)=" + ClaudeAccounts.shellQuote("CLAUDE_CONFIG_DIR=\(folder) claude"))
            signInStatus
        }
    }

    private var limitsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            signInStatus
            // The easiest way: nothing to set up in Claude Code.
            Toggle(isOn: Binding(get: { model.fetchFresh }, set: { controller.setFetchFresh($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Easiest: let Paceline ask Claude Code").font(.callout.weight(.medium))
                    Text("It asks each account for its limits when they’re over 15 minutes old. No prompt, nothing billed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(PacelineMark.mint)
            Text("Or, interactive sessions: Claude Code’s status line saves the limits.").font(.callout.weight(.medium))
            switch statusLineResult {
            case .added?:
                Label("Added to \(ClaudeAccounts.tilde(account.configDir, home: Self.home))/settings.json", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            case .alreadySet?, .unreadable?:
                Text(statusLineResult == .alreadySet
                     ? "This account already has a status line, so Paceline left it alone. To use Paceline’s, put this in its settings.json yourself:"
                     : "Its settings.json couldn’t be read, so Paceline left it alone. Put this in it yourself:")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                copyRow(PlanUsageReader.statusLineJSON)
            case .noFolder?:
                Text("The folder isn’t there yet: sign in first (step 2).").font(.callout).foregroundStyle(.orange)
            case nil:
                Button("Add status line to this account…") { confirmStatusLine = true }
            }
            Text("Or, runs with claude -p: pipe stream-json into Paceline.").font(.callout.weight(.medium))
            copyRow(PlanUsageReader.claudeLimitsCommand(account))
            HStack(spacing: 6) {
                if limitsArrived {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Plan limits: up to date")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Plan limits: waiting…").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var signInStatus: some View {
        HStack(spacing: 6) {
            if let signedIn {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Signed in as \(signedIn.status)" + (signedIn.plan.map { " · \($0)" } ?? "")).lineLimit(1)
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func copyRow(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)   // whole, however many lines: it's for copying
            Spacer()
            Button(copied == text ? "Copied" : "Copy") {
                controller.copyString(text)
                copied = text
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Actions

    /// Every 2.5 s while the sheet is up: signed in yet? limits saved yet? Reads only.
    private func watch() async {
        while !Task.isCancelled, !Demo.isOn || Demo.isNewUser {
            let account = self.account
            let (info, plan) = await Task.detached {
                (AccountsReader.claude(account.configURL.appendingPathComponent(".claude.json"), agent: account.name),
                 PlanUsageReader.claude(account) != nil)
            }.value
            signedIn = info.status == "Not signed in" ? nil : info
            limitsArrived = plan
            try? await Task.sleep(for: .seconds(2.5))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        try? FileManager.default.createDirectory(atPath: Self.home, withIntermediateDirectories: true)
        panel.directoryURL = URL(fileURLWithPath: Self.home)
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            dir = url.path
            dirChosen = true
        }
    }

    /// Only after the alert, and never into the main ~/.claude (step 1 won't allow it).
    private func addStatusLine() {
        let account = self.account
        guard ClaudeAccounts.standardized(account.configDir) != ClaudeAccounts.standardized("~/.claude") else { return }
        let result = ClaudeAccounts.addStatusLine(command: PlanUsageReader.statusLineCommand, toSettingsIn: account.configURL)
        statusLineResult = result
        if result == .added {
            controller.addClaudeAccount(account)
            saved = account
        }
    }
}
