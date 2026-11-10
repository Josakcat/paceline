import Foundation

/// `PACELINE_DEMO=1`: made-up accounts, plans and usage, for screenshots.
/// Nothing on this Mac is read for them, and settings go to their own domain
/// (com.josakcat.paceline.demo), so the real ones are never touched.
enum Demo {
    static let isOn = ["1", "new", "switch"].contains(ProcessInfo.processInfo.environment["PACELINE_DEMO"])
    /// `PACELINE_DEMO=switch`: Claude's 5-hour limit low, so the panel suggests Work.
    static let isSwitch = ProcessInfo.processInfo.environment["PACELINE_DEMO"] == "switch"
    /// `PACELINE_DEMO=new`: a first launch instead. Nothing signed in, no plans or
    /// usage, and the account list kept (in the demo domain) so the Add Claude
    /// account guide can be tried end to end on made-up folders.
    static let isNewUser = ProcessInfo.processInfo.environment["PACELINE_DEMO"] == "new"

    /// Where the Add Claude account guide suggests folders: home, or in demo
    /// mode a made-up one in the temporary folder, so trying the guide never
    /// reads or writes a real ~/.claude-*.
    static var home: String {
        isOn ? (NSTemporaryDirectory() as NSString).appendingPathComponent("paceline-demo-home") : NSHomeDirectory()
    }

    /// Settings: the app's own domain, or the demo's.
    nonisolated(unsafe) static let defaults: UserDefaults = isOn ? (UserDefaults(suiteName: "com.josakcat.paceline.demo") ?? .standard) : .standard

    static let accounts = [ClaudeAccount(id: "work", name: "Work", configDir: NSHomeDirectory() + "/.claude-work")]

    static let signIns = [
        AccountInfo(agent: "Claude", status: "you@example.com", plan: "Pro"),
        AccountInfo(agent: "Work", status: "you@acme.example", plan: "Max 5x · Acme"),
        AccountInfo(agent: "Codex", status: "Signed in · ChatGPT"),
        AccountInfo(agent: "Antigravity", status: "you@example.com", plan: "Google AI Pro"),
        AccountInfo(agent: "Cursor", status: "you@example.com", plan: "Pro"),
        AccountInfo(agent: "OpenCode", status: "Signed in"),
        AccountInfo(agent: "Cline", status: "Installed · VS Code"),
        AccountInfo(agent: "Roo Code", status: "Installed · Cursor"),
        AccountInfo(agent: "Kilo Code", status: "Not installed"),
        AccountInfo(agent: "Gemini CLI", status: "you@example.com", plan: "Google account"),
        AccountInfo(agent: "Amp", status: "Signed in"),
        AccountInfo(agent: "GitHub Copilot", status: "Signed in"),
        AccountInfo(agent: AccountsReader.windsurfName, status: "Signed in", plan: "Pro"),
        AccountInfo(agent: "Kiro", status: "Not installed"),
    ]

    /// A new user's Mac: Claude Code, Codex and Gemini CLI installed but signed out, Antigravity's app only.
    static let newUserSignIns = [
        AccountInfo(agent: "Claude", status: "Not signed in"),
        AccountInfo(agent: "Codex", status: "Not signed in"),
        AccountInfo(agent: "Antigravity", status: "Installed"),
        AccountInfo(agent: "Cursor", status: "Not installed"),
        AccountInfo(agent: "Gemini CLI", status: "Not signed in"),
    ]

    /// Claude on pace, Work running out before its reset, the others comfortable.
    static func plans(now: Date = Date()) -> [PlanUsage] {
        if isNewUser { return [] }
        let at = now.addingTimeInterval(-120)
        func window(_ label: String, _ left: Int, resetsIn: TimeInterval) -> PlanWindow {
            PlanWindow(label: label, left: left, resets: now.addingTimeInterval(resetsIn))
        }
        return [
            PlanUsage(agent: "Claude", windows: [window("5h", isSwitch ? 12 : 62, resetsIn: 110 * 60), window("Week", 71, resetsIn: 76 * 3600)], at: at),
            PlanUsage(agent: "Work", windows: [window("5h", isSwitch ? 82 : 34, resetsIn: 160 * 60), window("Week", isSwitch ? 88 : 58, resetsIn: 48 * 3600)], at: at),
            PlanUsage(agent: "Antigravity", group: "Gemini", windows: [window("5h", 92, resetsIn: 200 * 60), window("Week", 88, resetsIn: 100 * 3600)], at: at),
            PlanUsage(agent: "Antigravity", group: "Claude and GPT", windows: [window("5h", 71, resetsIn: 200 * 60), window("Week", 74, resetsIn: 100 * 3600)], at: at),
            PlanUsage(agent: "Codex", windows: [window("5h", 81, resetsIn: 180 * 60), window("Week", 76, resetsIn: 120 * 3600)], at: at),
            PlanUsage(agent: AccountsReader.windsurfName, windows: [window("Day", 64, resetsIn: 9 * 3600), window("Week", 70, resetsIn: 90 * 3600)], at: at),
        ]
    }

    /// A made-up week: Claude most days, Codex and Antigravity now and then.
    static func history(now: Date = Date()) -> UsageHistory {
        if isNewUser { return UsageHistory() }
        let claude = [8.4, 12.1, 3.2, 0, 16.8, 11.5, 14.62], codex = [1.2, 0, 2.6, 0, 0, 3.1, 1.94], antigravity = [0, 0.8, 0, 0.4, 1.1, 0, 0.62]
        let openCode = [0.9, 0, 1.4, 2.2, 0, 0.7, 2.29], cline = [0, 1.6, 0.8, 0, 2.4, 0, 1.31]
        let work = [3.1, 5.6, 0, 0, 4.2, 6.3, 4.85]
        var history = UsageHistory()
        for (i, (day, _)) in history.last(7, now: now).enumerated() {
            var records: [String: DayRecord] = [:]
            for (agent, usd, low) in [("Claude", claude[i], 30 + i * 4), ("Codex", codex[i], 70), ("Antigravity", antigravity[i], 80),
                                      ("OpenCode", openCode[i], 100), ("Cline", cline[i], 100),
                                      (UsageHistory.key(account: "work"), work[i], 40 + i * 2)] where usd > 0 {
                records[agent] = DayRecord(tokens: Int(usd * 1_150_000), usd: usd, low5h: low, lowWeek: low + 10)
            }
            // A model with no known price: tokens, $0 (the chart's note says why).
            if [1, 3, 4].contains(i) { records["Amp"] = DayRecord(tokens: 420_000 + i * 90_000, unpricedTokens: 420_000 + i * 90_000) }
            history.days[UsageHistory.key(day)] = records
        }
        return history
    }

    static var usage: UsageSnapshot {
        var usage = UsageSnapshot()
        if isNewUser { return usage }
        usage.byModel = ["Opus 5.5": UsageBucket(tokens: 12_140_000, usd: 11.21), "Sonnet 5.5": UsageBucket(tokens: 6_280_000, usd: 3.41)]
        usage.byProject = ["my-app": UsageBucket(tokens: 9_830_000, usd: 7.92), "website": UsageBucket(tokens: 5_120_000, usd: 4.08),
                           "notes": UsageBucket(tokens: 3_470_000, usd: 2.62)]
        usage.totalTokens = 18_420_000
        usage.totalUSD = 14.62
        usage.messages = 212
        return usage
    }

    /// The Work account's today (Demo.accounts), so its own line has numbers.
    static var accountUsage: [String: UsageSnapshot] {
        if isNewUser { return [:] }
        var usage = UsageSnapshot()
        usage.byModel = ["Opus 5.5": UsageBucket(tokens: 4_310_000, usd: 3.96), "Sonnet 5.5": UsageBucket(tokens: 1_720_000, usd: 0.89)]
        usage.byProject = ["acme-api": UsageBucket(tokens: 6_030_000, usd: 4.85)]
        usage.totalTokens = 6_030_000
        usage.totalUSD = 4.85
        usage.messages = 74
        return ["work": usage]
    }

    static func otherUsage(now: Date = Date()) -> [SourceUsage] {
        isNewUser ? [] : [SourceUsage(source: "Antigravity", accuracy: .exact,
                     byModel: ["gemini-3.8-flash": TokenCounts(input: 640_000, output: 82_000, cacheRead: 910_000, messages: 27)],
                     lastActivity: now.addingTimeInterval(-1800)),
         SourceUsage(source: "Codex", accuracy: .exact,
                     byModel: ["gpt-5.5": TokenCounts(input: 820_000, output: 96_000, cacheRead: 1_400_000, messages: 41)],
                     lastActivity: now.addingTimeInterval(-600)),
         SourceUsage(source: "OpenCode", accuracy: .exact,
                     byModel: ["claude-sonnet-5": TokenCounts(input: 410_000, output: 52_000, cacheRead: 1_900_000, messages: 33),
                               "gpt-5.4": TokenCounts(input: 120_000, output: 18_000, messages: 9)],
                     lastActivity: now.addingTimeInterval(-2400), costs: ["claude-sonnet-5": 1.72, "gpt-5.4": 0.57]),
         SourceUsage(source: "Cline", accuracy: .exact,
                     byModel: ["claude-sonnet-5": TokenCounts(input: 230_000, output: 41_000, cacheWrite: 120_000, cacheRead: 880_000, messages: 18)],
                     lastActivity: now.addingTimeInterval(-3600), costs: ["claude-sonnet-5": 1.31]),
         // Installed but not used today: Settings lists it, the panel doesn't.
         SourceUsage(source: "Roo Code", accuracy: .exact),
         SourceUsage(source: "Gemini CLI", accuracy: .exact,
                     byModel: ["gemini-3.1-pro": TokenCounts(input: 96_000, output: 12_000, cacheRead: 210_000, messages: 7)],
                     lastActivity: now.addingTimeInterval(-5400))]
    }
}
