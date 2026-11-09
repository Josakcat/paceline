import AppKit

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}
if arguments.contains("--usage") {
    TokenMonitor.printToday()
    exit(0)
}
if arguments.contains("--statusline") {
    PlanUsageReader.statusLine()
    exit(0)
}
if let i = arguments.firstIndex(of: "--claude-limits") {
    PlanUsageReader.claudeLimits(account: i + 1 < arguments.count ? arguments[i + 1] : "")
    exit(0)
}
// What "Fetch fresh numbers" does, for every account at once, whatever the setting.
if arguments.contains("--fetch-now") {
    let targets = [FreshLimits.Target(id: "claude", kind: .claude(configDir: nil), at: nil)]
        + ClaudeAccounts.load().map { FreshLimits.Target(id: $0.id, kind: .claude(configDir: $0.configDir), at: nil) }
        + [FreshLimits.Target(id: "antigravity", kind: .antigravity, at: nil)]
    for target in targets { FreshLimits.fetch(target) }
}
if arguments.contains("--plans") || arguments.contains("--fetch-now") {
    for plan in PlanUsageReader.all() {
        print(plan.title + ": " + plan.windows.map { "\($0.label) \($0.left)% left" + ($0.resetText().map { " (\($0))" } ?? "") }.joined(separator: " · ")
              + (plan.age().map { " · \($0)" } ?? ""))
    }
    exit(0)
}
if arguments.contains("--sources") {
    UsageSources.printToday()
    exit(0)
}
// The update path without installing anything; see Updates.commandLineCheck.
if arguments.contains("--check-update") {
    Task.detached { exit(await Updates.commandLineCheck(arguments)) }
    dispatchMain()
}
if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
    exit(SelfTest.renderIcon(to: arguments[i + 1]) ? 0 : 1)
}
// `--debug <command> [value]`: drives a running copy that has debugEndpoints on.
if let i = arguments.firstIndex(of: "--debug"), i + 1 < arguments.count {
    DistributedNotificationCenter.default().postNotificationName(
        AppController.debugNotification, object: arguments[i + 1],
        userInfo: i + 2 < arguments.count ? ["value": arguments[i + 2]] : nil, deliverImmediately: true)
    exit(0)
}

// Before AppModel reads them (the GUI only, so --selftest leaves the real domain alone).
if !Demo.isOn && Legacy.agentPetWasHere {
    DefaultsMigration.run(from: UserDefaults.standard.persistentDomain(forName: DefaultsMigration.legacyDomain), to: .standard,
                          domain: Bundle.main.bundleIdentifier ?? "com.josakcat.paceline")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
