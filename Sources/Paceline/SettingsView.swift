import ServiceManagement
import SwiftUI

/// The Settings window's tabs; `Paceline --debug settings <tab>` opens one.
enum SettingsTab: String, CaseIterable, Sendable {
    case general, accounts, appearance
}

/// Everything that used to need `defaults write`, in one window.
struct SettingsView: View {
    @Bindable var model: AppModel
    let controller: AppController

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var copied: String?     // the text last copied, for its button's "Copied"
    @State private var accounts: [AccountInfo] = []
    @State private var loadingAccounts = false
    @State private var removing: ClaudeAccount?
    @State private var foundName = ""
    @AppStorage("accountsOpenReady", store: Demo.defaults) private var openReady = true
    @AppStorage("accountsOpenNeedsSignIn", store: Demo.defaults) private var openNeedsSignIn = true
    @AppStorage("accountsShowNotInstalled", store: Demo.defaults) private var openNotInstalled = false

    var body: some View {
        TabView(selection: $model.settingsTab) {
            general.fitsWindow(.general, model: model, controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            accountsTab.fitsWindow(.accounts, model: model, controller: controller)
                .onChange(of: model.claudeAccounts) { loadAccounts() }   // added or removed elsewhere: show it
                .onChange(of: model.signInsChanged) { loadAccounts() }   // Sign in… finished
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag(SettingsTab.accounts)
            Form { AppearanceSection(appearance: $model.appearance) }.formStyle(.grouped)
                .fitsWindow(.appearance, model: model, controller: controller)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
        }
        .frame(minWidth: 460, minHeight: 200)
        .tint(PacelineMark.mint)
        .onChange(of: model.settingsTab) { _, tab in
            controller.fitSettings(tab)
            if tab == .accounts { loadAccounts() }   // installed or signed in elsewhere since: show it
        }
        .sheet(isPresented: Binding(get: { model.installGuide != nil }, set: { if !$0 { model.installGuide = nil } }),
               onDismiss: { loadAccounts() }) {
            if let name = model.installGuide, let install = Providers.named(name)?.install {
                InstallSheet(agent: name, install: install, controller: controller) { model.installGuide = nil }
            }
        }
        .sheet(isPresented: Binding(get: { model.addAccountStep != nil }, set: { if !$0 { model.addAccountStep = nil } }),
               onDismiss: { model.addAccountSample = ""; loadAccounts() }) {
            AddAccountSheet(model: model, controller: controller, step: model.addAccountStep ?? 1, name: model.addAccountSample) {
                model.addAccountStep = nil
            }
            .id(model.addAccountStep)   // a new start step (from `--debug add-account`) starts it over
        }
        .alert("Add this Claude account?", isPresented: Binding(get: { model.pendingFound != nil }, set: { if !$0 { model.pendingFound = nil } })) {
            TextField("Name", text: $foundName)
            Button("Add") {
                if let found = model.pendingFound { controller.confirmFound(found, name: foundName) }
                loadAccounts()
            }
            .disabled(ClaudeAccounts.nameProblem(foundName, existing: model.claudeAccounts) != nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((model.pendingFound?.detail ?? "") + " Paceline will show it under this name; nothing in the folder changes.")
        }
        .onChange(of: model.pendingFound) { _, found in
            if case .addAccount(_, let name)? = found?.action {
                foundName = ClaudeAccounts.nameProblem(name, existing: model.claudeAccounts) == nil ? name : name + " " + String(model.claudeAccounts.count + 2)
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "") from Paceline?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button("Remove", role: .destructive) {
                controller.removeClaudeAccount(account.id)
                loadAccounts()
            }
        } message: { account in
            Text("Paceline stops showing it. \(ClaudeAccounts.tilde(account.configDir)) and everything in it stay as they are.")
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            copied = nil
            loadAccounts()
        }
    }

    private var general: some View {
        // Grouped by job, each explanation under its option (a second Text is the subtitle).
        Form {
            Section {
                Picker("Shows", selection: Binding(get: { model.menuBarShows }, set: { controller.setMenuBarShows($0) })) {
                    ForEach(MenuBarShows.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)   // two choices; segments take the mint, pop-ups the system accent
                Picker(selection: Binding(get: { model.menuBarStyle }, set: { controller.setMenuBarStyle($0) })) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Text("Style")
                    Text("Two rows: 5-hour over weekly.")
                }
                .pickerStyle(.segmented)
                orderRows
            } header: { Label("Menu Bar", systemImage: "menubar.rectangle").tightHeader() }

            Section {
                Toggle(isOn: Binding(get: { model.notify }, set: { controller.setNotify($0) })) {
                    Text("Notify when a plan runs low or resets")
                    Text("At 20% and 10% left, before one runs out, and on reset.")
                }
            } header: { Label("Notifications", systemImage: "bell").tightHeader() }

            Section {
                Toggle(isOn: Binding(get: { model.fetchFresh }, set: { controller.setFetchFresh($0) })) {
                    Text("Fetch fresh numbers when stale")
                    Text("Asks claude and agy when over 15 min old. Nothing billed.")
                }
            } header: { Label("Data", systemImage: "arrow.triangle.2.circlepath").tightHeader() }

            Section {
                Toggle(isOn: Binding(get: { !model.showUSD }, set: { if $0 == model.showUSD { controller.toggleUnits() } })) {
                    Text("Show tokens instead of $")
                    Text("Or click today’s total in the panel.")
                }
                Toggle(isOn: Binding(get: { model.hideFromScreenSharing }, set: { controller.setHideFromScreenSharing($0) })) {
                    Text("Hide from screen sharing")
                    Text("Keeps names, spend and emails out of shares.")
                }
            } header: { Label("Panel", systemImage: "rectangle.portrait.on.rectangle.portrait").tightHeader() }

            Section {
                Toggle(isOn: $launchAtLogin) {
                    Text("Open at login")
                    if let loginError {
                        Text(loginError)
                    } else if !isInstalled {
                        Text("Move Paceline to Applications first, or login will open this copy.")
                    }
                }
                .onChange(of: launchAtLogin) { _, on in setLogin(on) }
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(Updates.current)
                        Button("Check for Updates…") { Updates.check() }
                    }
                } label: {
                    Text("Version")
                    Text("Local files only; online only to check for updates.")
                }
            }   // no header: the closing rows, as in System Settings
        }
        .formStyle(.grouped)
        .controlSize(.small)   // small switches: shorter rows
    }

    /// The AIs with numbers now, in the menu bar's order: drag a row, or use its
    /// arrows (VoiceOver, keyboard). The panel's rows follow the same order.
    @ViewBuilder private var orderRows: some View {
        let readings = model.aiReadings
        let keys = readings.map { model.orderKey($0.name) }
        if readings.count > 1 {
            // Folded, a row of logos in order: General stays one screen tall.
            DisclosureGroup(isExpanded: $model.orderExpanded) {
                ForEach(Array(readings.enumerated()), id: \.element.name) { i, reading in
                    HStack(spacing: 7) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Image(nsImage: AILogos.listIcon(for: reading.name, size: 16)).accessibilityHidden(true)
                        Text(reading.name).lineLimit(1)
                        Spacer()
                        Text(reading.text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        Button { move(keys, from: i, to: i - 1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0)
                            .accessibilityLabel("Move \(reading.name) up")
                        Button { move(keys, from: i, to: i + 2) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(i == readings.count - 1)
                            .accessibilityLabel("Move \(reading.name) down")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(reading.name), \(i + 1) of \(readings.count)")
                }
                .onMove { from, to in controller.setAIOrder(AIOrder.moved(keys, from: from, to: to, saved: model.aiOrder)) }
                HStack {
                    Spacer()
                    Button("Reset Order") { controller.setAIOrder([]) }.disabled(model.aiOrder.isEmpty)
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Order").font(.body)
                        Text("Menu bar and panel. Drag or use the arrows.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(readings, id: \.name) { Image(nsImage: AILogos.listIcon(for: $0.name, size: 14)) }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(readings.map(\.name).joined(separator: ", "))
                }
            }
        }
    }

    private func move(_ keys: [String], from: Int, to: Int) {
        controller.setAIOrder(AIOrder.moved(keys, from: IndexSet(integer: from), to: to, saved: model.aiOrder))
    }

    private func openBinding(_ group: AccountsLayout.Group) -> Binding<Bool> {
        switch group {
        case .ready: $openReady
        case .needsSignIn: $openNeedsSignIn
        case .notInstalled: $openNotInstalled
        }
    }

    /// One line per AI in three groups (Ready, Needs sign-in, Not installed, the last folded);
    /// everything else about an AI is in its ⓘ popover.
    private var accountsTab: some View {
        let sections = AccountsLayout.sections(accounts, extras: Set(model.claudeAccounts.map(\.name)))
        return Form {
            if sections.isEmpty {
                Section { Text("Reading…").foregroundStyle(.secondary) } header: { accountsHeader }
            }
            ForEach(sections) { section in
                let open = openBinding(section.group)
                Section {
                    if open.wrappedValue {
                        ForEach(section.rows) { row in
                            accountRow(row.account)
                            if row.account.agent == "Claude" { claudeChildren(row) }
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 10) {
                        if section.id == sections.first?.id { accountsHeader }
                        groupHeader(section, open: open)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "Ready 6 ›": a click folds or opens it, remembered on this Mac.
    private func groupHeader(_ section: AccountsLayout.Section, open: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { open.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Text(section.group.rawValue)
                Text(String(section.count)).foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.group.rawValue), \(section.count)")
        .accessibilityValue(open.wrappedValue ? "Open" : "Folded")
        .accessibilityHint(open.wrappedValue ? "Folds this group" : "Shows this group")
        .accessibilityAddTraits(.isHeader)
    }

    /// Logo · name · plan · who · then ✓, Sign in… or Install…, and ⓘ.
    private func accountRow(_ account: AccountInfo, indent: Bool = false) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(nsImage: AILogos.listIcon(for: account.agent, size: indent ? 16 : 18))
                Text(account.agent).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                if let plan = account.plan { PlanBadge(text: plan) }
                if let detail = AccountsLayout.detail(account) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowLabel(account))
            Spacer(minLength: 4)
            rowStatus(account)
            Button { model.accountDetails = account.agent } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Details").accessibilityLabel("\(account.agent) details")
                .popover(isPresented: Binding(get: { model.accountDetails == account.agent },
                                              set: { if !$0, model.accountDetails == account.agent { model.accountDetails = nil } }),
                         arrowEdge: .trailing) { details(account) }
        }
        .padding(.leading, indent ? 25 : 0)
    }

    /// "Claude, ready, Pro, someone.long@example.com" for VoiceOver: the whole email, not the short one.
    private func rowLabel(_ account: AccountInfo) -> String {
        let state = switch AccountsLayout.group(account.status) {
        case .ready: "ready"
        case .needsSignIn: "needs sign-in"
        case .notInstalled: "not installed"
        }
        let who = account.status.contains("@") ? account.status : AccountsLayout.detail(account)
        return ([account.agent, state, account.plan, who].compactMap { $0 } + (model.claudeAccounts.contains { $0.name == account.agent } ? ["added Claude account"] : []))
            .joined(separator: ", ")
    }

    /// ✓ when ready; its Sign in… (or Open, or links) when signed out; Install… when it isn't there.
    @ViewBuilder private func rowStatus(_ account: AccountInfo) -> some View {
        switch AccountsLayout.group(account.status) {
        case .ready:
            if account.status.hasPrefix("Unknown ·") {
                if let fix = fix(account) {   // agy: Sign in… anyway
                    SuggestionButtons(suggestion: fix, controller: controller, compact: true)
                } else {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityLabel("Sign-in not known")
                        .help(account.status)
                }
            } else if let editor = VSCodeAgents.openEditor(account.status, isInstalled: AccountsReader.installedApp) {
                // Cline, Roo Code, Kilo Code: their sign-in is the editor's secret, so open the editor.
                Button("Open \(editor.name)") { controller.openApp(editor.bundleID) }.controlSize(.small)
                    .help(VSCodeAgents.signInHint(account.agent))
            } else if account.status.hasPrefix("Installed ·") {   // signs in with keys kept by the editor
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).accessibilityLabel("Installed")
                    .help(account.status)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Signed in")
                    .help("Signed in")
            }
        case .needsSignIn:
            if let fix = fix(account) {
                SuggestionButtons(suggestion: fix, controller: controller, compact: true)
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Needs sign-in")
            }
        case .notInstalled:
            if let install = installAction(account) {
                if model.signInWaiting.contains(account.agent) {
                    ProgressView().controlSize(.mini).help("Waiting for the install…").accessibilityLabel("Waiting for the install")
                }
                Button("Install…", action: install).controlSize(.small).help("How to install \(account.agent), from its maker")
            }
        }
    }

    /// Under Claude: its added accounts, signed-in folders not added yet, the plan-limits setup when
    /// there's no data, and the one Add Claude account… button.
    @ViewBuilder private func claudeChildren(_ row: AccountsLayout.Row) -> some View {
        ForEach(row.extras) { accountRow($0, indent: true) }
        ForEach(model.suggestions.filter { $0.id.hasPrefix("add|") }) { found in
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.secondary).frame(width: 16)
                Text(found.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                SuggestionButtons(suggestion: found, controller: controller)
            }
            .padding(.leading, 25)
            .accessibilityElement(children: .contain).accessibilityLabel(found.title)
        }
        if AccountsLayout.group(row.account.status) == .ready && model.claudePlan == nil {
            HStack(spacing: 7) {
                Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.orange).frame(width: 16).accessibilityHidden(true)
                Text("No plan limits yet: they need Claude Code’s status line").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Set up…") { model.accountDetails = "Claude" }.controlSize(.small)
                    .accessibilityLabel("Set up Claude plan limits")
            }
            .padding(.leading, 25)
        }
        if AccountsLayout.offersAddClaude(row.account) {
            Button { model.addAccountStep = 1 } label: {
                Label("Add Claude account…", systemImage: "plus.circle.fill").font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.borderless).foregroundStyle(PacelineMark.deepMint)
            .padding(.leading, 25)
            .help("Another Claude login, in its own folder")
        }
    }

    /// Everything the row leaves out: who exactly, what's left, what Paceline can show, and how to fix or set it up.
    private func details(_ account: AccountInfo) -> some View {
        let extra = model.claudeAccounts.first { $0.name == account.agent }
        let provider = Providers.named(extra == nil ? account.agent : "Claude")
        let group = AccountsLayout.group(account.status)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(nsImage: AILogos.listIcon(for: account.agent, size: 24))
                VStack(alignment: .leading, spacing: 1) {
                    Text(extra == nil ? account.agent : "\(account.agent) (Claude)").font(.headline)
                    Text(account.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if let plan = account.plan { PlanBadge(text: plan) }
            }
            let left = provider?.group == .usage ? today(account.agent) : planLeft(account.agent)
            if let left {
                let age = AppModel.staleNote(model.plans.filter { $0.agent == account.agent })
                Text([left, age].compactMap { $0 }.joined(separator: " · ")).font(.caption.monospacedDigit())
            }
            if let note = note(account) { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let provider {
                Text("Paceline shows: " + Provider.Capability.allCases.filter { provider.capabilities.contains($0) && $0 != .usageLink }
                    .map(\.rawValue).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                if provider.group == .signInOnly {
                    Text("Its usage is on its own site. Paceline doesn’t use your sign-in to fetch it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if group != .notInstalled, let fix = fix(account) {
                Divider()
                Text(fix.detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                SuggestionButtons(suggestion: fix, controller: controller)
            }
            if group == .notInstalled, let install = installAction(account) {
                Button("Install…") { model.accountDetails = nil; install() }.controlSize(.small)
            }
            if account.agent == "Claude" && group != .notInstalled {
                Divider()
                claudePlanUsage
            }
            if let extra {
                Divider()
                extraPlanUsage(extra)
            }
            if signedIn(account), let link = provider?.usagePage {
                Button("View Usage") { NSWorkspace.shared.open(link) }.controlSize(.small)
                    .help(link.host().map { "Opens \($0)" } ?? "")
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .tint(PacelineMark.mint)
    }

    /// Its fix for this sign-in state, even if the panel's card was dismissed (here it was asked
    /// for), and agy's, which gets no card.
    private func fix(_ account: AccountInfo) -> Suggestion? {
        Suggestions.make(accounts: [account], found: [], listed: model.claudeAccounts).first
            ?? Providers.named(account.agent)?.fixSuggestion(for: account.status)
    }

    /// Install…, for an AI that isn't installed: its guide (Install.swift).
    private func installAction(_ account: AccountInfo) -> (() -> Void)? {
        guard account.status == "Not installed", Providers.named(account.agent)?.install != nil else { return nil }
        return { model.installGuide = account.agent }
    }

    private func signedIn(_ account: AccountInfo) -> Bool {
        !["Not installed", "Not signed in", "Installed"].contains(account.status)
    }

    /// "Today 2.4M tokens · $2.29", or nothing when it wasn't used today.
    private func today(_ agent: String) -> String? {
        guard let usage = model.otherUsage.first(where: { $0.source == agent }) else { return nil }
        return usage.total.total > 0 ? "Today \(Format.tokens(usage.total.total)) · \(Format.usd(usage.usd))" : "Not used today"
    }

    /// "6 ready · 1 needs sign-in · 9 not installed", and Check again.
    private var accountsHeader: some View {
        HStack {
            Text(AccountsLayout.summary(accounts)).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if loadingAccounts { ProgressView().controlSize(.small) }
            Button { loadAccounts() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Check again").accessibilityLabel("Refresh").disabled(loadingAccounts)
        }
    }

    /// Where Claude's plan numbers come from, and the status line that saves them.
    private var claudePlanUsage: some View {
        planLimits(status: planStatus, hasData: model.claudePlan != nil, copy: PlanUsageReader.statusLineJSON,
                   how: "Set this as Claude Code’s status line in ~/.claude/settings.json. It only saves the 5-hour and weekly percentages and reset times on this Mac.")
    }

    /// An extra account: `claude -p` piped through `--claude-limits <id>`, or its own status line.
    @ViewBuilder private func extraPlanUsage(_ account: ClaudeAccount) -> some View {
        let plan = model.plans.first { $0.agent == account.name }
        let folder = ClaudeAccounts.tilde(account.configDir)
        planLimits(status: plan.map { $0.age() ?? "Up to date" } ?? "No data yet", hasData: plan != nil,
                   copy: PlanUsageReader.claudeLimitsCommand(account),
                   how: "For claude -p, add --output-format stream-json --verbose and pipe it into Paceline --claude-limits \(account.id); the result line still comes out. Interactive sessions can use the status line above in \(folder)/settings.json.",
                   remove: account)
    }

    /// Status and a Copy button; how it works stays folded once there's data.
    @ViewBuilder private func planLimits(status: String, hasData: Bool, copy: String, how: String, remove: ClaudeAccount? = nil) -> some View {
        let instructions = VStack(alignment: .leading, spacing: 6) {
            Text(how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(copy).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Text("Plan limits: \(status)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(copied == copy ? "Copied" : "Copy") {
                controller.copyString(copy)
                copied = copy
            }
            .controlSize(.small)
            if let remove { Button("Remove…") { model.accountDetails = nil; removing = remove }.controlSize(.small) }
        }
        if hasData {
            DisclosureGroup("How plan limits are read") { instructions }.font(.caption)
        } else {
            instructions
        }
    }

    /// Why an installed AI has no limits; an extra account's folder.
    private func note(_ account: AccountInfo) -> String? {
        if let extra = model.claudeAccounts.first(where: { $0.name == account.agent }) { return ClaudeAccounts.tilde(extra.configDir) }
        if account.status.hasPrefix("Installed · "), VSCodeAgents.agents.contains(where: { $0.name == account.agent }) {
            return VSCodeAgents.signInHint(account.agent)
        }
        return codexNote(account)
    }

    private func codexNote(_ account: AccountInfo) -> String? {
        // Signed out: the sign-in fix under the row says more.
        if model.suggestions.contains(where: { $0.agent == "Codex" }) { return nil }
        return account.agent == "Codex" && !model.plans.contains { $0.agent == "Codex" } && account.status != "Not installed"
            ? "Plan limits appear after using the Codex CLI." : nil
    }

    /// Both windows, each the tightest across model groups: "5h 59% · Week 38% left".
    private func planLeft(_ agent: String) -> String? {
        AppModel.planSummary(model.plans.filter { $0.agent == agent })
    }

    private func loadAccounts() {
        controller.refreshSuggestions()
        loadingAccounts = true
        Task {
            let found = await Task.detached { AccountsReader.all() }.value
            accounts = found
            loadingAccounts = false
        }
    }

    private var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private var planStatus: String {
        guard let plan = model.claudePlan else { return "No data yet" }
        let writer = PlanUsageReader.claudeWriter().map { " from \($0)’s status line" } ?? ""
        return (plan.age() ?? "Up to date") + writer
    }

    private func setLogin(_ on: Bool) {
        if Demo.isOn { launchAtLogin = on; return }   // demo: the real login item stays as it is
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private extension View {
    /// Less air above a section's title, so General's short sections stack closer.
    func tightHeader() -> some View { padding(.top, -10) }

    /// The window takes the height of the shown tab's form content. macOS 15+.
    @ViewBuilder func fitsWindow(_ tab: SettingsTab, model: AppModel, controller: AppController) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom
            } action: { _, height in
                controller.fitSettings(tab, toForm: height)
            }
        } else {
            self
        }
    }
}

/// "Pro", "Max 5x · Acme": the plan, in a small mint capsule.
private struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(PacelineMark.mint.opacity(0.18)))
            .accessibilityLabel("Plan \(text)")
    }
}

/// Glass look, live: every change shows on the open drop-down right away.
/// A small slice of the panel in the chosen glass, so changes show here too.
private struct GlassPreview: View {
    let appearance: GlassAppearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: appearance.radius(14), style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(nsImage: PacelineMark.template(width: 13)).renderingMode(.template).foregroundStyle(.secondary)
                Text("AI Usage").font(.system(size: 11, weight: .semibold))
            }
            HStack(spacing: 6) {
                Text("5h").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                Capsule().fill(.white.opacity(0.08)).overlay(alignment: .leading) {
                    GeometryReader { geo in Capsule().fill(Color(hex: 0x32D74B)).frame(width: geo.size.width * 0.62) }
                }
                .frame(height: 4)
                Text("62%").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color(hex: 0x32D74B))
            }
        }
        .padding(10)
        .frame(width: 180, height: 58, alignment: .topLeading)
        .background(GlassSurface(appearance: appearance, radius: appearance.radius(14)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.13), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

private struct AppearanceSection: View {
    @Binding var appearance: GlassAppearance

    var body: some View {
        Section {
            LabeledContent("Preview") { GlassPreview(appearance: appearance) }
            Picker("Material", selection: $appearance.material) {
                ForEach(GlassAppearance.Material.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if appearance.material == .liquid && !GlassAppearance.liquidAvailable {
                Text("Liquid Glass needs macOS 26 or later; Frosted is used here.").font(.caption).foregroundStyle(.secondary)
            }
            if appearance.material == .liquid {
                Toggle("Clear glass (more see-through)", isOn: $appearance.clear)
            }
            LabeledContent("Tint") {
                HStack(spacing: 6) {
                    ForEach(GlassAppearance.Tint.allCases, id: \.self) { tint in
                        Button { appearance.tint = tint } label: {
                            Circle()
                                .fill(tint.color.map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.25))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.primary.opacity(appearance.tint == tint ? 0.9 : 0), lineWidth: 2))
                                .overlay { if tint == .none { Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(.secondary) } }
                        }
                        .buttonStyle(.plain)
                        .help(tint.label)
                        .accessibilityLabel("Tint: \(tint.label)")
                        .accessibilityAddTraits(appearance.tint == tint ? .isSelected : [])
                    }
                }
            }
            if appearance.tint != .none {
                slider("Tint strength", value: $appearance.tintStrength, in: 0.05...1)
            }
            slider("Darkness", value: $appearance.dim, in: 0...0.6)
            slider("Roundness", value: $appearance.roundness, in: 0...1)
            HStack {
                Text("Darker reads better over bright wallpapers.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { appearance = .standard }.disabled(appearance == .standard)
            }
        } header: { Label("Panel Background", systemImage: "paintbrush") }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 180)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
        }
    }
}
