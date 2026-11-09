import AppKit
import SwiftUI

/// Owns the menu bar icon, its drop-down and every usage source, and turns
/// their updates into model changes.
@MainActor
final class AppController {
    let model = AppModel()
    private lazy var settingsWindow = AppWindow(title: "Paceline Settings", size: NSSize(width: 500, height: 520)) { [unowned self] in
        SettingsView(model: self.model, controller: self)
    }

    private var panel: FloatingPanel!
    private var tokenMonitor: TokenMonitor?
    /// Extra Claude accounts' monitors, by id, with the folder each reads.
    private var accountMonitors: [String: (root: URL, monitor: TokenMonitor)] = [:]
    private var sourcesMonitor: SourcesMonitor?
    private var planTimer: Timer?
    private var suggestionTimer: Timer?
    private var checkingSuggestions = false
    private var signInWatches: [String: Task<Void, Never>] = [:]
    private let statusItem = StatusItemController()
    private var outsideClickMonitor: Any?

    static let panelSize = NSSize(width: 320, height: 440)

    // MARK: - Lifecycle

    func start() {
        panel = FloatingPanel(size: Self.panelSize)
        panel.onCancel = { [weak self] in self?.closePanel() }

        model.history = UsageHistory.load().migrated(accounts: model.claudeAccounts)
        if Demo.isOn {
            // Made-up usage; no logs are watched.
            model.usage = Demo.usage
            model.accountUsage = Demo.accountUsage
            model.otherUsage = Demo.otherUsage()
            model.claudeLastActive = Date()
        } else {
            let monitor = TokenMonitor { [weak self] snapshot, latestWrite in
                Task { @MainActor in self?.usageUpdated(snapshot, latestWrite) }
            }
            monitor.start()
            tokenMonitor = monitor
            syncAccountMonitors()

            let sources = SourcesMonitor { [weak self] usage in
                Task { @MainActor in self?.otherUsageUpdated(usage) }
            }
            sources.start()
            sourcesMonitor = sources
        }

        // Plan files are tiny and change at most once per Claude Code turn.
        refreshPlans()
        planTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlans() }
        }

        // Who's signed in, what's found: at launch, on opening the panel or Refresh, and every 10 minutes.
        refreshSuggestions()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSuggestions() }
        }

        statusItem.onClick = { [weak self] in self?.togglePanel() }
        statusItem.makeMenu = { [weak self] in self?.statusMenu() ?? NSMenu() }
        statusItem.setVisible(true)
        applySharing()
        updateStatusItem()

        if model.debugEndpoints { listenForDebugCommands() }
    }

    func stop() {
        tokenMonitor?.stop()
        accountMonitors.values.forEach { $0.monitor.stop() }
        sourcesMonitor?.stop()
        FreshLimits.stopAll()
        model.history.save()
    }

    // MARK: - History

    private var historySaved = Date.distantPast

    /// Today's figures go into the history as they change; the file is written
    /// at most every 5 minutes (and on quit).
    private func recordHistory() {
        let updated = model.history.recording(usage: model.usageByAI, unpriced: model.unpricedByAI, plans: model.plans, accounts: model.claudeAccounts)
        if updated != model.history { model.history = updated }
        if Date().timeIntervalSince(historySaved) >= 300 {
            historySaved = Date()
            updated.save()
        }
    }

    // MARK: - Drop-down

    var panelOpen: Bool { panel.isVisible }

    func togglePanel() {
        if panelOpen { closePanel() } else { openPanel() }
    }

    /// The SwiftUI view exists only while the drop-down shows, so a closed
    /// drop-down costs nothing when usage updates arrive.
    private func openPanel() {
        refreshSuggestions()
        fetchFreshIfDue()
        panel.contentView = FirstMouseHostingView(rootView: UsagePanelView(model: model, controller: self))
        panel.setFrame(panelFrame(), display: true)
        panel.orderFrontRegardless()
        // A click in any other app closes it, like a menu. Clicks on our own
        // windows (and the icon, which toggles) aren't global events.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    func closePanel() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        guard panelOpen else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// Hangs below the icon, kept on screen.
    private func panelFrame() -> NSRect {
        let size = Self.panelSize
        let screen = statusItem.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        guard let icon = statusItem.buttonFrame else {
            return NSRect(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 6, width: size.width, height: size.height)
        }
        let x = min(max(icon.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(x: x, y: icon.minY - 6 - size.height, width: size.width, height: size.height)
    }

    // MARK: - Menu bar

    /// Right click: each AI's numbers (not clickable), then the menu bar options.
    func statusMenu() -> NSMenu {
        let menu = NSMenu()
        let ais = model.aiReadings
        for line in AIReading.tooltip(ais).split(separator: "\n") {
            let item = NSMenuItem(title: String(line), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !ais.isEmpty { menu.addItem(.separator()) }
        // One submenu for the menu bar: what it shows, then its style.
        let menuBar = NSMenu()
        for shows in MenuBarShows.allCases {
            menuBar.addItem(ClosureMenuItem(shows.label, checked: model.menuBarShows == shows) { [weak self] in self?.setMenuBarShows(shows) })
        }
        menuBar.addItem(.separator())
        for style in MenuBarStyle.allCases {
            menuBar.addItem(ClosureMenuItem(style.label, checked: model.menuBarStyle == style) { [weak self] in self?.setMenuBarStyle(style) })
        }
        let menuBarItem = NSMenuItem(title: "Menu Bar", action: nil, keyEquivalent: "")
        menuBarItem.submenu = menuBar
        menu.addItem(menuBarItem)
        menu.addItem(ClosureMenuItem("Show Tokens Instead of $", checked: !model.showUSD) { [weak self] in self?.toggleUnits() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Check for Updates…") { Updates.check() })
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { [weak self] in self?.showSettings() })
        menu.addItem(ClosureMenuItem("Quit Paceline", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    /// Every AI's reading, or only the latest one's (Settings → Menu bar shows),
    /// each behind its logo.
    private func updateStatusItem() {
        let readings = model.aiReadings
        let shown = AIReading.shown(readings, shows: model.menuBarShows).filter { debugOnly?.contains($0.name) ?? true }
        let segments = shown.map { reading in
            let icon = AILogos.menuBarIcon(for: reading.name, badge: reading.badge)
            return StatusItemController.Segment(icon: icon, label: nil, text: reading.text, low: reading.low || reading.rows.first?.runsOut != nil,
                                               rows: reading.rows, stale: reading.staleNote != nil)
        }
        let tooltip = AIReading.tooltip(readings)
        statusItem.update(segments: segments, warning: shown.contains(where: \.low),
                          tooltip: tooltip.isEmpty ? nil : tooltip, spoken: readings.isEmpty ? nil : AIReading.spoken(readings),
                          style: model.menuBarStyle)
    }

    func setMenuBarStyle(_ style: MenuBarStyle) {
        model.menuBarStyle = style
        updateStatusItem()
    }

    func setMenuBarShows(_ shows: MenuBarShows) {
        model.menuBarShows = shows
        updateStatusItem()
    }

    /// Settings → General → Order: the menu bar follows at once, the panel by itself.
    func setAIOrder(_ order: [String]) {
        model.aiOrder = order
        updateStatusItem()
    }

    func toggleUnits() {
        model.showUSD.toggle()
        updateStatusItem()
    }

    func setHideFromScreenSharing(_ on: Bool) {
        model.hideFromScreenSharing = on
        applySharing()
    }

    /// `.none` keeps the drop-down (project names, spend) and Settings (account emails) out of screenshots,
    /// recordings and screen sharing that use the window server.
    private func applySharing() {
        panel.sharingType = model.hideFromScreenSharing ? .none : .readOnly
        settingsWindow.sharingType = panel.sharingType
    }

    func showSettings(_ tab: SettingsTab? = nil) {
        if let tab { model.settingsTab = tab }
        closePanel()
        settingsWindow.show()
    }

    /// Each Settings tab's form height, last reported: switching back to a tab
    /// reports nothing new, so its height is kept here.
    private var settingsFormHeights: [SettingsTab: CGFloat] = [:]

    /// Settings fits the shown tab's content (macOS 15 and later).
    func fitSettings(_ tab: SettingsTab, toForm height: CGFloat? = nil) {
        if let height { settingsFormHeights[tab] = height }
        guard tab == model.settingsTab, let formHeight = settingsFormHeights[tab] else { return }
        settingsWindow.fitContent(toForm: formHeight)
    }

    func copyString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Usage

    private func usageUpdated(_ snapshot: UsageSnapshot, _ latestWrite: Date?) {
        model.usage = snapshot
        if let latestWrite { model.claudeLastActive = max(model.claudeLastActive ?? latestWrite, latestWrite) }
        updateStatusItem()
    }

    /// Each listed extra account's transcripts, read like the main account's:
    /// a monitor starts for an account added, stops for one removed. A folder
    /// another account already reads (symlinks followed) isn't read twice.
    private func syncAccountMonitors() {
        guard !Demo.isOn else { return }
        let wanted = Dictionary(uniqueKeysWithValues: TokenMonitor.roots(accounts: model.claudeAccounts).filter { $0.id != TokenMonitor.mainID }.map { ($0.id, $0.root) })
        for (id, running) in accountMonitors where wanted[id] != running.root {
            running.monitor.stop()
            accountMonitors[id] = nil
            model.accountUsage[id] = nil
            model.accountLastActive[id] = nil
        }
        for (id, root) in wanted where accountMonitors[id] == nil {
            let monitor = TokenMonitor(root: root) { [weak self] snapshot, latestWrite in
                Task { @MainActor in self?.accountUsageUpdated(id, root: root, snapshot, latestWrite) }
            }
            accountMonitors[id] = (root, monitor)
            monitor.start()
        }
    }

    private func accountUsageUpdated(_ id: String, root: URL, _ snapshot: UsageSnapshot, _ latestWrite: Date?) {
        // A pass that finished as its account was removed (or moved) is dropped.
        guard accountMonitors[id]?.root == root else { return }
        model.accountUsage[id] = snapshot
        if let latestWrite { model.accountLastActive[id] = max(model.accountLastActive[id] ?? latestWrite, latestWrite) }
        updateStatusItem()
    }

    /// `--debug plans none` reads no plan files, to see the empty state; `--debug plans files` undoes it.
    private var ignorePlanFiles = false
    /// `--debug only Claude,Work`: the menu bar shows just these AIs, for screenshots; "all" ends it. Never saved.
    private var debugOnly: Set<String>?

    private var readingPlans = false
    private var plansAgain = false

    /// Read off the main thread: Codex's are the tail of its newest logs and
    /// Windsurf's a SQLite row, too slow for every 15 s on the main thread.
    /// A call while a read is going reads once more after it.
    private func refreshPlans() {
        guard !readingPlans else { plansAgain = true; return }
        readingPlans = true
        let ignore = ignorePlanFiles, accounts = model.claudeAccounts
        Task {
            let plans = ignore ? [] : await Task.detached(priority: .utility) { PlanUsageReader.all(accounts: accounts) }.value
            readingPlans = false
            if plans != model.plans { model.plans = plans }
            updateStatusItem()
            notifyIfDue()
            fetchFreshIfDue()
            recordHistory()
            if plansAgain {
                plansAgain = false
                refreshPlans()
            }
        }
    }

    // MARK: - Fetch fresh numbers (opt-in)

    private var lastAsked: [String: Date] = [:]
    private var fetching = false
    private var fetchStarted = Date.distantPast

    /// Plans over 15 minutes old (or missing) are asked of the AIs' own
    /// commands, each at most every 15 minutes; checked with the plans and on
    /// opening the panel.
    private func fetchFreshIfDue() {
        // Each command has a 25 s limit; a round still going after 5 minutes is
        // stuck (something kept its output open) and mustn't stop fetching for good.
        if fetching, Date().timeIntervalSince(fetchStarted) > 300 { fetching = false }
        guard model.fetchFresh, !Demo.isOn, !fetching else { return }
        var targets: [FreshLimits.Target] = []
        if FreshLimits.claudeCommand != nil {
            targets.append(.init(id: "claude", kind: .claude(configDir: nil), at: model.claudePlan?.at))
            targets += model.claudeAccounts.map { account in
                .init(id: account.id, kind: .claude(configDir: account.configDir), at: model.plans.first { $0.agent == account.name }?.at)
            }
        }
        if FreshLimits.agyCommand != nil {
            targets.append(.init(id: "antigravity", kind: .antigravity, at: model.plans.filter { $0.agent == "Antigravity" }.map(\.at).max()))
        }
        let due = FreshLimits.due(targets, lastAsked: lastAsked)
        guard !due.isEmpty else { return }
        let now = Date()
        due.forEach { lastAsked[$0.id] = now }
        fetching = true
        fetchStarted = now
        Task {
            await Task.detached(priority: .utility) { due.forEach(FreshLimits.fetch) }.value
            fetching = false
            refreshPlans()
        }
    }

    func setFetchFresh(_ on: Bool) {
        model.fetchFresh = on
        if on { fetchFreshIfDue() }
    }

    /// Plan alerts, when they're on: what's due is posted and remembered, so a
    /// relaunch doesn't say it again.
    private func notifyIfDue() {
        guard model.notify else { return }
        let said = Set(Demo.defaults.stringArray(forKey: "sentAlerts") ?? [])
        let (alerts, sent) = PlanAlerts.due(model.plans, sent: said)
        if sent != said { Demo.defaults.set(sent.sorted(), forKey: "sentAlerts") }
        alerts.forEach(Notifier.post)
    }

    /// Extra Claude accounts: kept in UserDefaults, read again by the plans.
    func addClaudeAccount(_ account: ClaudeAccount) {
        guard !model.claudeAccounts.contains(where: { $0.id == account.id }) else { return }
        model.claudeAccounts.append(account)
        ClaudeAccounts.save(model.claudeAccounts)
        syncAccountMonitors()
        refreshPlans()
    }

    /// Only Paceline's list: the account's folder and files stay as they are.
    func removeClaudeAccount(_ id: String) {
        model.claudeAccounts.removeAll { $0.id == id }
        ClaudeAccounts.save(model.claudeAccounts)
        model.aiOrder.removeAll { $0 == UsageHistory.key(account: id) }
        syncAccountMonitors()
        refreshPlans()
    }

    // MARK: - Suggestions

    /// Reads sign-ins (runs `codex login status`) and looks for Claude folders, off the main thread.
    func refreshSuggestions() {
        guard !checkingSuggestions else { return }
        checkingSuggestions = true
        let listed = model.claudeAccounts
        Task {
            let (accounts, found) = await Task.detached { (AccountsReader.all(), Suggestions.foundClaude(listed: listed)) }.value
            applySuggestions(Suggestions.make(accounts: accounts, found: found, listed: listed))
            checkingSuggestions = false
        }
    }

    private func applySuggestions(_ all: [Suggestion]) {
        let said = Set(Demo.defaults.stringArray(forKey: "dismissedSuggestions") ?? [])
        let (shown, kept) = Suggestions.visible(all, dismissed: said)
        if kept != said { Demo.defaults.set(kept.sorted(), forKey: "dismissedSuggestions") }
        if all != model.suggestions { model.suggestions = all }
        if shown != model.shownSuggestions { model.shownSuggestions = shown }
    }

    /// The panel card's ×: these stay hidden until their state changes.
    func dismissSuggestions() {
        let said = Set(Demo.defaults.stringArray(forKey: "dismissedSuggestions") ?? [])
        Demo.defaults.set(said.union(model.shownSuggestions.map(\.id)).sorted(), forKey: "dismissedSuggestions")
        model.shownSuggestions = []
    }

    /// Sign in…: Terminal runs the AI's own login (SignIn.swift); the user signs in there.
    func signIn(_ suggestion: Suggestion) {
        guard case .signIn(let command) = suggestion.action else { return }
        guard SignInLauncher.launch(command, agent: suggestion.agent) else { NSSound.beep(); return }
        watchSignIn(suggestion.agent)
    }

    func openApp(_ bundleID: String, for agent: String? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        if let agent { watchSignIn(agent) }
    }

    /// Install in Terminal…: the maker's installer, run only once Return is pressed there.
    func install(_ agent: String, command: String) {
        guard Install.launch(command, agent: agent) else { NSSound.beep(); return }
        watchInstall(agent)
    }

    /// Installs take longer: every 3 s for 10 minutes, is it there yet? Then Settings
    /// reads it again, and its row turns to Sign in… or ✓.
    func watchInstall(_ agent: String) {
        watchSignIn(agent, for: 600) { $0.map { $0.status != "Not installed" } ?? false }
    }

    /// Like the Add account guide: every 3 s for 3 minutes, is it signed in yet?
    /// Reads only. When it is, the suggestion goes and a ✓ shows for a while.
    private func watchSignIn(_ agent: String, for seconds: TimeInterval = 180,
                             until done: @escaping @Sendable (AccountInfo?) -> Bool = { $0?.isSignedIn == true }) {
        signInWatches[agent]?.cancel()
        model.signInWaiting.insert(agent)
        signInWatches[agent] = Task { [weak self] in
            let deadline = Date().addingTimeInterval(seconds)
            var found: AccountInfo?
            var signedIn = false
            while !Task.isCancelled, !signedIn, Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                guard let listed = self?.model.claudeAccounts else { return }
                found = await Task.detached { AccountsReader.one(agent, listed: listed) }.value
                signedIn = done(found)
            }
            guard let self, !Task.isCancelled else { return }
            model.signInWaiting.remove(agent)
            signInWatches[agent] = nil
            guard signedIn else { return }
            model.signInsChanged += 1
            refreshSuggestions()
            guard found?.isSignedIn == true else { return }   // installed, not signed in yet: Settings shows its Sign in…
            model.signInDone.insert(agent)
            try? await Task.sleep(for: .seconds(30))
            model.signInDone.remove(agent)
        }
    }

    /// A found folder: Settings asks for its name, then it's listed.
    func addFound(_ suggestion: Suggestion) {
        showSettings(.accounts)
        model.pendingFound = suggestion
    }

    func confirmFound(_ suggestion: Suggestion, name: String) {
        guard case .addAccount(let dir, _) = suggestion.action else { return }
        let usable = ClaudeAccounts.usableName(name, dir: dir, existing: model.claudeAccounts)
        addClaudeAccount(ClaudeAccount(id: ClaudeAccounts.newID(for: usable, existing: model.claudeAccounts),
                                       name: usable, configDir: dir))
        refreshSuggestions()
    }

    /// Turning alerts on is when permission is asked, not at launch.
    func setNotify(_ on: Bool) {
        model.notify = on
        if on {
            Notifier.requestPermission()
            notifyIfDue()
        }
    }

    private func otherUsageUpdated(_ usage: [SourceUsage]) {
        model.otherUsage = usage
        updateStatusItem()
    }

    // MARK: - Debug hooks (defaults write com.josakcat.paceline debugEndpoints -bool true)

    /// `Paceline --debug <open|close|settings [general|accounts|appearance]|snapshot|scroll-end|shows|style [compact|tworows]|plans [none|files]|notify-test|add-account [1|2|3]|signin <ai>|details <ai>|group <g>:<open|fold>> [value]` from a
    /// terminal posts these; nothing listens unless debugEndpoints is on.
    static let debugNotification = Notification.Name("com.josakcat.paceline.debug")

    private func listenForDebugCommands() {
        DistributedNotificationCenter.default().addObserver(forName: Self.debugNotification, object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            let value = note.userInfo?["value"] as? String
            MainActor.assumeIsolated { self?.debug(command, value) }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private static func overBackground(_ rep: NSBitmapImageRep, appearance: NSAppearance) -> Data? {
        let size = rep.size
        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                // A rep's plain draw(in:) copies, clearing what's under it.
                rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
            return true
        }
        return png(image, scale: CGFloat(rep.pixelsWide) / max(size.width, 1))
    }

    private static func png(_ image: NSImage, scale: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func debug(_ command: String, _ value: String?) {
        switch command {
        case "open": if !panelOpen { openPanel() }
        case "close": closePanel(); model.addAccountStep = nil; model.installGuide = nil; model.accountDetails = nil; settingsWindow.close()
        case "settings":
            showSettings(SettingsTab(rawValue: value ?? ""))
        case "shows": if let shows = MenuBarShows(rawValue: value ?? "") { setMenuBarShows(shows) }
        case "only":
            debugOnly = value == "all" ? nil : Set((value ?? "").split(separator: ",").map(String.init))
            updateStatusItem()
        case "plans": ignorePlanFiles = value == "none"; refreshPlans()
        case "add-account":
            // Opens the guide at a step with a sample name; nothing is saved unless Done is pressed.
            showSettings(.accounts)
            model.addAccountSample = model.claudeAccounts.contains { $0.name == "Work" } ? "Team" : "Work"
            model.addAccountStep = Int(value ?? "") ?? 1
        case "account-add":
            // "Name|/folder": what the guide's last step does, without the clicks (the name is checked the same way).
            let parts = (value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, ClaudeAccounts.nameProblem(parts[0], existing: model.claudeAccounts) == nil,
                  ClaudeAccounts.folderProblem(parts[1], existing: model.claudeAccounts) == nil else { NSSound.beep(); return }
            addClaudeAccount(ClaudeAccount(id: ClaudeAccounts.newID(for: parts[0], existing: model.claudeAccounts),
                                           name: parts[0], configDir: ClaudeAccounts.standardized(parts[1])))
        case "account-remove": removeClaudeAccount(value ?? "")
        case "signin":
            // Presses an AI's Sign in… (its own login in Terminal), signed in or not: "codex", "work".
            let name = (value ?? "").lowercased()
            if let extra = model.claudeAccounts.first(where: { $0.name.lowercased() == name || $0.id == name }) {
                signIn(Suggestion(agent: extra.name, title: "", detail: "", action: .signIn(.init("claude auth login", configDir: extra.configDir))))
            } else if let provider = Providers.all.first(where: { $0.name.lowercased() == name || $0.short.lowercased() == name }),
                      let fix = provider.fixes.values.first(where: { if case .signIn = $0.action { true } else { false } }) {
                signIn(Suggestion(agent: provider.name, title: "", detail: "", action: fix.action))
            } else { NSSound.beep() }
        case "install":
            // Opens an AI's Install… guide in Settings → Accounts; nothing is run: "amp", "opencode".
            let name = (value ?? "").lowercased()
            guard let provider = Providers.all.first(where: { ($0.name.lowercased() == name || $0.short.lowercased() == name) && $0.install != nil })
            else { NSSound.beep(); return }
            showSettings(.accounts)
            model.installGuide = provider.name
        case "details":
            // Opens an AI's ⓘ popover in Settings → Accounts: "claude", "work", "codex"; "none" closes it.
            let name = (value ?? "").lowercased()
            showSettings(.accounts)
            model.accountDetails = name == "none" ? nil
                : model.claudeAccounts.first { $0.name.lowercased() == name || $0.id == name }?.name
                ?? Providers.all.first { $0.name.lowercased() == name || $0.short.lowercased() == name }?.name
        case "group":
            // "notinstalled:open", "ready:fold": Settings → Accounts' groups, as their headers would.
            let parts = (value ?? "").split(separator: ":").map(String.init)
            let keys = ["ready": "accountsOpenReady", "needs": "accountsOpenNeedsSignIn", "notinstalled": "accountsShowNotInstalled"]
            guard parts.count == 2, let key = keys[parts[0]] else { NSSound.beep(); return }
            Demo.defaults.set(parts[1] == "open", forKey: key)
        case "notify-test":
            Notifier.post(PlanAlerts.Alert(id: "test-\(UUID().uuidString)", title: "Paceline",
                                           body: "A test: plan alerts look like this."))
        case "order":
            // "Work,Claude": those keys first, the rest after; "reset" for the built-in order;
            // "open"/"fold" Settings' list.
            switch value {
            case "open", "fold": model.orderExpanded = value == "open"
            case "reset": setAIOrder([])
            default: setAIOrder((value ?? "").split(separator: ",").map(String.init))
            }
        case "style": if let style = MenuBarStyle(rawValue: value ?? "") { setMenuBarStyle(style) }
        case "scroll-end":
            // Scrolls the panel and Settings to the bottom, to snapshot what's below the fold.
            for root in [panel.contentView, settingsWindow.contentView].compactMap({ $0 }) {
                for scroll in Self.scrollViews(in: root) {
                    if let doc = scroll.documentView { doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.maxY : 0)) }
                }
            }
        case "scroll":
            // "0.5": the panel and Settings part way down (0 top, 1 bottom), for what's mid-way.
            let f = min(max(Double(value ?? "") ?? 0, 0), 1)
            for root in [panel.contentView, settingsWindow.contentView].compactMap({ $0 }) {
                for scroll in Self.scrollViews(in: root) {
                    guard let doc = scroll.documentView else { continue }
                    let room = max(doc.bounds.height - scroll.contentView.bounds.height, 0)
                    doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? room * f : room * (1 - f)))
                }
            }
        case "snapshot":
            // Renders our own windows (no Screen Recording permission needed); the glass renders flat.
            let dir = URL(fileURLWithPath: value ?? NSTemporaryDirectory())
            for (name, view) in [("panel", panelOpen ? panel.contentView : nil), ("settings", settingsWindow.contentView),
                                 ("sheet", settingsWindow.sheetView), ("menubar", statusItem.buttonView),
                                 ("popover", NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }?.contentView)] {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                // Windows over their own background (a sheet's or popover's is otherwise clear);
                // the panel keeps its rounded corners.
                if name != "panel" && name != "menubar", let filled = Self.overBackground(rep, appearance: view.effectiveAppearance) {
                    try? filled.write(to: dir.appendingPathComponent("\(name).png"))
                } else {
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                }
            }
            // The menu bar's own view draws on nothing: its reading on a light and a dark bar.
            for dark in [false, true] {
                guard let image = statusItem.preview(dark: dark), let png = Self.png(image, scale: 2) else { continue }
                try? png.write(to: dir.appendingPathComponent(dark ? "menubar-dark.png" : "menubar-light.png"))
            }
        default: break
        }
    }
}
