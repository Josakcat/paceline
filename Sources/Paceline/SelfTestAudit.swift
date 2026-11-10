import AppKit

extension SelfTest {
    /// Regression checks for the bugs found in the 2026-11-08 audit (docs/bug-audit-2026-11-08.md).
    static func auditTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  audit: \(what)")
        }
        let now = Date(), dayStart = Calendar.current.startOfDay(for: now)
        let todayMS = Int(max(now.addingTimeInterval(-60), dayStart).timeIntervalSince1970 * 1000)

        // #F13: absurd numbers in another app's file are capped, not a crash.
        let huge = #"{"id":"x","type":"assistant","model":{"id":"m"},"cost":1e300,"tokens":{"input":1e20,"output":-5,"reasoning":1e300,"cache":{"read":1e19,"write":0}},"time":{"created":\#(todayMS)}}"#
        let counts = OpenCodeLog.message(Data(huge.utf8), since: dayStart)?.counts
        check(counts?.input == 1_000_000_000_000 && counts?.output == 1_000_000_000_000 && counts?.cacheRead == 1_000_000_000_000, "huge, negative and infinite token counts are capped (OpenCode)")
        let saved: [String: Any] = ["saved_at": now.timeIntervalSince1970, "five_hour": ["used": 1e20], "seven_day": ["used": -3]]
        let plan = PlanUsageReader.claude(saved, agent: "Claude", now: now)
        check(plan?.window("5h")?.left == 0 && plan?.window("Week")?.left == 100, "a plan file with used 1e20 or -3 → 0% and 100% left")
        check(Int(count: UInt64.max) == 1_000_000_000_000 && Int(count: Double.nan) == 0 && Int(percent: .infinity) == 0,
              "UInt64 varints and NaN are safe")

        // #F1: just after midnight, yesterday's totals (still in the monitors) aren't recorded as today's.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!
        var stale = UsageSnapshot(totalTokens: 5_000_000, totalUSD: 12.5, day: yesterday)
        var other = SourceUsage(source: "Codex", accuracy: .exact, byModel: ["gpt-5.5": TokenCounts(input: 100, messages: 1)])
        other.day = yesterday
        let atMidnight = dayStart.addingTimeInterval(5)
        let byAI = AppModel.usageByAI(usage: stale, other: [other], now: atMidnight)
        let recorded = UsageHistory().recording(usage: byAI, plans: [], now: atMidnight)
        check(byAI.isEmpty && recorded.days[UsageHistory.key(atMidnight)] == nil, "00:00:05 with yesterday's snapshot: nothing recorded for today")
        stale.day = dayStart
        other.day = dayStart
        check(AppModel.usageByAI(usage: stale, other: [other], now: atMidnight).keys.sorted() == ["Claude", "Codex"], "today's snapshots are recorded")

        // #F3: a window at 0% has run out; it isn't "running out in 1m", and no runs-out alert follows.
        let empty = PlanWindow(label: "5h", left: 0, resets: now.addingTimeInterval(2 * 3600))
        let emptyPlan = PlanUsage(agent: "Claude", windows: [empty], at: now)
        check(empty.pace(now: now) == nil && !PlanAlerts.due([emptyPlan], sent: [], now: now).alerts.contains { $0.id.hasSuffix("runsout") },
              "0% left: no pace line, no runs-out alert (the 10% alert still says it)")
        let weekOK = PlanWindow(label: "Week", left: 60, resets: now.addingTimeInterval(2 * 86400))
        check(!PlanSection.onPace([PlanUsage(agent: "Claude", windows: [empty, weekOK], at: now)], now: now),
              "0% in one window: the header doesn't say On pace")

        // #F4: an account named with "|" still gets its reset alert, and old ids are forgotten.
        let piped = PlanUsage(agent: "Work | Team", windows: [PlanWindow(label: "5h", left: 8, resets: now.addingTimeInterval(1800))], at: now)
        let low = PlanAlerts.due([piped], sent: [], now: now)
        let resetSoon: Date = now.addingTimeInterval(1800 + 60)
        let freshWindow = PlanWindow(label: "5h", left: 100, resets: resetSoon.addingTimeInterval(5 * 3600))
        let fresh = PlanUsage(agent: "Work | Team", windows: [freshWindow], at: resetSoon)
        let after = PlanAlerts.due([fresh], sent: low.sent, now: resetSoon)
        check(after.alerts.contains { $0.title == "Work | Team: 5-hour limit reset" }, "a name with | gets its 5-hour reset alert")
        let weekLater = PlanAlerts.due([], sent: after.sent, now: now.addingTimeInterval(9 * 86400))
        check(weekLater.sent.isEmpty, "alert ids over 8 days old are dropped, | or not")

        // #F5: a reset that happened hours ago (Paceline was closed) is noted, not announced.
        let lateNow: Date = now.addingTimeInterval(1800 + 5 * 3600)
        let lowWindow = PlanWindow(label: "5h", left: 8, resets: now.addingTimeInterval(1800))
        let lowSent: Set<String> = PlanAlerts.due([PlanUsage(agent: "Claude", windows: [lowWindow], at: now)], sent: [], now: now).sent
        let fullWindow = PlanWindow(label: "5h", left: 100, resets: lateNow.addingTimeInterval(3600))
        let late = PlanAlerts.due([PlanUsage(agent: "Claude", windows: [fullWindow], at: lateNow)], sent: lowSent, now: lateNow)
        let announced: Bool = late.alerts.contains { $0.title.hasSuffix("reset") }
        let remembered: Bool = late.sent.contains { $0.hasSuffix("|reset") }
        check(!announced && remembered, "a 5-hour reset 5 hours ago isn't announced late (but is remembered)")

        // #F2: an extra account's id never takes the main account's ("claude") or a removed account's leftover file.
        let noFiles: (String) -> Bool = { _ in false }
        let mainID = ClaudeAccounts.newID(for: "Claude.", existing: [], leftover: noFiles)
        let leftID = ClaudeAccounts.newID(for: "Work", existing: [], leftover: { $0 == "work" })
        check(mainID == "claude-2" && leftID == "work-2" && ClaudeAccounts.newID(for: "Work", existing: [], leftover: noFiles) == "work",
              "ids: \"Claude.\" → \(mainID), Work with a leftover work file → \(leftID)")

        // #F6: the status line is added as one line; the rest of settings.json, a symlink and permissions stay.
        let fm = FileManager.default
        let acct = fm.temporaryDirectory.appendingPathComponent("paceline-audit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: acct) }
        try? fm.createDirectory(at: acct, withIntermediateDirectories: true)
        let settings = acct.appendingPathComponent("settings.json")
        let original = "{\n    \"zeta\": 1.0,\n    \"alpha\": \"/a/b\"\n}\n"
        try? Data(original.utf8).write(to: settings)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        let added = ClaudeAccounts.addStatusLine(command: "~/x/Paceline --statusline", toSettingsIn: acct)
        let afterAdd = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
        let parsed = (try? JSONSerialization.jsonObject(with: Data(afterAdd.utf8))) as? [String: Any]
        let mode = (try? fm.attributesOfItem(atPath: settings.path))?[.posixPermissions] as? Int
        check(added == .added && afterAdd.hasSuffix("\n    \"zeta\": 1.0,\n    \"alpha\": \"/a/b\"\n}\n") && afterAdd.contains("~/x/Paceline --statusline")
              && parsed?["zeta"] != nil && parsed?["statusLine"] != nil && mode == 0o600,
              "settings.json: one line added, key order, 1.0, slashes and 0600 kept")
        check(ClaudeAccounts.addStatusLine(command: "y", toSettingsIn: acct) == .alreadySet, "a status line that's there isn't replaced")
        let real = acct.appendingPathComponent("dotfiles.json"), linked = acct.appendingPathComponent("linked")
        try? fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: real)
        try? fm.createSymbolicLink(at: linked.appendingPathComponent("settings.json"), withDestinationURL: real)
        let viaLink = ClaudeAccounts.addStatusLine(command: "z", toSettingsIn: linked)
        let stillLink = (try? fm.destinationOfSymbolicLink(atPath: linked.appendingPathComponent("settings.json").path)) != nil
        check(viaLink == .added && stillLink && ((try? String(contentsOf: real, encoding: .utf8)) ?? "").contains("statusLine"),
              "a symlinked settings.json stays a link; the file it points to gets the line")
        let locked = acct.appendingPathComponent("locked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? Data(#"{"keep":true}"#.utf8).write(to: locked.appendingPathComponent("settings.json"))
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.appendingPathComponent("settings.json").path)
        let lockedResult = ClaudeAccounts.addStatusLine(command: "z", toSettingsIn: locked)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.appendingPathComponent("settings.json").path)
        check(lockedResult == .unreadable && ((try? String(contentsOf: locked.appendingPathComponent("settings.json"), encoding: .utf8)) ?? "") == #"{"keep":true}"#,
              "a settings.json that can't be read is left alone, not overwritten")

        // #F9: home itself, or a link to ~/.claude or to another account's folder, isn't a new account's folder.
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("paceline-home-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fakeHome) }
        try? fm.createDirectory(at: fakeHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: fakeHome.appendingPathComponent(".claude-work"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: fakeHome.appendingPathComponent("main-link"), withDestinationURL: fakeHome.appendingPathComponent(".claude"))
        try? fm.createSymbolicLink(at: fakeHome.appendingPathComponent("work-link"), withDestinationURL: fakeHome.appendingPathComponent(".claude-work"))
        let workAccount = ClaudeAccount(id: "work", name: "Work", configDir: fakeHome.appendingPathComponent(".claude-work").path)
        let h = fakeHome.path
        check(ClaudeAccounts.folderProblem(h, existing: [], home: h) != nil && ClaudeAccounts.folderProblem(h + "/", existing: [], home: h) != nil
              && ClaudeAccounts.folderProblem(h + "/main-link", existing: [], home: h) != nil
              && ClaudeAccounts.folderProblem(h + "/work-link", existing: [workAccount], home: h) != nil
              && ClaudeAccounts.folderProblem(h + "/.claude-new", existing: [workAccount], home: h) == nil,
              "folders: home, links to ~/.claude or another account's are refused; a new one is fine")

        // #F8: paths in commands to paste survive any character; the JSON for settings.json escapes \\ too.
        func shellEcho(_ word: String) -> String? {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + word]
            process.environment = ["HOME": "/home-for-test"]
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let odd = ["/h/x/My Dir/.claude-a", "/h/x/.claude-bob's", "/tmp/a$(touch nope)`b`;c", "/tmp/plain-dir"]
        check(odd.allSatisfy { shellEcho(ClaudeAccounts.shellPath($0, home: "/h/x")) == $0 || ClaudeAccounts.shellPath($0, home: "/h/x").hasPrefix("~") },
              "shell paths: spaces, ' , $( ) and backticks come back unchanged")
        check(ClaudeAccounts.shellPath("/h/x/.claude-work", home: "/h/x") == "~/.claude-work", "a plain path under home stays ~/…")
        let body = "CLAUDE_CONFIG_DIR=" + ClaudeAccounts.shellPath("/tmp/it's here") + " claude"
        check(shellEcho(ClaudeAccounts.shellQuote(body)) == body, "the alias body quotes whole, even with ' inside")
        let json = "{" + PlanUsageReader.statusLineJSON(command: #"'/Apps/A\B "Q"/Paceline' --statusline"#) + "}"
        let decoded = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?["statusLine"] as? [String: Any]
        check(decoded?["command"] as? String == #"'/Apps/A\B "Q"/Paceline' --statusline"#, "statusLine JSON: quotes and backslashes escaped")

        // #F12: a found folder's name is checked again when it's added.
        let listed = [ClaudeAccount(id: "work", name: "Work", configDir: "/tmp/w")]
        check(ClaudeAccounts.usableName("  ", dir: "/x/.claude-team", existing: listed) == "Team"
              && ClaudeAccounts.usableName("Work", dir: "/x/.claude-work", existing: listed) == "Work 2"
              && ClaudeAccounts.usableName("Codex", dir: "/x/.claude-codex", existing: []) == "Codex 2"
              && ClaudeAccounts.usableName("Lab", dir: "/x/.claude-lab", existing: listed) == "Lab",
              "found folder names: empty or taken fall back to the folder's, numbered")

        // #F14: the same tasks folder found twice is read once.
        let shared = fm.temporaryDirectory.appendingPathComponent("paceline-roo-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: shared) }
        let rooAgent = VSCodeAgents.Agent(name: "Roo Code", extensionID: "rooveterinaryinc.roo-cline", short: "RC", color: 0)
        check(VSCodeAgentSource(agent: rooAgent, folders: [shared, shared.appendingPathComponent("."), shared]).folders.count == 1,
              "Roo Code: one custom folder named by two editors is read once")

        // #F15: an Antigravity conversation written today only into its -wal still counts as today's.
        let wal = fm.temporaryDirectory.appendingPathComponent("paceline-ag-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: wal) }
        try? fm.createDirectory(at: wal, withIntermediateDirectories: true)
        let db = wal.appendingPathComponent("c.db")
        try? Data().write(to: db)
        try? Data().write(to: URL(fileURLWithPath: db.path + "-wal"))
        try? fm.setAttributes([.modificationDate: dayStart.addingTimeInterval(-86400)], ofItemAtPath: db.path)
        check(AntigravitySource.modified(db) >= dayStart, "Antigravity: the -wal's date counts")

        // #F17: a plan Paceline fetched just now doesn't make that AI the "latest used"; one saved by use does.
        let model = AppModel()
        var fetchedPlan = PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 70, resets: now.addingTimeInterval(3600))], at: now)
        fetchedPlan.fetched = true
        model.plans = [fetchedPlan]
        var codexToday = SourceUsage(source: "Codex", accuracy: .exact, byModel: ["gpt-5.5": TokenCounts(input: 10, messages: 1)])
        codexToday.lastActivity = now.addingTimeInterval(-600)
        model.otherUsage = [codexToday]
        model.claudeLastActive = now.addingTimeInterval(-3 * 3600)
        let latestName = AIReading.shown(model.aiReadings, shows: .latest).first?.name
        check(latestName == "Codex", "latest used: Codex used 10 min ago beats Claude's fetched-just-now plan → \(latestName ?? "none")")
        check(PlanUsageReader.claude(["saved_at": now.timeIntervalSince1970, "five_hour": ["used": 10], "fetched": true], agent: "Claude", now: now)?.fetched == true
              && PlanUsageReader.merged(["five_hour": ["used": 5]], into: ["fetched": true, "seven_day": ["used": 1]])["fetched"] == nil,
              "fetched is read back, and a later save by use (status line) clears it")

        // #F21: a pre-release isn't newer than its release; a prefix before the version is skipped.
        check(!Updates.isNewer("v1.0.0-beta.2", than: "1.0.0") && Updates.isNewer("1.0.0", than: "1.0.0-beta.2")
              && Updates.isNewer("paceline-v1.2", than: "1.1.9") && Updates.isNewer("v0.1.10", than: "0.1.9") && !Updates.isNewer("v0.1.0", than: "0.1.0"),
              "update check: pre-releases, prefixes and 0.1.10 > 0.1.9")

        // #F23: older Claude model ids read the right way round.
        check(Pricing.displayName("claude-3-5-sonnet-20241022") == "Sonnet 3.5" && Pricing.displayName("claude-opus-5-5") == "Opus 5.5"
              && Pricing.displayName("claude-3-haiku-20240307") == "Haiku 3", "model names: \(Pricing.displayName("claude-3-5-sonnet-20241022"))")

        // Fable/Mythos 5.2 is checked before 5.1 and 5, so it gets its own price.
        func priced(_ m: String) -> String { Pricing.price(for: m).map { "\($0.input)/\($0.output)/\($0.cacheRead)" } ?? "nil" }
        check(priced("claude-fable-5-2") == "8.0/40.0/0.2" && priced("claude-mythos-5-2") == "8.0/40.0/0.2"
              && priced("claude-fable-5-1") == "10.0/50.0/0.25" && priced("claude-fable-5") == "10.0/50.0/1.0"
              && Pricing.displayName("claude-fable-5-2") == "Fable 5.2",
              "Fable prices: \(priced("claude-fable-5-2")), \(priced("claude-fable-5-1")), \(priced("claude-fable-5"))")

        // #F7: a command that ignores SIGTERM is killed after its time limit, not waited on forever.
        let started = Date()
        let output = FreshLimits.run("/bin/sh", ["-c", "trap '' TERM; echo started; sleep 4"], timeout: 1)
        let took = Date().timeIntervalSince(started)
        check(output == nil && took < 8, "a command (or its child) holding its output past the limit doesn't hold Paceline (\(String(format: "%.1f", took)) s)")
        return failures
    }
}
