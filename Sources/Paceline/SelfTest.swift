import AppKit
import SQLite3

/// `Paceline --selftest` checks the menu bar readings and plan parsing without the UI.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        var failures = menuBarTests()
        failures += planTests()
        failures += codexTests()
        failures += claude2Tests()
        failures += accountTests()
        failures += migrationTests()
        failures += paceTests()
        failures += alertTests()
        failures += claudeAccountTests()
        failures += suggestionTests()
        failures += freshTests()
        failures += roundBTests()
        failures += roundCTests()
        failures += roundDTests()
        failures += auditTests()
        failures += splitUsageTests()
        failures += orderTests()
        failures += signInTests()
        failures += installTests()
        failures += accountsLayoutTests()
        failures += followupTests()
        failures += chartLegendTests()
        failures += updateTests()
        failures += accountSwitchTests()
        failures += statusLineTests()
        failures += reportTests()
        failures += cpuLeanTests()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0
    }

    static func menuBarTests() -> Int {
        var failures = 0
        func check(_ got: (text: String, low: Bool), _ text: String, low: Bool = false, _ what: String) {
            let ok = got.text == text && got.low == low
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  menu bar: \(what) → \"\(got.text)\"")
        }
        let now = Date()
        let claude = AIReading(name: "Claude", text: "72%", low: false, lastActive: now.addingTimeInterval(-600))
        let gemini = AIReading(name: "Antigravity", text: "15%", low: true, lastActive: now.addingTimeInterval(-60))
        let idle = AIReading(name: "Antigravity", text: "98%", low: false, lastActive: nil)
        check(AIReading.title([claude], shows: .all), "72%", "one AI goes without a label")
        check(AIReading.title([claude], shows: .latest), "72%", "latest with one AI is the same")
        check(AIReading.title([claude, gemini], shows: .all), "CC 72%  AG 15%", low: true, "all: each AI labelled, low if any is")
        check(AIReading.title([claude, gemini], shows: .latest), "AG 15%", low: true, "latest: the AI used last")
        check(AIReading.title([claude, idle], shows: .latest), "CC 72%", "latest: an AI never used today loses")
        check(AIReading.title([AIReading(name: "Claude", text: "$0.00", low: false, lastActive: nil), idle], shows: .latest),
              "CC $0.00", "latest: a tie keeps Claude first")
        check(AIReading.title([], shows: .latest), "", "no AI: icon only")
        let codex = AIReading(name: "Codex", text: "64%", low: false, lastActive: now)
        check(AIReading.title([claude, gemini, codex], shows: .all), "CC 72%  AG 15%  CX 64%", low: true, "Codex is labelled CX")

        // Three logos packed vs the old layout (18pt logos, " " after, "   " between; the
        // item's side padding, 8pt → 3pt a side, isn't in either).
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let old = NSMutableAttributedString()
        for (i, text) in ["71%", "12%", "63%"].enumerated() {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(size: NSSize(width: 18, height: 18))
            attachment.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
            old.append(NSAttributedString(string: i == 0 ? "" : "   ", attributes: [.font: font]))
            old.append(NSAttributedString(attachment: attachment))
            old.append(NSAttributedString(string: (i == 2 ? "2" : "") + " " + text, attributes: [.font: font]))
        }
        let logo = NSImage(size: AILogos.menuBarSize)
        let packed = StatusItemController.title(["71%", "12%", "63%"].map {
            StatusItemController.Segment(icon: logo, label: nil, text: $0)
        }, warning: false)
        let (was, now2) = (old.size().width, packed.size().width)
        let ok = now2 <= was * 0.65
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  menu bar: packed title \(Int(now2))pt vs \(Int(was))pt before (\(Int((1 - now2 / was) * 100))% narrower)")

        // The item grows with its title (it's measured, not asked for a fitting size that wraps).
        func length(_ texts: [String]) -> CGFloat {
            StatusItemController.compactLength(title: StatusItemController.title(texts.map { StatusItemController.Segment(icon: logo, label: nil, text: $0) }, warning: false), image: nil)
        }
        let (short, wide, more) = (length(["9%", "61%"]), length(["100%", "61%"]), length(["100%", "61%", "12%"]))
        let grows = short < wide && wide < more
        if !grows { failures += 1 }
        print("\(grows ? "PASS" : "FAIL")  menu bar: length grows 9%→100%, + an AI → \(Int(short)) < \(Int(wide)) < \(Int(more))pt")

        // Only the low AI's number (and its small %) is orange.
        let mixed = StatusItemController.title([StatusItemController.Segment(icon: logo, label: nil, text: "71%"),
                                                StatusItemController.Segment(icon: logo, label: nil, text: "12%", low: true)], warning: true)
        var orange = ""
        mixed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: mixed.length)) { color, range, _ in
            if (color as? NSColor) === MenuBarInk.orange { orange += mixed.attributedSubstring(from: range).string }
        }
        check((orange, false), "12%", "orange only on the low AI")

        // One warning rule: orange at 20% or less, red at 10% or less, in the menu bar and the panel.
        let rule = (Warning.color(left: 8) == .systemRed, Warning.color(left: 15) == .systemOrange, Warning.color(left: 50) == nil)
        let reds = StatusItemController.title([StatusItemController.Segment(icon: logo, label: nil, text: "8%", low: true)], warning: true)
        let red = (reds.attribute(.foregroundColor, at: reds.length - 1, effectiveRange: nil) as? NSColor) === MenuBarInk.red
        check((rule == (true, true, true) && red ? "ok" : "no", false), "ok", "warning: ≤20% orange, ≤10% red (menu bar too)")

        // Menu bar text reads at 4.5:1 or better on a light bar and a dark one, dimmed or not.
        let inks: [(String, NSColor)] = [("text", MenuBarInk.text), ("old", MenuBarInk.stale), ("orange", MenuBarInk.orange), ("red", MenuBarInk.red)]
        let ratios = inks.flatMap { name, ink in
            [(name + " light", MenuBarInk.contrast(ink, on: MenuBarInk.lightBar, dark: false)),
             (name + " dark", MenuBarInk.contrast(ink, on: MenuBarInk.darkBar, dark: true))]
        }
        // Settings' mint, also link-style buttons' text, on a white and a dark window.
        let mint = NSColor(PacelineMark.mint)
        let mintRatios = (MenuBarInk.contrast(mint, on: .white, dark: false),
                          MenuBarInk.contrast(mint, on: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1), dark: true))
        check((min(mintRatios.0, mintRatios.1) >= 4.5 ? "ok" : "no", false), "ok",
              "Settings' mint text ≥ 4.5:1 (light \(String(format: "%.1f", mintRatios.0)), dark \(String(format: "%.1f", mintRatios.1)))")
        let weakest = ratios.min { $0.1 < $1.1 }!
        check((weakest.1 >= 4.5 ? "ok" : "no", false), "ok",
              "menu bar contrast ≥ 4.5:1 light and dark (weakest: \(weakest.0) \(String(format: "%.1f", weakest.1)):1)")

        // Right click: each AI's numbers on top, not clickable, then the options.
        let controller = AppController()
        controller.model.plans = [PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 54, resets: nil), PlanWindow(label: "Week", left: 37, resets: nil)], at: now)]
        let items = controller.statusMenu().items
        let titles = items.map { $0.isSeparatorItem ? "—" : $0.title }
        let sub = items.first { $0.title == "Menu Bar" }?.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
        let menuOK = titles == ["Claude: 5h 54% · Week 37% left", "—", "Menu Bar", "Show Tokens Instead of $", "—", "Check for Updates…", "Report a Problem…", "Settings…", "Quit Paceline"]
            && items.first?.isEnabled == false && sub == ["All AIs", "Latest used AI", "—", "Compact", "Two rows"]
        check((menuOK ? "ok" : titles.joined(separator: " | "), false), "ok", "right-click menu starts with the readings")
        return failures
    }

    /// The model's readings from plan windows: the tightest Antigravity group wins.
    static func planTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  plans: \(what)")
        }
        let now = Date()
        let model = AppModel()
        model.plans = [
            PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 18, resets: now.addingTimeInterval(3600))], at: now),
            PlanUsage(agent: "Antigravity", group: "Gemini", windows: [PlanWindow(label: "5h", left: 90, resets: nil)], at: now),
            PlanUsage(agent: "Antigravity", group: "Claude", windows: [PlanWindow(label: "5h", left: 40, resets: nil)], at: now),
        ]
        let readings = model.aiReadings
        check(readings.map(\.name) == ["Claude", "Antigravity"], "one reading per AI, Claude first → \(readings.map(\.name))")
        check(readings.first?.text == "18%" && readings.first?.low == true, "Claude at 18% is low")
        check(readings.last?.text == "40%", "Antigravity shows its tightest group → \(readings.last?.text ?? "nil")")

        // Two rows: the five hours over the week; one window, one row.
        let rowsModel = AppModel()
        rowsModel.plans = [
            PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 18, resets: nil), PlanWindow(label: "Week", left: 40, resets: nil)], at: now),
            PlanUsage(agent: "Codex", windows: [PlanWindow(label: "Week", left: 64, resets: nil)], at: now),
            PlanUsage(agent: "Antigravity", group: "Gemini", windows: [PlanWindow(label: "5h", left: 90, resets: nil), PlanWindow(label: "Week", left: 12, resets: nil)], at: now),
            PlanUsage(agent: "Antigravity", group: "Claude", windows: [PlanWindow(label: "5h", left: 40, resets: nil), PlanWindow(label: "Week", left: 70, resets: nil)], at: now),
        ]
        let rowReadings = Dictionary(uniqueKeysWithValues: rowsModel.aiReadings.map { ($0.name, $0.rows) })
        check(rowReadings["Claude"] == [AIReading.Row(text: "18", low: true, window: "5h"), AIReading.Row(text: "40", low: false, window: "Week")],
              "two rows: Claude 5h then Week, low per number → \(rowReadings["Claude"]?.map(\.text) ?? [])")
        check(rowReadings["Codex"]?.map(\.text) == ["64"], "two rows: one window, one row → \(rowReadings["Codex"]?.map(\.text) ?? [])")
        check(rowReadings["Antigravity"]?.map(\.text) == ["40", "12"], "two rows: Antigravity's tightest group per window → \(rowReadings["Antigravity"]?.map(\.text) ?? [])")
        let logo = NSImage(size: AILogos.menuBarSize)
        let image = StatusItemController.twoRows([StatusItemController.Segment(icon: logo, label: nil, text: "18%", rows: rowReadings["Claude"] ?? []),
                                                  StatusItemController.Segment(icon: logo, label: nil, text: "64%", rows: rowReadings["Codex"] ?? [])],
                                                 appearance: NSAppearance(named: .darkAqua)!, height: 22)
        check(image.size.height == 22 && image.size.width < 60, "two rows image fits the menu bar → \(Int(image.size.width))×\(Int(image.size.height))pt")

        // VoiceOver hears names, windows and which number is low.
        let spoken = AIReading.spoken(rowsModel.aiReadings)
        check(spoken == "Claude 5-hour 18% left, weekly 40% left, low; Antigravity 5-hour 40% left, weekly 12% left, low; Codex weekly 64% left",
              "spoken → \(spoken)")
        let summary = AppModel.planSummary(rowsModel.plans.filter { $0.agent == "Antigravity" })
        check(summary == "5h 40% · Week 12% left", "Accounts summary names both windows → \(summary ?? "nil")")

        // Seven hours old: dimmed, and the age goes into the tooltip and VoiceOver.
        let oldModel = AppModel()
        oldModel.plans = [PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 50, resets: nil)], at: now.addingTimeInterval(-7 * 3600))]
        let old = oldModel.aiReadings
        check(old.first?.staleNote == "as of 7 h ago", "stale plan has its age → \(old.first?.staleNote ?? "nil")")
        check(AIReading.tooltip(old) == "Claude: 5h 50% left · as of 7 h ago", "tooltip → \(AIReading.tooltip(old))")
        check(AIReading.spoken(old) == "Claude 5-hour 50% left, as of 7 h ago", "spoken stale → \(AIReading.spoken(old))")
        let listed = [ClaudeAccount(id: "account2", name: "Claude 2", configDir: "/tmp/c2")]
        check(AILogos.badge(for: "Claude 2", accounts: listed) == "2" && AILogos.badge(for: "Claude", accounts: listed) == nil, "the 2 badge is for Claude 2 only")
        check(rowsModel.aiReadings.allSatisfy { $0.staleNote == nil }, "fresh plans aren't stale")
        check(PlanWindow(label: "5h", left: 50, resets: now.addingTimeInterval(5400)).resetText(now: now) == "resets in 1h 30m", "reset text")
        return failures
    }

    /// A made-up Codex rollout: yesterday's call is the baseline, a repeated
    /// total counts once, and the newest rate_limits win.
    static func codexTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  codex: \(what)")
        }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))  // resets_at is whole seconds
        let dayStart = Calendar.current.startOfDay(for: now)
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func stamp(_ date: Date) -> String { date.formatted(iso) }
        func tokens(_ input: Int, _ cached: Int, _ output: Int) -> String {
            #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}"#
        }
        let yesterday = dayStart.addingTimeInterval(-3600), today = min(now, dayStart.addingTimeInterval(60))
        let resets = Int(now.timeIntervalSince1970) + 5400
        let lines = [
            #"{"timestamp":"\#(stamp(yesterday))","type":"session_meta","payload":{"id":"test","cwd":"/tmp"}}"#,
            #"{"timestamp":"\#(stamp(yesterday))","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(stamp(yesterday))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(tokens(1000, 200, 100))},"rate_limits":{"primary":{"used_percent":90,"window_minutes":300,"resets_in_seconds":60}}}}"#,
            #"{"timestamp":"\#(stamp(today))","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"\#(stamp(today))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(tokens(3000, 1200, 400)),"last_token_usage":\#(tokens(2000, 1000, 300))},"rate_limits":null}}"#,
            #"{"timestamp":"\#(stamp(today))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(tokens(3000, 1200, 400))},"rate_limits":{"plan_type":"team","primary":{"used_percent":36.4,"window_minutes":300,"resets_at":\#(resets)},"secondary":{"used_percent":55,"window_minutes":10080,"resets_in_seconds":86400}}}}"#,
            #"{"timestamp":"\#(stamp(today))","type":"response_item","payload":{"type":"message","content":"no token_count here"}}"#,
            "not json",
        ]
        let log = CodexLog.read(Data(lines.joined(separator: "\n").utf8), since: dayStart)
        let c = log.byModel["gpt-5.5"] ?? TokenCounts()
        check(log.byModel["gpt-5-codex"] == nil, "yesterday's call isn't counted → \(log.byModel.keys.sorted())")
        check(c.input == 1000 && c.cacheRead == 1000 && c.output == 300 && c.messages == 1,
              "today's call, cached input split out, repeat counted once → in \(c.input) cache \(c.cacheRead) out \(c.output) × \(c.messages)")
        let plan = log.limits.flatMap { PlanUsageReader.codex($0, now: now) }
        check(plan?.agent == "Codex" && plan?.windows.map(\.label) == ["5h", "Week"], "plan has 5h and Week → \(plan?.windows.map(\.label) ?? [])")
        check(plan?.window("5h")?.left == 64 && plan?.window("Week")?.left == 45, "% left from used_percent → \(plan?.windows.map(\.left) ?? [])")
        check(plan?.window("5h")?.resetText(now: now) == "resets in 1h 30m", "resets_at → \(plan?.window("5h")?.resetText(now: now) ?? "nil")")
        let old = CodexLog.Limits(primary: CodexLog.Window(minutes: 300, used: 99, resets: now.addingTimeInterval(-60)), secondary: nil, at: now.addingTimeInterval(-7200))
        let reset = PlanUsageReader.codex(old, now: now)?.window("5h")
        check(reset?.left == 100 && reset?.wasReset == true, "a window that has reset is full again, marked as reset")
        check(log.limits?.planType == "team" && plan?.planName == "Team", "plan_type read and named → \(plan?.planName ?? "nil")")
        let names = ["free", "plus", "pro", "team", "business", "enterprise", "edu", "go"].map { CodexLog.planName($0) ?? "nil" }
        check(names == ["Free", "Plus", "Pro", "Team", "Business", "Enterprise", "Edu", "Go"] && CodexLog.planName(nil) == nil && CodexLog.planName("") == nil,
              "plan names → \(names)")
        check(PlanUsageReader.codex(old, now: now)?.planName == nil, "no plan_type: no plan name, nothing breaks")
        let noon = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 11, day: 7, hour: 12)
        let folder = noon.date.map { CodexSource.dayFolders(in: URL(fileURLWithPath: "/s"), days: 2, now: $0).map(\.path) } ?? []
        check(folder == ["/s/2026/11/07", "/s/2026/11/06"], "session folders use Gregorian years → \(folder)")
        return failures
    }

    /// A `rate_limit_event` from `claude -p --output-format stream-json`, and a
    /// second account that reads apart from the first.
    static func claude2Tests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  claude 2: \(what)")
        }
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1794045000,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.36,"resetsAt":1794045000},"seven_day":{"utilization":0.25,"resetsAt":1794222000}}}}"#
        let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
        var saved = PlanUsageReader.rateLimitWindows(event)
        func used(_ key: String) -> Double? { ((saved[key] as? [String: Any])?["used"] as? NSNumber)?.doubleValue }
        func resets(_ key: String) -> Double? { ((saved[key] as? [String: Any])?["resets_at"] as? NSNumber)?.doubleValue }
        check(used("five_hour") == 36 && used("seven_day") == 25, "utilization → used \(used("five_hour") ?? -1)/\(used("seven_day") ?? -1)")
        check(resets("five_hour") == 1794045000 && resets("seven_day") == 1794222000, "resetsAt → resets_at")
        let now = Date(timeIntervalSince1970: 1794045000 - 5400)
        saved["saved_at"] = now.timeIntervalSince1970
        let plan = PlanUsageReader.claude(saved, agent: "Claude 2", now: now)
        check(plan?.agent == "Claude 2" && plan?.window("5h")?.left == 64 && plan?.window("Week")?.left == 75,
              "same parser as Claude → \(plan?.windows.map(\.left) ?? [])")
        check(plan?.window("5h")?.resetText(now: now) == "resets in 1h 30m", "5h reset → \(plan?.window("5h")?.resetText(now: now) ?? "nil")")

        let claude2 = [ClaudeAccount(id: "account2", name: "Claude 2", configDir: "/tmp/c2")]
        let model = AppModel()
        model.claudeAccounts = claude2
        model.plans = [PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 72, resets: nil)], at: Date())] + [plan].compactMap { $0 }
        let readings = model.aiReadings
        let withOthers = AppModel()
        withOthers.claudeAccounts = claude2
        withOthers.plans = [PlanUsage(agent: "Antigravity", group: "Gemini", windows: [PlanWindow(label: "5h", left: 90, resets: nil)], at: Date())] + model.plans
        check(withOthers.aiReadings.map(\.name) == ["Claude", "Claude 2", "Antigravity"], "Claude 2 sits next to Claude → \(withOthers.aiReadings.map(\.name))")
        check(readings.map(\.name) == ["Claude", "Claude 2"] && readings.map(\.text) == ["72%", "64%"],
              "a reading of its own → \(readings.map { "\($0.name) \($0.text)" })")
        check(AIReading.title(readings, shows: .all).text == "CC 72%  C2 64%", "labelled C2 → \(AIReading.title(readings, shows: .all).text)")
        check(readings.last?.badge == "2" && readings.first?.badge == nil, "badge 2 after the logo")

        // Only the five hours in this event: the saved week stays.
        let fiveOnly = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1794045000,"rateLimitType":"five_hour","utilization":0.5}}"#
        let single = PlanUsageReader.rateLimitWindows((try? JSONSerialization.jsonObject(with: Data(fiveOnly.utf8))) as? [String: Any] ?? [:])
        check(((single["five_hour"] as? [String: Any])?["used"] as? NSNumber)?.doubleValue == 50 && single["seven_day"] == nil,
              "no unifiedWindows: rateLimitType + utilization → \(single.keys.sorted())")
        let merged = PlanUsageReader.merged(single, into: saved, now: now)
        let mergedPlan = PlanUsageReader.claude(merged, agent: "Claude 2", now: now)
        check(mergedPlan?.window("5h")?.left == 50 && mergedPlan?.window("Week")?.left == 75,
              "one window merged over the saved file keeps the other → \(mergedPlan?.windows.map(\.left) ?? [])")
        return failures
    }

    /// The AgentPet → Paceline move: the newer of the two plan files wins, and
    /// old settings come over once. Temp files and a throwaway suite only.
    static func migrationTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  rename: \(what)")
        }
        let now = Date()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func save(_ name: String, used: Int, age: TimeInterval) -> URL {
            let url = dir.appendingPathComponent(name)
            let json: [String: Any] = ["saved_at": now.timeIntervalSince1970 - age, "five_hour": ["used": used]]
            try? JSONSerialization.data(withJSONObject: json).write(to: url)
            return url
        }
        let current = save("paceline.json", used: 10, age: 600), legacy = save("agentpet.json", used: 30, age: 60)
        check(PlanUsageReader.newest([current, legacy], agent: "Claude 2", now: now)?.window("5h")?.left == 70, "a newer legacy file wins")
        let newer = save("paceline2.json", used: 20, age: 5)
        check(PlanUsageReader.newest([newer, legacy], agent: "Claude 2", now: now)?.window("5h")?.left == 80, "a newer Paceline file wins")
        check(PlanUsageReader.newest([dir.appendingPathComponent("missing.json"), legacy], agent: "Claude", now: now)?.window("5h")?.left == 70,
              "a missing file is skipped")
        check(PlanUsageReader.claudeFiles(account: "account2", legacy: true).map(\.path).allSatisfy { $0.hasSuffix("claude-usage-account2.json") }
              && PlanUsageReader.claudeFiles(account: "account2", legacy: true).last?.path.contains("/Caches/AgentPet/") == true,
              "where AgentPet was, account2 reads its folder too")
        check(PlanUsageReader.claudeFiles(account: "account2", legacy: false).count == 1
              && !PlanUsageReader.claudeFiles(legacy: false).contains { $0.path.contains("/Caches/AgentPet/") }
              && PlanUsageReader.claudeFiles(legacy: true).contains { $0.path.contains("/Caches/AgentPet/") },
              "elsewhere, no AgentPet files are read")

        // Caches → Application Support (0.1.9).
        let support = "/Library/Application Support/Paceline/"
        check(PlanUsageReader.ownClaudeFile.path.contains(support) && PlanUsageReader.claudeFile(account: "account2").path.contains(support)
              && PlanUsageReader.ownAntigravityFile.path.contains(support) && UsageHistory.file.path.contains(support),
              "plan numbers and history live in Application Support/Paceline")
        check(!PlanUsageReader.claudeFiles(legacy: false).contains { $0.path.contains("/Caches/Paceline/") }
              && PlanUsageReader.claudeFiles(legacy: false).contains { $0.path.contains("/Caches/Pixpaw/") }
              && PlanUsageReader.antigravityFiles.contains { $0.path.contains("/Pixpaw/") },
              "Pixpaw's files are still read where Pixpaw writes them")
        let old = dir.appendingPathComponent("Caches/Paceline"), new = dir.appendingPathComponent("Application Support/Paceline")
        try? FileManager.default.createDirectory(at: old.appendingPathComponent("src"), withIntermediateDirectories: true)
        for name in ["claude-usage.json", "claude-usage-account2.json", "antigravity-usage.json", "assets-info.plist", "other.json"] {
            try? Data("old \(name)".utf8).write(to: old.appendingPathComponent(name))
        }
        let moved = DataFolder.migrate(from: old, to: new)
        func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
        check(moved == ["antigravity-usage.json", "claude-usage-account2.json", "claude-usage.json"]
              && text(new.appendingPathComponent("claude-usage.json")) == "old claude-usage.json"
              && !FileManager.default.fileExists(atPath: old.appendingPathComponent("claude-usage.json").path),
              "old plan files move over when the new folder has none")
        check(["assets-info.plist", "other.json", "src"].allSatisfy { FileManager.default.fileExists(atPath: old.appendingPathComponent($0).path) }
              && !FileManager.default.fileExists(atPath: new.appendingPathComponent("other.json").path),
              "nothing else in Caches is moved or deleted")
        try? Data("newer".utf8).write(to: new.appendingPathComponent("claude-usage.json"))
        try? Data("stale".utf8).write(to: old.appendingPathComponent("claude-usage.json"))
        check(DataFolder.migrate(from: old, to: new).isEmpty && text(new.appendingPathComponent("claude-usage.json")) == "newer"
              && text(old.appendingPathComponent("claude-usage.json")) == "stale",
              "an existing new file is never overwritten")
        check(DataFolder.migrate(from: dir.appendingPathComponent("missing"), to: new).isEmpty, "no old folder, nothing to do")

        let suite = "com.josakcat.paceline.selftest-\(UUID().uuidString)"
        guard let fake = UserDefaults(suiteName: suite) else { check(false, "throwaway defaults suite"); return failures }
        defer { fake.removePersistentDomain(forName: suite) }
        fake.setPersistentDomain(["showUSD": true], forName: suite)  // saved, as a real user's settings are
        DefaultsMigration.run(from: ["menuBarShows": "latest", "menuBarStyle": "tworows", "showUSD": false, "debugEndpoints": true,
                                     "pseudonymSalt": "x"], to: fake, domain: suite)
        check(fake.string(forKey: "menuBarShows") == "latest" && fake.string(forKey: "menuBarStyle") == "tworows", "old settings come over")
        // The saved domain, not object(forKey:): AppModel registered a debugEndpoints default above.
        let saved = fake.persistentDomain(forName: suite) ?? [:]
        check(fake.bool(forKey: "showUSD") && saved["debugEndpoints"] == nil && saved["pseudonymSalt"] == nil,
              "a value already set stays; debugEndpoints and the old app's keys don't come")
        DefaultsMigration.run(from: ["menuBarShows": "all"], to: fake, domain: suite)
        check(fake.string(forKey: "menuBarShows") == "latest", "it runs once")
        return failures
    }

    /// Pace: the rate since the window began, carried to the reset.
    static func paceTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  pace: \(what)")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func window(_ label: String = "5h", left: Int, resetsIn: TimeInterval?) -> PlanWindow {
            PlanWindow(label: label, left: left, resets: resetsIn.map { now.addingTimeInterval($0) })
        }
        // 60% used in the first 2 hours: 30%/h, the last 40% lasts 1h 20m, 3 hours before the reset.
        let fast = window(left: 40, resetsIn: 3 * 3600).pace(now: now)
        check(fast == .runsOut(in: 4800), "60% in 2h of 5h runs out in 1h 20m → \(String(describing: fast))")
        check(PlanWindow.duration(4800) == "1h 20m" && PlanWindow.duration(1500) == "25m" && PlanWindow.duration(2 * 86400 + 3 * 3600) == "2d 3h", "durations")
        check(window(left: 50, resetsIn: 2 * 3600).pace(now: now) == .onPace, "50% in 3h of 5h is on pace")
        check(window(left: 40, resetsIn: 4 * 3600).pace(now: now) == nil, "an hour into 5h (under a quarter): no call")
        // From real data: 42 minutes into a 5-hour window, 14% used, said "runs out in 4h 15m".
        check(window(left: 86, resetsIn: 4 * 3600 + 18 * 60).pace(now: now) == nil, "42 minutes into 5h: no call")
        // 60% used 2h 58m 12s in: empty 7128 s from now, 3 minutes before the 7308 s reset.
        check(window(left: 40, resetsIn: 7308).pace(now: now) == .onPace, "running out only 3 minutes before the reset: on pace")
        check(window(left: 100, resetsIn: 3600).pace(now: now) == nil, "nothing used: no call")
        check(window(left: 40, resetsIn: nil).pace(now: now) == nil, "no reset time: no call")
        check(window("Week", left: 20, resetsIn: 3 * 86400).pace(now: now) == .runsOut(in: 0.2 / (0.8 / (4 * 86400)) ), "a week: 80% in 4 days runs out in a day")
        let fresh = PlanUsage(agent: "Claude", windows: [window(left: 40, resetsIn: 3 * 3600)], at: now)
        let old = PlanUsage(agent: "Claude", windows: [window(left: 40, resetsIn: 3 * 3600)], at: now.addingTimeInterval(-7 * 3600))
        check(fresh.pace(fresh.windows[0], now: now) != nil && old.pace(old.windows[0], now: now) == nil, "old data: no call")
        let rows = AppModel.planRows([fresh], now: now)
        check(rows.first?.runsOut == 4800 && rows.first?.warn == true && rows.first?.low == false, "a 40% window on course to run out warns (orange), isn't low")
        let reading = AIReading(name: "Claude", text: "40%", low: false, lastActive: nil, rows: rows)
        check(AIReading.tooltip([reading]) == "Claude: 5h 40% left, runs out in 1h 20m", "tooltip → \(AIReading.tooltip([reading]))")
        check(AIReading.spoken([reading]) == "Claude 5-hour 40% left, runs out in 1h 20m", "VoiceOver → \(AIReading.spoken([reading]))")

        // Lately counts for half. All these are 5h windows; `ago` is from now.
        func sample(_ ago: TimeInterval, _ used: Int) -> PaceSample { PaceSample(at: now.addingTimeInterval(-ago), used: used) }
        func near(_ pace: PlanWindow.Pace?, _ seconds: TimeInterval) -> Bool {
            if case .runsOut(let t)? = pace { return abs(t - seconds) < 1 } else { return false }
        }
        // 70% in the first hour of three, then nothing: the average says it runs out, lately says stopped.
        let stopped = window(left: 30, resetsIn: 2 * 3600)
        check(stopped.pace(now: now) != .onPace && stopped.pace(now: now, samples: [sample(2.5 * 3600, 35), sample(2 * 3600, 70)]) == .onPace,
              "heavy early, then stopped 2h ago: on pace, not runs out")
        // 10% in two hours, then 45% in the last hour: the average says on pace, lately says it runs out.
        let rushed = window(left: 45, resetsIn: 2 * 3600)
        let rushedPace = rushed.pace(now: now, samples: [sample(2 * 3600, 8), sample(3600, 10), sample(600, 50)])
        let average: TimeInterval = 55.0 / 10800, lately: TimeInterval = 45.0 / 3600
        check(rushed.pace(now: now) == .onPace && near(rushedPace, 45 / ((average + lately) / 2)),
              "light, then 45% in the last hour: runs out in \(String(describing: rushedPace))")
        // Steady 30%/h: the same as the average alone.
        check(near(window(left: 40, resetsIn: 3 * 3600).pace(now: now, samples: [sample(5400, 15), sample(3600, 30), sample(1800, 45)]), 4800),
              "steady use: the same 1h 20m as before")
        // Little to go on: readings only within the last hour, or none older than the round.
        check(near(window(left: 40, resetsIn: 3 * 3600).pace(now: now, samples: [sample(1800, 50)]), 4800)
              && near(window(left: 40, resetsIn: 3 * 3600).pace(now: now, samples: [sample(3 * 3600, 90)]), 4800),
              "only recent readings, or last round's: the average, as before")
        check(window(left: 40, resetsIn: 4 * 3600).pace(now: now, samples: [sample(2400, 10), sample(600, 60)]) == nil,
              "under a quarter in: still no call, whatever the readings")

        // The log: one reading per 1% of the window, 40 at most, a new round starts over.
        let resets = now.addingTimeInterval(3600)
        var log = PaceLog()
        for minute in 0..<240 {
            let at: Date = now.addingTimeInterval(Double(minute - 240) * 60)
            let left: Int = 100 - minute / 4
            log = log.recording([PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: left, resets: resets)], at: at)])
        }
        let latest = PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 41, resets: resets.addingTimeInterval(30))], at: now)
        let logged = log.recording([latest]).attached(to: [latest])[0].paceSamples["5h"] ?? []
        let gaps: [TimeInterval] = zip(logged, logged.dropFirst()).map { pair in pair.1.at.timeIntervalSince(pair.0.at) }
        let spaced: Bool = gaps.dropLast().allSatisfy { gap in gap >= 180 }
        let newest: Bool = logged.last == PaceSample(at: now, used: 59)
        check(logged.count <= PaceLog.kept && logged.count > 20 && newest && spaced,
              "the log keeps \(logged.count) readings ≥ 3 minutes apart, the newest last")
        let next = PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 95, resets: resets.addingTimeInterval(5 * 3600))], at: now.addingTimeInterval(4000))
        check(log.recording([next]).attached(to: [next])[0].paceSamples["5h"]?.count == 1
              && log.attached(to: [PlanUsage(agent: "Codex", windows: latest.windows, at: now)])[0].paceSamples.isEmpty,
              "a new round starts over; another AI has its own log")
        let idle = PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: 30, resets: now.addingTimeInterval(2 * 3600))], at: now.addingTimeInterval(-2 * 3600))
        let idleLogged = PaceLog().recording([idle]).attached(to: [idle])[0]
        check(idle.pace(idle.windows[0], now: now) != .onPace && idleLogged.pace(idleLogged.windows[0], now: now) == .onPace,
              "a reading 2 hours old, opened now: nothing used since, on pace")
        return failures
    }

    /// Plan alerts: each threshold once a round, the soon-to-run-out warning, the reset.
    static func alertTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  alerts: \(what)")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resets = now.addingTimeInterval(600)   // 4h 50m in: low but on pace, so only thresholds speak
        func claude(_ left: Int, resets: Date = resets, at: Date = now) -> [PlanUsage] {
            [PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: left, resets: resets)], at: at)]
        }
        var due = PlanAlerts.due(claude(50), sent: [], now: now)
        var alerts: [PlanAlerts.Alert] = due.alerts, sent: Set<String> = due.sent
        check(alerts.isEmpty, "50% left: nothing")
        due = PlanAlerts.due(claude(18), sent: sent, now: now)
        (alerts, sent) = (due.alerts, due.sent)
        check(alerts.map(\.title) == ["Claude: 18% of the 5-hour limit left"] && alerts.first?.body == "Resets in 10m.", "crossing 20% → \(alerts.map(\.title))")
        due = PlanAlerts.due(claude(16), sent: sent, now: now)
        (alerts, sent) = (due.alerts, due.sent)
        check(alerts.isEmpty, "still under 20%: not again")
        due = PlanAlerts.due(claude(9), sent: sent, now: now)
        (alerts, sent) = (due.alerts, due.sent)
        check(alerts.map(\.title) == ["Claude: 9% of the 5-hour limit left"], "crossing 10% → \(alerts.map(\.title))")
        let (jump, jumped) = PlanAlerts.due(claude(8), sent: [], now: now)
        check(jump.count == 1 && jump.first?.id.hasSuffix("|10") == true && jumped.contains { $0.hasSuffix("|20") }, "straight past both: one alert, both marked")
        // 95% gone 4h into 5h: 23.75%/h, the last 5% lasts about 13 minutes.
        let soon = PlanAlerts.due(claude(5, resets: now.addingTimeInterval(3600)), sent: [], now: now).alerts.map(\.title)
        check(soon.contains("Claude: 5-hour limit runs out in 12m"), "runs out within 30 minutes → \(soon)")
        let later = now.addingTimeInterval(600 + 60)
        due = PlanAlerts.due(claude(100, resets: later.addingTimeInterval(5 * 3600), at: later), sent: sent, now: later)
        (alerts, sent) = (due.alerts, due.sent)
        check(alerts.map(\.title) == ["Claude: 5-hour limit reset"], "the low round reset → \(alerts.map(\.title))")
        due = PlanAlerts.due(claude(100, resets: later.addingTimeInterval(5 * 3600), at: later), sent: sent, now: later)
        (alerts, sent) = (due.alerts, due.sent)
        check(alerts.isEmpty, "the reset is said once")
        check(PlanAlerts.due(claude(5, at: now.addingTimeInterval(-7 * 3600)), sent: [], now: now).alerts.isEmpty, "old data: nothing")
        return failures
    }

    /// Extra Claude accounts: safe ids, the AgentPet-era account2 listed on its
    /// own, CLAUDE_CONFIG_DIR → the right file, badges in order, and a status
    /// line added without replacing one. A throwaway suite and temp folders only.
    static func claudeAccountTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  accounts list: \(what)")
        }
        check(ClaudeAccounts.slug("Work Team/../x") == "work-team-x" && ClaudeAccounts.slug("..") == "account" && ClaudeAccounts.slug("งาน") == "account",
              "slugs keep to a-z, 0-9 and dashes → \(ClaudeAccounts.slug("Work Team/../x"))")
        let work = ClaudeAccount(id: "work", name: "Work", configDir: "/tmp/paceline-test/.claude-work")
        check(ClaudeAccounts.newID(for: "Work", existing: [work]) == "work-2", "a taken id gets a number")
        let file = PlanUsageReader.claudeFile(account: ClaudeAccounts.slug("../../etc/passwd"))
        check(file.deletingLastPathComponent() == PlanUsageReader.ownClaudeFile.deletingLastPathComponent() && file.lastPathComponent == "claude-usage-etc-passwd.json",
              "its file stays in the cache folder → \(file.lastPathComponent)")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-accounts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let suite = "com.josakcat.paceline.selftest-\(UUID().uuidString)"
        guard let fake = UserDefaults(suiteName: suite) else { check(false, "throwaway defaults suite"); return failures }
        defer { fake.removePersistentDomain(forName: suite) }
        check(ClaudeAccounts.load(fake, home: tmp, legacy: true).isEmpty, "nothing saved, no ~/.claude-account2: no accounts")
        try? FileManager.default.createDirectory(at: tmp.appendingPathComponent(".claude-account2"), withIntermediateDirectories: true)
        check(ClaudeAccounts.load(fake, home: tmp, legacy: false).isEmpty, "a Mac that never had AgentPet: ~/.claude-account2 isn't added by itself")
        let legacy = ClaudeAccounts.load(fake, home: tmp, legacy: true)
        check(legacy.map(\.id) == ["account2"] && legacy.first?.name == "Claude 2" && legacy.first?.configDir == tmp.appendingPathComponent(".claude-account2").path,
              "where AgentPet was, ~/.claude-account2 shows up as Claude 2 (account2)")
        ClaudeAccounts.save([], fake)
        check(ClaudeAccounts.load(fake, home: tmp, legacy: true).isEmpty, "once the list is saved (removed), it stays removed")
        ClaudeAccounts.save([work], fake)
        check(ClaudeAccounts.load(fake, home: tmp, legacy: true) == [work], "a saved list comes back")

        check(PlanUsageReader.statusLineFile(configDir: "/tmp/paceline-test/sub/../.claude-work/", accounts: [work])?.lastPathComponent == "claude-usage-work.json",
              "CLAUDE_CONFIG_DIR of a listed account (with ../ and a trailing /) → that account's file")
        check(PlanUsageReader.statusLineFile(configDir: nil, accounts: [work]) == PlanUsageReader.ownClaudeFile
              && PlanUsageReader.statusLineFile(configDir: "~/.claude", accounts: [work]) == PlanUsageReader.ownClaudeFile
              && PlanUsageReader.statusLineFile(configDir: NSHomeDirectory() + "/.claude/", accounts: [work]) == PlanUsageReader.ownClaudeFile,
              "no CLAUDE_CONFIG_DIR, or ~/.claude → the main file")
        check(PlanUsageReader.statusLineFile(configDir: "/tmp/paceline-test/.claude-elsewhere", accounts: [work]) == nil
              && PlanUsageReader.statusLineFile(configDir: "/tmp/paceline-test/.claude-work", accounts: []) == nil,
              "a folder not in the list → nothing saved")

        let home2 = ClaudeAccount(id: "home", name: "Home", configDir: "/tmp/paceline-test/.claude-home")
        check(ClaudeAccounts.badge(for: "Work", in: [work, home2]) == "2" && ClaudeAccounts.badge(for: "Home", in: [work, home2]) == "3"
              && ClaudeAccounts.badge(for: "Claude", in: [work, home2]) == nil, "badges 2, 3 in list order")
        let model = AppModel()
        model.claudeAccounts = [work, home2]
        model.plans = ["Claude", "Home", "Work"].map { PlanUsage(agent: $0, windows: [PlanWindow(label: "5h", left: 50, resets: nil)], at: Date()) }
        let readings = model.aiReadings
        check(readings.map(\.name) == ["Claude", "Work", "Home"] && readings.map(\.badge) == [nil, "2", "3"] && readings.map(\.short) == ["CC", "C2", "C3"],
              "readings follow the list, named and badged → \(readings.map { "\($0.name) \($0.badge ?? "-")" })")

        // settings.json: added beside what's there, never over a status line, never into junk.
        let dir = tmp.appendingPathComponent(".claude-work")
        check(ClaudeAccounts.addStatusLine(command: "pl --statusline", toSettingsIn: dir) == .noFolder, "no folder yet: nothing written")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        func json() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:] }
        check(ClaudeAccounts.addStatusLine(command: "pl --statusline", toSettingsIn: dir) == .added
              && (json()["statusLine"] as? [String: String]) == ["type": "command", "command": "pl --statusline"], "no settings.json: one with the status line")
        try? Data(#"{"model":"opus"}"#.utf8).write(to: settings)
        check(ClaudeAccounts.addStatusLine(command: "pl --statusline", toSettingsIn: dir) == .added && json()["model"] as? String == "opus"
              && json()["statusLine"] != nil, "other settings stay")
        let mine = Data(#"{"statusLine":{"type":"command","command":"mine"}}"#.utf8)
        try? mine.write(to: settings)
        check(ClaudeAccounts.addStatusLine(command: "pl --statusline", toSettingsIn: dir) == .alreadySet && (try? Data(contentsOf: settings)) == mine,
              "a status line already there isn't replaced")
        try? Data("not json".utf8).write(to: settings)
        check(ClaudeAccounts.addStatusLine(command: "pl --statusline", toSettingsIn: dir) == .unreadable
              && (try? Data(contentsOf: settings)) == Data("not json".utf8), "a file that isn't JSON is left alone")
        return failures
    }

    /// What to suggest from made-up sign-in states, the ~/.claude-* search in a
    /// temp "home", and dismissing.
    static func suggestionTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  suggestions: \(what)")
        }
        let accounts = [AccountInfo(agent: "Claude", status: "someone@example.com"), AccountInfo(agent: "Codex", status: "Not signed in"),
                        AccountInfo(agent: "Antigravity", status: "Installed"), AccountInfo(agent: "Work", status: "Not signed in")]
        let made = Suggestions.make(accounts: accounts, found: [("/tmp/home/.claude-team", "team@example.com")])
        check(made.map(\.id) == ["signin|Codex", "open|Antigravity", "add|/tmp/home/.claude-team"], "signed out, app to open, found folder → \(made.map(\.id))")
        check(made.first?.action == .signIn(.init("codex login")) && made.last?.action == .addAccount(dir: "/tmp/home/.claude-team", name: "Team"),
              "codex login; the found folder is named Team")
        let none = Suggestions.make(accounts: [AccountInfo(agent: "Claude", status: "Not installed"), AccountInfo(agent: "Codex", status: "Not installed"),
                                               AccountInfo(agent: "Antigravity", status: "Not installed")], found: [])
        check(none.isEmpty, "nothing installed: nothing to suggest")
        let claude = Suggestions.make(accounts: [AccountInfo(agent: "Claude", status: "Not signed in"), AccountInfo(agent: "Codex", status: "Installed")], found: [])
        check(claude.map(\.id) == ["signin|Claude", "open|Codex"] && claude.first?.action == .signIn(.init("claude auth login")), "Claude signed out; Codex app only → open it")

        var (shown, dismissed) = Suggestions.visible(made, dismissed: ["signin|Codex", "open|Gone"])
        check(shown.map(\.id) == ["open|Antigravity", "add|/tmp/home/.claude-team"] && dismissed == ["signin|Codex"],
              "dismissed stays hidden; a dismissal whose problem is gone is dropped")
        (shown, dismissed) = Suggestions.visible(Array(made.dropFirst()), dismissed: dismissed)   // Codex signed in
        check(dismissed.isEmpty, "signed in: its dismissal goes")
        (shown, dismissed) = Suggestions.visible(made, dismissed: dismissed)   // signed out again
        check(shown.first?.id == "signin|Codex", "signed out again: it shows again")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-found-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func folder(_ name: String, oauth: Bool) {
            let dir = home.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = oauth ? #"{"oauthAccount":{"emailAddress":"\#(name)@example.com"}}"# : #"{"numStartups":1}"#
            try? Data(json.utf8).write(to: dir.appendingPathComponent(".claude.json"))
        }
        folder(".claude-work", oauth: true)
        folder(".claude-empty", oauth: false)
        folder(".claude-listed", oauth: true)
        folder(".claudework", oauth: true)
        try? Data("x".utf8).write(to: home.appendingPathComponent(".claude-file"))
        let listed = [ClaudeAccount(id: "listed", name: "Listed", configDir: home.appendingPathComponent(".claude-listed").path)]
        let found = Suggestions.foundClaude(home: home, listed: listed)
        check(found.map { ($0.dir as NSString).lastPathComponent } == [".claude-work"] && found.first?.email == ".claude-work@example.com",
              "only signed-in, unlisted ~/.claude-* folders → \(found.map { ($0.dir as NSString).lastPathComponent })")
        check(ClaudeAccounts.nameProblem("Work", existing: []) == nil && ClaudeAccounts.nameProblem("Codex", existing: []) != nil
              && ClaudeAccounts.nameProblem(" ", existing: []) != nil, "names: taken and empty ones are refused")
        return failures
    }

    /// Fetch fresh numbers: get_usage's answer, who's due, and Antigravity's
    /// table from either file. Made-up data and temp files only.
    static func freshTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  fresh: \(what)")
        }
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"paceline-1","response":{"subscription_type":"pro","rate_limits":{"five_hour":{"utilization":66,"resets_at":"2026-11-08T06:40:00.287921+00:00"},"seven_day":{"utilization":12,"resets_at":"2026-11-14T19:00:00+00:00"},"extra_usage":{"utilization":null}}}}}"#
        let limits = FreshLimits.rateLimits(inLine: Data(line.utf8), id: "paceline-1")
        check(limits != nil && FreshLimits.rateLimits(inLine: Data(line.utf8), id: "other") == nil, "the control_response for our request id")
        let windows = limits.flatMap(FreshLimits.windows(fromUsage:))
        func value(_ key: String, _ field: String) -> Double? { ((windows?[key] as? [String: Any])?[field] as? NSNumber)?.doubleValue }
        check(value("five_hour", "used") == 66 && value("seven_day", "used") == 12, "utilization → used 66 / 12")
        check(value("five_hour", "resets_at").map { Int($0) } == 1_794_120_000 && value("seven_day", "resets_at").map { Int($0) } == 1_794_682_800,
              "resets_at, with or without fractions → epoch seconds")
        check(FreshLimits.windows(fromUsage: [:]) == nil, "an empty answer saves nothing (asked again later)")
        let saved = windows.map { $0.merging(["saved_at": 1_794_100_000.0]) { $1 } } ?? [:]
        let plan = PlanUsageReader.claude(saved, agent: "Claude", now: Date(timeIntervalSince1970: 1_794_100_060))
        check(plan?.window("5h")?.left == 34 && plan?.window("Week")?.left == 88, "saved like the status line: 5h 34% · Week 88% left")
        // Fable's weekly cap: get_usage's model_scoped row named "Fable" → a "Fable week" window, shown only when there.
        check(plan?.window(PlanWindow.fableWeek) == nil && AppModel.planSummary([plan].compactMap { $0 }) == "5h 34% · Week 88% left",
              "no model_scoped: no Fable week")
        let scoped: [String: Any] = ["seven_day": ["utilization": 12, "resets_at": "2026-11-14T19:00:00+00:00"],
                                     "model_scoped": [["display_name": "Opus", "utilization": 50, "resets_at": NSNull()],
                                                      ["display_name": "Fable", "utilization": 40, "resets_at": "2026-11-15T02:00:00Z"]]]
        let fableSaved = (FreshLimits.windows(fromUsage: scoped) ?? [:]).merging(["saved_at": 1_794_100_000.0]) { $1 }
        let fableNow = Date(timeIntervalSince1970: 1_794_100_060)
        let fablePlan = PlanUsageReader.claude(fableSaved, agent: "Claude", now: fableNow)
        let fable = fablePlan?.window(PlanWindow.fableWeek)
        check(fable?.left == 60 && fable?.resets.map { Int($0.timeIntervalSince1970) } == 1_794_708_000 && fable?.length == 7 * 86400
              && fablePlan?.windows.map(\.label) == ["Week", PlanWindow.fableWeek],
              "model_scoped Fable 40% used → Fable week 60% left, under Week, a 7-day round")
        check(AppModel.planSummary([fablePlan].compactMap { $0 }) == "Week 88% · Fable week 60% left", "Accounts ⓘ: Week 88% · Fable week 60% left")
        let kept = PlanUsageReader.merged(["five_hour": ["used": 10, "resets_at": 1_794_110_000]], into: fableSaved)
        check(kept["seven_day_fable"] != nil, "a status-line update (5h and week only) keeps the fetched Fable week")
        let lowFable = PlanUsage(agent: "Claude", windows: [PlanWindow(label: "Week", left: 80, resets: fableNow.addingTimeInterval(86400)),
                                                            PlanWindow(label: PlanWindow.fableWeek, left: 5, resets: fableNow.addingTimeInterval(86400))], at: fableNow)
        check(PlanAlerts.due([lowFable], sent: [], now: fableNow).alerts.isEmpty, "Fable week at 5% left sends no alert (panel only)")
        // Two files for one account: a newer status-line one (no Fable) and an older fetched one with Fable.
        let twoDir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-two-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: twoDir, withIntermediateDirectories: true)
        func twoFile(_ name: String, _ json: [String: Any]) -> URL {
            let url = twoDir.appendingPathComponent(name)
            try? JSONSerialization.data(withJSONObject: json).write(to: url)
            return url
        }
        let t = fableNow.timeIntervalSince1970
        let newer = twoFile("new.json", ["saved_at": t - 60, "five_hour": ["used": 30, "resets_at": t + 3600], "seven_day": ["used": 20, "resets_at": t + 86400]])
        let olderFable = twoFile("old.json", ["saved_at": t - 3000, "fetched": true, "five_hour": ["used": 90, "resets_at": t + 3600],
                                              "seven_day": ["used": 90, "resets_at": t + 86400], "seven_day_fable": ["used": 40, "resets_at": t + 86400]])
        let olderReset = twoFile("reset.json", ["saved_at": t - 3000, "seven_day": ["used": 90, "resets_at": t + 86400],
                                                "seven_day_fable": ["used": 40, "resets_at": t - 60]])
        let both = PlanUsageReader.newest([olderFable, newer], agent: "Claude", now: fableNow)
        check(both?.window("5h")?.left == 70 && both?.window("Week")?.left == 80 && both?.window(PlanWindow.fableWeek)?.left == 60
              && both?.windows.map(\.label) == ["5h", "Week", PlanWindow.fableWeek]
              && both?.at == Date(timeIntervalSince1970: t - 60) && both?.fetched == false,
              "newest file without Fable + older with Fable → 5h/Week from the newest, Fable week from the older; its time kept")
        check(PlanUsageReader.newest([olderReset, newer], agent: "Claude", now: fableNow)?.window(PlanWindow.fableWeek) == nil,
              "an older file's Fable week that has reset since isn't borrowed")
        let plain = twoFile("plain.json", ["saved_at": t - 3000, "seven_day": ["used": 90, "resets_at": t + 86400]])
        check(PlanUsageReader.newest([plain, newer], agent: "Claude", now: fableNow)?.windows.map(\.label) == ["5h", "Week"],
              "neither file has Fable → no Fable week")
        try? FileManager.default.removeItem(at: twoDir)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let targets = [FreshLimits.Target(id: "claude", kind: .claude(configDir: nil), at: now.addingTimeInterval(-20 * 60)),
                       FreshLimits.Target(id: "work", kind: .claude(configDir: "/tmp/w"), at: now.addingTimeInterval(-5 * 60)),
                       FreshLimits.Target(id: "antigravity", kind: .antigravity, at: nil)]
        check(FreshLimits.due(targets, lastAsked: [:], now: now).map(\.id) == ["claude", "antigravity"], "old or missing plans are due; a fresh one isn't")
        check(FreshLimits.due(targets, lastAsked: ["claude": now.addingTimeInterval(-60)], now: now).map(\.id) == ["antigravity"],
              "asked a minute ago: not again for 15 minutes")
        check(FreshLimits.due(targets, lastAsked: ["claude": now.addingTimeInterval(-16 * 60)], now: now).map(\.id) == ["claude", "antigravity"],
              "15 minutes later: asked again")
        check(FreshLimits.due(targets, lastAsked: [:], emptyAt: ["claude": now.addingTimeInterval(-3600)], now: now).map(\.id) == ["antigravity"],
              "answered empty an hour ago: left alone")
        check(FreshLimits.due(targets, lastAsked: [:], emptyAt: ["claude": now.addingTimeInterval(-7 * 3600)], now: now).map(\.id) == ["claude", "antigravity"],
              "answered empty 7 hours ago: asked again")
        check(FreshLimits.due(targets, lastAsked: [:], emptyAt: ["work": now.addingTimeInterval(-3600)], now: now).map(\.id) == ["claude", "antigravity"],
              "another account's empty answer doesn't hold this one back")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-fresh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func table(_ name: String, at: Double, left: Int) -> URL {
            let url = dir.appendingPathComponent(name)
            let text = "Gemini Models\tFive Hour Limit Remaining\t\(left)%\t2026-11-08T08:46:32Z\nGemini Models\tWeekly Limit Remaining\t90%\t2026-11-15T03:46:32Z\n"
            try? JSONSerialization.data(withJSONObject: ["at": at, "table": text]).write(to: url)
            return url
        }
        let mine = table("mine.json", at: now.timeIntervalSince1970 - 60, left: 70), pixpaw = table("pixpaw.json", at: now.timeIntervalSince1970 - 3600, left: 40)
        let ag = PlanUsageReader.antigravity(now: now, files: [mine, pixpaw])
        check(ag.first?.group == "Gemini" && ag.first?.windows.map(\.label) == ["5h", "Week"], "agy's table → Gemini 5h and Week")
        check(PlanUsageReader.antigravity(now: now, files: [pixpaw, mine]).first?.at == Date(timeIntervalSince1970: now.timeIntervalSince1970 - 60),
              "the newer of Paceline's and Pixpaw's files wins")
        check(PlanUsageReader.antigravity(now: now, files: [dir.appendingPathComponent("none.json"), pixpaw]).first?.at
              == Date(timeIntervalSince1970: now.timeIntervalSince1970 - 3600), "Pixpaw's alone still works")
        return failures
    }

    /// Round B: the history's days, version numbers, the new prices.
    static func roundBTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  history/updates/prices: \(what)")
        }
        // History: today's totals replace, the lows only go down, past 30 days go.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
        let plan = { (left5h: Int, at: Date) in [PlanUsage(agent: "Claude", windows: [PlanWindow(label: "5h", left: left5h, resets: now.addingTimeInterval(3600)),
                                                                                       PlanWindow(label: "Week", left: 80, resets: now.addingTimeInterval(86400))], at: at)] }
        var history = UsageHistory()
        history.days["2026-10-01"] = ["Claude": DayRecord(tokens: 1, usd: 1)]
        history = history.recording(usage: ["Claude": (100, 1.0), "Codex": (0, 0)], plans: plan(40, now), now: now)
        history = history.recording(usage: ["Claude": (250, 2.5)], plans: plan(55, now), now: now)
        let today = history.days["2026-11-08"]?["Claude"]
        check(today == DayRecord(tokens: 250, usd: 2.5, low5h: 40, lowWeek: 80), "today's totals replace; the 5h low stays 40 → \(String(describing: today))")
        check(history.days["2026-11-08"]?["Codex"] == nil, "nothing used, nothing recorded")
        check(history.days["2026-10-01"] == nil, "a day 38 days back is dropped")
        let stale = UsageHistory().recording(usage: [:], plans: plan(5, now.addingTimeInterval(-7 * 3600)), now: now)
        check(stale.days.isEmpty, "an old plan isn't today's low")
        let week = history.last(7, now: now)
        check(week.count == 7 && UsageHistory.key(week.last!.day) == "2026-11-08" && UsageHistory.key(week.first!.day) == "2026-11-02"
              && week.dropLast().allSatisfy { $0.records.isEmpty }, "the last 7 days, oldest first, empty days included")

        // Updates: tags compared number by number.
        check(Updates.isNewer("v0.2.0", than: "0.1.0") && Updates.isNewer("0.1.10", than: "0.1.9") && Updates.isNewer("v1.0", than: "0.9.9"), "newer versions")
        check(!Updates.isNewer("v0.1.0", than: "0.1.0") && !Updates.isNewer("0.1", than: "0.1.0") && !Updates.isNewer("0.0.9", than: "0.1.0"), "same or older isn't")

        // Prices: Gemini by date, OpenAI by exact id, unknown stays unknown.
        let nov = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8))!, jan = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2))!
        check(Pricing.price(for: "gemini-3.8-flash-n", on: nov)?.input == 0.75 && Pricing.price(for: "gemini-3.8-flash", on: jan)?.input == 1.5,
              "Gemini 3.8 Flash $0.75 → $1.50 from 2027")
        check(Pricing.price(for: "gemini-4-argon", on: nov)?.output == 10 && Pricing.price(for: "gemini-3.8-flash-tts", on: nov) == nil,
              "Gemini 4 Argon; TTS models aren't priced")
        check(Pricing.price(for: "gpt-5.5")?.output == 30 && Pricing.price(for: "gpt-5.3-codex")?.cacheRead == 0.175 && Pricing.price(for: "gpt-5")?.input == 1.25,
              "GPT-5.5, GPT-5.3 Codex, GPT-5")
        check(Pricing.price(for: "gpt-5-codex") == nil && Pricing.price(for: "gpt-5.5-mini") == nil, "ids not on the page stay unknown")
        var codex = SourceUsage(source: "Codex", accuracy: .exact)
        codex.byModel = ["gpt-5.5": TokenCounts(input: 1_000_000, output: 100_000, cacheRead: 2_000_000), "gpt-5-codex": TokenCounts(input: 1_000_000)]
        check(abs(codex.usd - (5 + 3 + 1)) < 0.0001 && codex.unpricedModels == ["gpt-5-codex"], "Codex $ from known prices; the rest listed as unknown → \(codex.usd)")
        return failures
    }

    /// OpenCode from a made-up data folder (both database shapes and the JSON
    /// files), Cursor from a made-up state.vscdb, and what they suggest.
    static func roundCTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  opencode/cursor: \(what)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-oc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("storage/message/ses_1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func database(_ name: String, _ statements: [String]) {
            var db: OpaquePointer?
            guard sqlite3_open(dir.appendingPathComponent(name).path, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            for sql in statements { sqlite3_exec(db, sql, nil, nil, nil) }
        }
        let now = Date(), dayStart = Calendar.current.startOfDay(for: now)
        let today = Int(max(now.addingTimeInterval(-60), dayStart).timeIntervalSince1970 * 1000), yesterday = Int(dayStart.timeIntervalSince1970 * 1000) - 3_600_000
        func v2(_ id: String, _ at: Int, _ model: String, cost: Double) -> String {
            #"{"id":"\#(id)","type":"assistant","model":{"id":"\#(model)","providerID":"anthropic"},"cost":\#(cost),"tokens":{"input":1000,"output":200,"reasoning":50,"cache":{"read":3000,"write":400}},"time":{"created":\#(at)}}"#
        }
        func v1(_ id: String, _ at: Int, _ model: String) -> String {
            #"{"id":"\#(id)","role":"assistant","modelID":"\#(model)","providerID":"openai","cost":0,"tokens":{"input":500,"output":100,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":\#(at)}}"#
        }
        database("opencode.db", [
            "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT, time_created INTEGER)",
            "INSERT INTO session_message VALUES ('msg_1','ses_1','assistant','\(v2("msg_1", today, "claude-sonnet-5", cost: 0.42))',\(today))",
            "INSERT INTO session_message VALUES ('msg_2','ses_1','assistant','\(v2("msg_2", yesterday, "claude-sonnet-5", cost: 9))',\(yesterday))",
            "INSERT INTO session_message VALUES ('msg_3','ses_1','user','{\"type\":\"user\",\"time\":{\"created\":\(today)}}',\(today))",
        ])
        database("opencode-beta.db", [
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT)",
            "INSERT INTO message VALUES ('msg_4','ses_2','\(v1("msg_4", today, "gpt-5.4"))')",
        ])
        try? Data(v1("msg_5", today, "gpt-5.4").utf8).write(to: dir.appendingPathComponent("storage/message/ses_1/msg_5.json"))
        try? Data(v2("msg_1", today, "claude-sonnet-5", cost: 0.42).utf8).write(to: dir.appendingPathComponent("storage/message/ses_1/msg_1.json"))   // also in the db
        let source = OpenCodeSource(root: dir)
        check(source.isInstalled && source.databases.count == 2, "databases found (opencode.db and a channel's)")
        let usage = source.usage(since: dayStart)
        let sonnet = usage.byModel["claude-sonnet-5"], gpt = usage.byModel["gpt-5.4"]
        check(sonnet?.messages == 1 && sonnet?.input == 1000 && sonnet?.output == 250 && sonnet?.cacheRead == 3000 && sonnet?.cacheWrite == 400,
              "today's new-format message once (yesterday's and the JSON copy left out), reasoning counted as output")
        check(gpt?.messages == 2 && gpt?.input == 1000, "old-format rows and JSON files both read → \(gpt?.messages ?? 0) messages")
        check(abs((usage.costs["claude-sonnet-5"] ?? 0) - 0.42) < 0.0001 && usage.costs["gpt-5.4"] == nil, "OpenCode's own cost is kept; a $0 cost isn't")
        check(abs(usage.usd - (0.42 + (1000 * 2.5 + 200 * 15) / 1_000_000)) < 0.0001 && usage.unpricedModels.isEmpty,
              "$: recorded cost, else list price → \(usage.usd)")
        check(OpenCodeLog.message(Data(v1("x", yesterday, "m").utf8), since: dayStart) == nil, "a message from before today isn't counted")
        check(!OpenCodeSource(root: dir.appendingPathComponent("nothing")).isInstalled || OpenCodeSource.binary != nil, "an empty folder isn't OpenCode")
        check(AccountsReader.openCode(dataDir: dir, installed: true)?.status == "Not signed in", "no auth.json: not signed in")
        try? Data(#"{"anthropic":{"type":"oauth"}}"#.utf8).write(to: dir.appendingPathComponent("auth.json"))
        check(AccountsReader.openCode(dataDir: dir, installed: true)?.status == "Signed in" && AccountsReader.openCode(dataDir: dir, installed: false) == nil,
              "auth.json there: signed in (the file isn't opened); not installed: no row")

        // Cursor: only the email and plan rows are asked for; the token rows next to them never come out.
        database("state.vscdb", [
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
            "INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail','someone@example.com')",
            "INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType','pro_plus')",
            "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','SECRET-ACCESS')",
            "INSERT INTO ItemTable VALUES ('cursorAuth/refreshToken','SECRET-REFRESH')",
        ])
        let cursor = AccountsReader.cursor(state: dir.appendingPathComponent("state.vscdb"), installed: true)
        check(cursor == AccountInfo(agent: "Cursor", status: "someone@example.com", plan: "Pro Plus"), "Cursor: email and plan → \(cursor?.plan ?? "nil")")
        check(!AccountsReader.cursorKeys.contains { $0.lowercased().contains("token") } && !"\(String(describing: cursor))".contains("SECRET"),
              "Cursor: no token key asked for, none in the result")
        check(AccountsReader.cursor(state: dir.appendingPathComponent("none.vscdb"), installed: true)?.status == "Not signed in"
              && AccountsReader.cursor(state: dir.appendingPathComponent("none.vscdb"), installed: false) == nil, "Cursor: no state → not signed in; not installed → no row")

        let made = Suggestions.make(accounts: [AccountInfo(agent: "Cursor", status: "Not signed in"), AccountInfo(agent: "OpenCode", status: "Not signed in"),
                                               AccountInfo(agent: "Cursor", status: "Not installed")], found: [])
        check(made.map(\.id) == ["open|Cursor", "signin|OpenCode"] && made.last?.action == .signIn(.init("opencode auth login")),
              "signed out: open Cursor; opencode auth login → \(made.map(\.id))")
        return failures
    }

    /// Sign-in state from made-up files: no real account in here.
    static func accountTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  accounts: \(what)")
        }
        let json = #"{"numStartups":3,"oauthAccount":{"emailAddress":"someone@example.com","organizationName":"someone@example.com's Organization","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_5x","billingType":"stripe_subscription","seatTier":null}}"#
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let claude = AccountsReader.claude(parsed, agent: "Claude 2")
        check(claude == AccountInfo(agent: "Claude 2", status: "someone@example.com", plan: "Max 5x"), "oauthAccount → \(claude.status) · \(claude.plan ?? "nil")")
        let team = AccountsReader.claudePlan(["organizationType": "claude_team", "organizationName": "Acme", "seatTier": "team_premium"])
        check(team == "Team · Team Premium", "team plan with seat → \(team ?? "nil")")
        check(AccountsReader.claude(["numStartups": 1], agent: "Claude").status == "Not signed in", "no oauthAccount → Not signed in")
        check(AccountsReader.codexStatus("Logged in using an API key - sk-proj-***ABCDE") == "Signed in · API key", "codex: the key part is cut off")
        check(AccountsReader.codexStatus("Logged in using ChatGPT") == "Signed in · ChatGPT", "codex: ChatGPT → Signed in")
        check(AccountsReader.codexStatus("Not logged in") == "Not signed in", "codex: Not logged in → Not signed in")

        // Antigravity's userStatus: base64(proto{1:{2:{1: base64(proto{7: email, 36:{2: plan}})}}})
        func field(_ number: Int, _ data: Data) -> Data {
            var out = Data()
            func varint(_ v: Int) { var v = v; while v >= 0x80 { out.append(UInt8(v & 0x7F | 0x80)); v >>= 7 }; out.append(UInt8(v)) }
            varint(number << 3 | 2); varint(data.count); out.append(data)
            return out
        }
        let inner = field(3, Data("Some One".utf8)) + field(7, Data("someone@example.com".utf8)) + field(36, field(1, Data("g1-pro-tier".utf8)) + field(2, Data("Google AI Pro".utf8)))
        let status = field(1, field(1, Data("userStatusKey".utf8)) + field(2, field(1, Data(inner.base64EncodedString().utf8)))).base64EncodedString()
        let ag = AccountsReader.antigravity(userStatus: status)
        check(ag == AccountInfo(agent: "Antigravity", status: "someone@example.com", plan: "Google AI Pro"), "antigravity userStatus → \(ag?.plan ?? "nil")")
        check(AccountsReader.antigravity(userStatus: "not base64") == nil, "antigravity: junk → nil")
        return failures
    }

    /// `--render-icon <dir.iconset>`: the app icon at every size iconutil wants.
    static func renderIcon(to dir: String) -> Bool {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = points * scale
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let png = iconPNG(pixels: px) else { return false }
                do { try png.write(to: url.appendingPathComponent(name)) } catch { return false }
            }
        }
        print(dir)
        return true
    }

    /// Apple's grid: an 824/1024 rounded square with a soft shadow, mint, and
    /// the Paceline mark inside.
    static func iconPNG(pixels: Int) -> Data? {
        let s = CGFloat(pixels) / 1024
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: s, y: -s)  // 1024-point space, y down
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor(hex: 0x34D399).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        // Mint, a touch lighter at the top.
        let colors = [NSColor(hex: 0x3EE0A6).cgColor, NSColor(hex: 0x2BBF8A).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        }
        // The 130-unit design scaled to the 824 square, the chevrons' own middle
        // (62, 65) on the square's, a little larger to fill it.
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: 824 / 130 * 1.06, y: 824 / 130 * 1.06)
        ctx.translateBy(x: -62, y: -65)
        // Tiny sizes: the back chevrons darker and the strokes thicker.
        let tiny = pixels <= 64
        PacelineMark.draw(in: ctx, color: NSColor(hex: 0x0F3D2E), opacities: tiny ? PacelineMark.smallOpacities : PacelineMark.opacities,
                          lineWidth: tiny ? 13 : 11)
        ctx.restoreGState()
        ctx.restoreGState()

        // Hairline edge so the square keeps its outline on any dock.
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()

        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
