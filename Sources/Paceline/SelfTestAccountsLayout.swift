import Foundation

extension SelfTest {
    /// Settings → Accounts: groups, Claude's added accounts under it, the count on top, short lines.
    static func accountsLayoutTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  accounts layout: \(what)")
        }
        typealias L = AccountsLayout

        check(L.group("you@example.com") == .ready && L.group("Signed in · ChatGPT") == .ready
              && L.group("Installed · VS Code") == .ready && L.group("Unknown · Cursor") == .ready,
              "signed in, or keys kept by the editor: ready")
        check(L.group("Not signed in") == .needsSignIn && L.group("Installed") == .needsSignIn && L.group("Unknown") == .needsSignIn,
              "signed out, app with no sign-in, unknown: needs sign-in")
        check(L.group("Not installed") == .notInstalled, "not installed")

        // The demo's Mac: everything ready but Kilo Code and Kiro, Work under Claude.
        let demo = L.sections(Demo.signIns, extras: ["Work"])
        check(demo.map(\.group) == [.ready, .notInstalled], "demo: Ready and Not installed only → \(demo.map(\.group.rawValue))")
        let ready = demo.first?.rows ?? []
        check(ready.first?.account.agent == "Claude" && ready.first?.extras.map(\.agent) == ["Work"]
              && !ready.contains { $0.account.agent == "Work" }, "Work sits under Claude, not on its own row")
        check(ready.map(\.account.agent) == ["Claude", "Codex", "Antigravity", AccountsReader.windsurfName, "OpenCode", "Cline", "Roo Code",
                                             "Gemini CLI", "Amp", "Cursor", "GitHub Copilot"],
              "plan limits first, then usage, then sign-in only → \(ready.map(\.account.agent))")
        check(demo.first?.count == 12 && demo.last?.count == 2, "counts include added accounts → \(demo.map(\.count))")
        check(L.summary(Demo.signIns) == "12 ready · 2 not installed", "demo summary → \(L.summary(Demo.signIns))")

        // A new user's Mac: Claude signed out but its added account signed in → Claude is ready, with it.
        let mixed = [AccountInfo(agent: "Claude", status: "Not signed in"), AccountInfo(agent: "Work", status: "w@x.example"),
                     AccountInfo(agent: "Codex", status: "Not signed in"), AccountInfo(agent: "Cursor", status: "Not installed"),
                     AccountInfo(agent: "Antigravity", status: "Installed")]
        let mixedSections = L.sections(mixed, extras: ["Work"])
        check(mixedSections.map(\.group) == [.ready, .needsSignIn, .notInstalled]
              && mixedSections[0].rows.map(\.account.agent) == ["Claude"]
              && mixedSections[1].rows.map(\.account.agent) == ["Codex", "Antigravity"],
              "Claude goes where its readiest account does → \(mixedSections.map { $0.rows.map(\.account.agent) })")
        check(L.summary(mixed) == "1 ready · 3 need sign-in · 1 not installed", "summary counts each account → \(L.summary(mixed))")
        check(L.summary([AccountInfo(agent: "Codex", status: "Not signed in")]) == "1 needs sign-in", "one: needs, not need")
        check(L.summary([]) == "" && L.sections([], extras: []).isEmpty, "nothing read yet: no line, no groups")
        let orphan = L.sections([AccountInfo(agent: "Work", status: "w@x.example")], extras: ["Work"])
        check(orphan.first?.rows.first?.account.agent == "Claude" && orphan.first?.rows.first?.extras.count == 1,
              "an added account without Claude's own row still shows, under Claude")

        check(L.detail(AccountInfo(agent: "Codex", status: "Signed in · ChatGPT")) == "ChatGPT", "detail: Codex's sign-in kind")
        check(L.detail(AccountInfo(agent: "Cline", status: "Installed · VS Code")) == "In VS Code", "detail: where it lives")
        check(L.detail(AccountInfo(agent: "Amp", status: "Signed in")) == nil, "detail: nothing to add next to ✓")
        check(L.detail(AccountInfo(agent: "Kiro", status: "Not installed")) == nil
              && L.detail(AccountInfo(agent: "Codex", status: "Not signed in")) == "Not signed in", "detail: signed out says so")
        check(L.shortEmail("you@example.com") == "you@example.com", "a short email stays whole")
        check(L.shortEmail("someone.long@example.com") == "someone.l…@example.com", "a long one keeps its domain → \(L.shortEmail("someone.long@example.com"))")
        check(L.shortEmail("no-at-sign") == "no-at-sign", "not an email: as is")
        return failures
    }
}
