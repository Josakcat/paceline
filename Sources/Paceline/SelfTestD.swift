import AppKit
import SQLite3

extension SelfTest {
    /// Gemini CLI, Amp, Cline / Roo Code / Kilo Code, Copilot, Windsurf, Kiro and
    /// the provider table, on made-up files in a temporary folder. Secrets are
    /// planted next to what's read, and must never come out (or be queried).
    static func roundDTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  round D: \(what)")
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("paceline-d-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        func write(_ path: String, _ text: String) {
            let url = dir.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        func database(_ path: String, _ statements: [String]) {
            let url = dir.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            for sql in statements { sqlite3_exec(db, sql, nil, nil, nil) }
        }
        let now = Date(), dayStart = Calendar.current.startOfDay(for: now)
        let todayDate = max(now.addingTimeInterval(-60), dayStart)
        let iso = ISO8601DateFormatter()
        let today = iso.string(from: todayDate), yesterday = iso.string(from: dayStart.addingTimeInterval(-3600))
        let todayMS = Int(todayDate.timeIntervalSince1970 * 1000), yesterdayMS = Int(dayStart.timeIntervalSince1970 * 1000) - 3_600_000
        SQLiteFile.queryLog = []
        defer { SQLiteFile.queryLog = nil }

        // MARK: Gemini CLI
        let gemini = dir.appendingPathComponent("home/.gemini")
        write("home/.gemini/settings.json", #"{"general":{}}"#)
        try? fm.createDirectory(at: gemini.appendingPathComponent("antigravity"), withIntermediateDirectories: true)
        check(!GeminiCLISource(root: gemini).isInstalled || GeminiCLISource.binary != nil,
              "Gemini CLI: Antigravity's ~/.gemini (settings.json, antigravity/) alone isn't Gemini CLI")
        func geminiLine(_ id: String, _ at: String, tokens: Bool) -> String {
            #"{"id":"\#(id)","timestamp":"\#(at)","type":"gemini","content":"(answer)","model":"gemini-3.1-pro""#
                + (tokens ? #","tokens":{"input":1200,"output":300,"cached":200,"thoughts":50,"tool":0,"total":1750}}"# : "}")
        }
        write("home/.gemini/tmp/proj1/chats/session-2026-11-08T09-00-aaaa.jsonl", [
            #"{"sessionId":"s1","projectHash":"p","startTime":"\#(today)","kind":"main"}"#,
            #"{"id":"u1","timestamp":"\#(today)","type":"user","content":"hello"}"#,
            geminiLine("g1", today, tokens: false),
            geminiLine("g1", today, tokens: true),         // the same message again, now with tokens
            geminiLine("g2", yesterday, tokens: true),     // before today
            #"{"$rewindTo":"g1"}"#,
        ].joined(separator: "\n"))
        write("home/.gemini/tmp/proj1/chats/session-a.jsonl", geminiLine("g3", today, tokens: true))
        write("home/.gemini/tmp/proj1/chats/session-a.json", #"{"messages":[\#(geminiLine("g9", today, tokens: true))]}"#)   // migrated: skipped
        write("home/.gemini/tmp/proj2/chats/session-old.json", #"{"sessionId":"s3","messages":[\#(geminiLine("g4", today, tokens: true))]}"#)
        let geminiSource = GeminiCLISource(root: gemini)
        check(geminiSource.isInstalled, "Gemini CLI: its tmp folder means installed")
        let g = geminiSource.usage(since: dayStart).byModel["gemini-3.1-pro"]
        check(g?.messages == 3 && g?.input == 3000 && g?.cacheRead == 600 && g?.output == 1050,
              "Gemini CLI: last copy of each message, today only, old .json once, migrated .json skipped → \(g?.messages ?? 0) messages, in \(g?.input ?? 0)")
        check(AccountsReader.geminiCLI(home: gemini, installed: true, apiKey: { false })?.status == "Not signed in", "Gemini CLI: nothing saved → not signed in")
        write("home/.gemini/oauth_creds.json", #"{"access_token":"SECRET-GEMINI","refresh_token":"SECRET-GEMINI"}"#)
        let creds = AccountsReader.geminiCLI(home: gemini, installed: true)
        check(creds?.status == "Signed in" && !"\(String(describing: creds))".contains("SECRET"), "Gemini CLI: oauth_creds.json there → signed in (not opened)")
        write("home/.gemini/google_accounts.json", #"{"active":"someone@example.com","old":["old@example.com"]}"#)
        check(AccountsReader.geminiCLI(home: gemini, installed: true)?.status == "someone@example.com", "Gemini CLI: the active email from google_accounts.json")
        let keyHome = dir.appendingPathComponent("keyhome/.gemini")
        write("keyhome/.gemini/settings.json", #"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#)
        check(AccountsReader.geminiCLI(home: keyHome, installed: true)?.status == "Signed in · API key", "Gemini CLI: an API key chosen in settings.json")

        // MARK: Amp
        let amp = dir.appendingPathComponent("amp")
        write("amp/threads/T-1.json", #"""
        {"id":"T-1","messages":[{"role":"user","messageId":0},
         {"role":"assistant","messageId":1,"usage":{"model":"claude-sonnet-5","inputTokens":100,"outputTokens":50,"cacheCreationInputTokens":200,"cacheReadInputTokens":1000,"credits":0.12,"timestamp":"\#(today)"}},
         {"role":"assistant","messageId":2,"usage":{"model":"claude-sonnet-5","inputTokens":999,"outputTokens":999,"timestamp":"\#(yesterday)"}}]}
        """#)
        write("amp/threads/T-2.json", #"{"id":"T-2","messages":[],"usageLedger":{"events":[{"id":"e1","timestamp":"\#(today)","model":"gpt-5.4","credits":0.5,"tokens":{"input":400,"output":40,"total":440}}]}}"#)
        let ampUsage = AmpSource(roots: [amp]).usage(since: dayStart)
        let sonnet = ampUsage.byModel["claude-sonnet-5"], gpt = ampUsage.byModel["gpt-5.4"]
        check(sonnet?.messages == 1 && sonnet?.input == 100 && sonnet?.cacheWrite == 200 && sonnet?.cacheRead == 1000 && gpt?.input == 400,
              "Amp: today's per-message usage and the older ledger → \(ampUsage.total.messages) calls")
        check(AccountsReader.amp(dataDirs: [amp], installed: true)?.status == "Not signed in", "Amp: no secrets.json → not signed in")
        write("amp/secrets.json", #"{"apiKey@https://ampcode.com/":"SECRET-AMP"}"#)
        let ampAccount = AccountsReader.amp(dataDirs: [amp], installed: true)
        check(ampAccount?.status == "Signed in" && !AccountsReader.topLevelKeys(amp.appendingPathComponent("secrets.json")).joined().contains("SECRET"),
              "Amp: signed in from secrets.json's key names alone")

        // MARK: Copilot
        let copilotConfig = dir.appendingPathComponent("gh-copilot"), copilotCLI = dir.appendingPathComponent("copilot-cli"), exts = dir.appendingPathComponent("exts")
        check(AccountsReader.copilot(config: copilotConfig, cli: copilotCLI, extensionDirs: [exts]) == nil || CommandFinder.find("copilot") != nil,
              "Copilot: nothing there → no row")
        try? fm.createDirectory(at: exts.appendingPathComponent("github.copilot-chat-0.40.0"), withIntermediateDirectories: true)
        check(AccountsReader.copilot(config: copilotConfig, cli: copilotCLI, extensionDirs: [exts])?.status.hasPrefix("Unknown") == true,
              "Copilot: only the editor extension → sign-in unknown")
        write("copilot-cli/config.json", #"{"loggedInUsers":[{"host":"https://github.com","login":"someone"}],"copilot_tokens":{"x":"SECRET-CLI"}}"#)
        check(AccountsReader.copilot(config: copilotConfig, cli: copilotCLI, extensionDirs: [exts])?.status == "Signed in · Copilot CLI",
              "Copilot CLI: loggedInUsers key → signed in")
        write("gh-copilot/apps.json", #"{"github.com:Iv1.x":{"user":"someone","oauth_token":"SECRET-COPILOT"}}"#)
        let copilot = AccountsReader.copilot(config: copilotConfig, cli: copilotCLI, extensionDirs: [exts])
        check(copilot?.status == "Signed in" && !"\(String(describing: copilot))".contains("SECRET"), "Copilot: apps.json there → signed in (not opened)")

        // MARK: Windsurf
        database("windsurf/state.vscdb", [
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
            #"INSERT INTO ItemTable VALUES ('windsurf.settings.cachedPlanInfo','{"planName":"Pro","usage":{"messages":500}}')"#,
        ])
        let windsurfState = dir.appendingPathComponent("windsurf/state.vscdb")
        check(AccountsReader.windsurf(state: windsurfState, name: "Windsurf", installed: true)?.status == "Not signed in", "Windsurf: no auth row → not signed in")
        database("windsurf/state.vscdb", [#"INSERT INTO ItemTable VALUES ('windsurfAuthStatus','{"apiKey":"SECRET-WINDSURF","name":"Someone"}')"#])
        let windsurf = AccountsReader.windsurf(state: windsurfState, name: "Windsurf", installed: true)
        check(windsurf == AccountInfo(agent: "Windsurf", status: "Signed in", plan: "Pro") && !"\(String(describing: windsurf))".contains("SECRET"),
              "Windsurf: signed in, plan from cachedPlanInfo")

        // MARK: Kiro
        let kiroToken = dir.appendingPathComponent("aws/kiro-auth-token.json"), kiroStore = dir.appendingPathComponent("kiro-cli/data.sqlite3")
        check(AccountsReader.kiro(token: kiroToken, cliStore: kiroStore, installed: true)?.status == "Not signed in", "Kiro: nothing → not signed in")
        database("kiro-cli/data.sqlite3", ["CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT)",
                                           "INSERT INTO auth_kv VALUES ('kirocli:odic:token','SECRET-KIRO')"])
        check(AccountsReader.kiro(token: kiroToken, cliStore: kiroStore, installed: true)?.status == "Signed in · kiro-cli", "Kiro: kiro-cli's token key there → signed in")
        write("aws/kiro-auth-token.json", #"{"accessToken":"SECRET-KIRO","refreshToken":"SECRET-KIRO"}"#)
        check(AccountsReader.kiro(token: kiroToken, cliStore: kiroStore, installed: true)?.status == "Signed in", "Kiro: the IDE's token file there → signed in (not opened)")

        // MARK: Cline / Roo Code / Kilo Code
        let roo = VSCodeAgents.agents[1]
        let storage = dir.appendingPathComponent("Application Support/Cursor/User/globalStorage/\(roo.extensionID)")
        func request(_ at: Int, _ info: String) -> String {
            #"{"ts":\#(at),"type":"say","say":"api_req_started","text":"\#(info.replacingOccurrences(of: "\"", with: "\\\""))"}"#
        }
        write("Application Support/Cursor/User/globalStorage/\(roo.extensionID)/tasks/t1/ui_messages.json", "[" + [
            #"{"ts":\#(todayMS),"type":"say","say":"text","text":"hello"}"#,
            request(todayMS, #"{"tokensIn":1500,"tokensOut":300,"cacheWrites":700,"cacheReads":9000,"cost":0.031}"#),
            request(todayMS, #"{"request":"(still streaming)"}"#),                       // no tokens yet
            request(yesterdayMS, #"{"tokensIn":99999,"tokensOut":1,"cost":5}"#),            // before today
        ].joined(separator: ",") + "]")
        write("Application Support/Cursor/User/globalStorage/\(roo.extensionID)/tasks/t1/task_metadata.json",
              #"{"model_usage":[{"ts":1,"model_id":"old-model"},{"ts":\#(todayMS),"model_id":"claude-sonnet-5","model_provider_id":"anthropic"}]}"#)
        write("Application Support/Cursor/User/globalStorage/\(roo.extensionID)/tasks/t2/ui_messages.json",
              "[" + request(todayMS, #"{"tokensIn":100,"tokensOut":20,"cost":0}"#) + "]")
        let found = VSCodeAgents.storages(roo, appSupport: dir.appendingPathComponent("Application Support"))
        check(found.map(\.editor) == ["Cursor"] && found.first?.folder.standardizedFileURL.path == storage.standardizedFileURL.path, "Roo Code: found in Cursor's globalStorage")
        let rooUsage = VSCodeAgentSource(agent: roo, folders: [storage]).usage(since: dayStart)
        let rooSonnet = rooUsage.byModel["claude-sonnet-5"], unknown = rooUsage.byModel["unknown"]
        check(rooSonnet?.messages == 1 && rooSonnet?.input == 1500 && rooSonnet?.cacheRead == 9000 && rooSonnet?.cacheWrite == 700 && unknown?.messages == 1,
              "Roo Code: today's finished requests only, model from task_metadata → \(rooUsage.total.messages) requests")
        check(abs((rooUsage.costs["claude-sonnet-5"] ?? 0) - 0.031) < 0.000_001 && rooUsage.unpricedModels == ["unknown"],
              "Roo Code: the recorded cost is used; no cost and no model → price unknown")
        check(AccountsReader.vsCodeAgent(roo, storages: found)?.status == "Installed · Cursor" && AccountsReader.vsCodeAgent(roo, storages: []) == nil,
              "Roo Code: installed in Cursor; nowhere → no row")

        // Cline: a deleted-requests total and a subagent total count too; the model is on each message.
        let clineData = dir.appendingPathComponent("cline-data")
        let cline = VSCodeAgents.Agent(name: "Cline", extensionID: "saoudrizwan.claude-dev", short: "CL", color: 0, clineData: clineData)
        func clineSay(_ say: String, _ info: String, model: String? = nil) -> String {
            #"{"ts":\#(todayMS),"type":"say","say":"\#(say)","text":"\#(info.replacingOccurrences(of: "\"", with: "\\\""))""#
                + (model.map { #","modelInfo":{"modelId":"\#($0)","providerId":"anthropic","mode":"act"}}"# } ?? "}")
        }
        write("cline-data/tasks/c1/ui_messages.json", "[" + [
            clineSay("api_req_started", #"{"tokensIn":1000,"tokensOut":100,"cost":0.02}"#, model: "claude-opus-5"),
            clineSay("deleted_api_reqs", #"{"tokensIn":500,"tokensOut":50,"cost":0.01}"#),
            clineSay("subagent_usage", #"{"source":"subagents","tokensIn":200,"tokensOut":20,"cacheWrites":0,"cacheReads":0,"cost":0.004}"#),
            clineSay("api_req_finished", #"{"tokensIn":7777}"#),
        ].joined(separator: ",") + "]")
        write("cline-data/tasks/c1/task_metadata.json", #"{"model_usage":[{"ts":\#(todayMS),"model_id":"claude-sonnet-5"}]}"#)
        write("cline-data/sessions/s1/s1.messages.json", #"{"updated_at":"\#(today)","messages":[{"role":"user","ts":\#(todayMS)},"#
              + #"{"role":"assistant","ts":\#(todayMS),"modelInfo":{"id":"claude-sonnet-5","provider":"anthropic"},"#
              + #""metrics":{"inputTokens":5000,"outputTokens":400,"cacheReadTokens":3000,"cacheWriteTokens":1000,"cost":0.05}}]}"#)
        let clineUsage = VSCodeAgentSource(agent: cline, folders: [clineData]).usage(since: dayStart)
        let opus = clineUsage.byModel["claude-opus-5"], clineSonnet = clineUsage.byModel["claude-sonnet-5"]
        check(opus?.input == 1000 && clineSonnet?.messages == 3 && clineSonnet?.input == 500 + 200 + 1000 && clineSonnet?.cacheRead == 3000,
              "Cline: requests, deleted and subagent totals, SDK sessions (input less its cache) → \(clineUsage.total.messages) requests")
        check(abs(clineUsage.usd - (0.02 + 0.01 + 0.004 + 0.05)) < 0.000_001, "Cline: recorded costs add up → \(clineUsage.usd)")

        // Kilo Code 7: OpenCode's tables in kilo.db.
        let kiloDir = dir.appendingPathComponent("kilo")
        let kiloMessage = #"{"id":"m1","role":"assistant","modelID":"gpt-5.4","providerID":"openai","cost":0.07,"tokens":{"input":800,"output":90,"reasoning":10,"cache":{"read":0,"write":0}},"time":{"created":\#(todayMS)}}"#
        try? fm.createDirectory(at: kiloDir, withIntermediateDirectories: true)
        var kdb: OpaquePointer?
        if sqlite3_open(kiloDir.appendingPathComponent("kilo.db").path, &kdb) == SQLITE_OK {
            sqlite3_exec(kdb, "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT)", nil, nil, nil)
            sqlite3_exec(kdb, "INSERT INTO message VALUES ('m1','s1','\(kiloMessage)')", nil, nil, nil)
            sqlite3_close(kdb)
        }
        let kilo = VSCodeAgents.Agent(name: "Kilo Code", extensionID: "kilocode.kilo-code", short: "KC", color: 0, openCode: .kilo(root: kiloDir))
        let kiloUsage = VSCodeAgentSource(agent: kilo, folders: []).usage(since: dayStart)
        check(kiloUsage.source == "Kilo Code" && kiloUsage.byModel["gpt-5.4"]?.output == 100 && abs(kiloUsage.usd - 0.07) < 0.000_001,
              "Kilo Code 7: kilo.db read like OpenCode's, under Kilo's name")

        // Windsurf's daily and weekly quota, from the same non-secret row.
        let resetDay = Int(now.addingTimeInterval(5 * 3600).timeIntervalSince1970), resetWeek = Int(now.addingTimeInterval(80 * 3600).timeIntervalSince1970)
        database("windsurf/state.vscdb", [
            #"INSERT INTO ItemTable VALUES ('windsurf.settings.cachedPlanInfo','{"planName":"Pro","quotaUsage":{"dailyRemainingPercent":37.4,"weeklyRemainingPercent":70,"dailyResetAtUnix":\#(resetDay),"weeklyResetAtUnix":\#(resetWeek)}}')"#])
        let windsurfPlan = PlanUsageReader.windsurf(state: windsurfState, name: "Windsurf", now: now)
        check(windsurfPlan?.agent == "Windsurf" && windsurfPlan?.shortWindow?.label == "Day" && windsurfPlan?.shortWindow?.left == 37
              && windsurfPlan?.window("Week")?.left == 70 && windsurfPlan?.window("Day")?.length == 86400,
              "Windsurf: quotaUsage → Day 37% and Week 70% left")
        check(windsurfPlan.map { AppModel.planSummary([$0]) } == "Day 37 · Week 70".replacingOccurrences(of: " ·", with: "% ·") + "% left",
              "Windsurf: Settings says \(windsurfPlan.flatMap { AppModel.planSummary([$0]) } ?? "nil")")
        check(PlanWindow.spokenName("Day") == "daily" && PlanWindow.spokenName("5h") == "5-hour" && PlanWindow.spokenName("Week") == "weekly",
              "a daily window is spoken as daily")
        let dayAlert = PlanAlerts.due([PlanUsage(agent: "Windsurf", windows: [PlanWindow(label: "Day", left: 15, resets: now.addingTimeInterval(3600))], at: now)],
                                      sent: [], now: now).alerts
        check(dayAlert.first?.title == "Windsurf: 15% of the daily limit left", "a daily limit's alert says daily → \(dayAlert.first?.title ?? "none")")
        database("windsurf/state.vscdb", [
            #"INSERT INTO ItemTable VALUES ('windsurf.settings.cachedPlanInfo','{"planName":"Pro","quotaUsage":{"dailyRemainingPercent":5,"dailyResetAtUnix":1000}}')"#])
        check(PlanUsageReader.windsurf(state: windsurfState, name: "Windsurf", now: now)?.shortWindow?.wasReset == true, "Windsurf: a day that's reset since is full again")
        check(PlanUsageReader.windsurf(state: dir.appendingPathComponent("none.vscdb"), now: now) == nil, "Windsurf: no state, no plan")

        // Roo Code's custom storage folder, from that one key of the editor's settings.json.
        let custom = dir.appendingPathComponent("roo-elsewhere")
        try? fm.createDirectory(at: custom.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        write("Application Support/Code/User/settings.json", """
        {
            // "roo-cline.customStoragePath": "/nowhere/commented",
            "editor.fontSize": 13,
            "roo-cline.customStoragePath": "\(custom.path)",
        }
        """)
        let rooPlaces = VSCodeAgents.storages(roo, appSupport: dir.appendingPathComponent("Application Support"))
        check(rooPlaces.contains { $0.editor == "VS Code" && $0.folder.path == custom.standardizedFileURL.path } && rooPlaces.count == 2,
              "Roo Code: customStoragePath followed (a commented-out one isn't) → \(rooPlaces.map(\.editor))")
        check(VSCodeAgents.setting(named: "roo-cline.customStoragePath", in: dir.appendingPathComponent("none.json")) == nil
              && VSCodeAgents.agents.first { $0.name == "Cline" }?.storageSetting == nil, "no settings file, or another extension: nothing followed")

        // No query asked for a secret row's value.
        let queries = SQLiteFile.queryLog ?? []
        let leaky = queries.filter { sql in
            let lower = sql.lowercased()
            return lower.contains("value") && (lower.contains("token") || lower.contains("authstatus") || lower.contains("apikey"))
        }
        check(!queries.isEmpty && leaky.isEmpty, "no secret row's value is ever selected (\(queries.count) queries) \(leaky)")

        // MARK: The table
        let names = Providers.all.map(\.name), shorts = Providers.all.map(\.short)
        check(Set(names).count == names.count && Set(shorts).count == shorts.count && shorts.allSatisfy { (2...3).contains($0.count) },
              "providers: names and short labels are unique, 2–3 letters")
        check(Providers.all.allSatisfy { !$0.capabilities.contains(.usageLink) || $0.usagePage != nil }
              && Providers.all.allSatisfy { ($0.source != nil) == $0.capabilities.contains(.tokens) || $0.name == "Claude" },
              "providers: a usage link where one's promised, a reader where tokens are")
        check(AILogos.short(for: "Gemini CLI") == "GE" && AILogos.short(for: "Work", badge: "2") == "C2" && AILogos.short(for: "Some AI") == "SO",
              "letter badges: GE, C2 for a second Claude account, first letters otherwise")
        let letters = AILogos.icon(for: "Amp", size: 14)
        check(letters.size == NSSize(width: 14, height: 14), "an AI with no app gets a 14 pt letter badge")
        check(ClaudeAccounts.nameProblem(AccountsReader.windsurfName.lowercased(), existing: []) != nil, "an extra Claude account can't take another AI's name")
        let fixes = Suggestions.make(accounts: [
            AccountInfo(agent: AccountsReader.windsurfName, status: "Not signed in"), AccountInfo(agent: "Gemini CLI", status: "Not signed in"),
            AccountInfo(agent: "Amp", status: "Not signed in"), AccountInfo(agent: "GitHub Copilot", status: "Not signed in"),
            AccountInfo(agent: "Kiro", status: "Not installed"), AccountInfo(agent: "Cline", status: "Installed · VS Code"),
        ], found: [])
        check(fixes.map(\.id) == ["open|\(AccountsReader.windsurfName)", "links|Gemini CLI", "signin|Amp", "signin|GitHub Copilot"],
              "suggestions: sign in only where installed and there's a way; never to install → \(fixes.map(\.id))")
        return failures
    }
}
