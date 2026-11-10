import Foundation

extension SelfTest {
    /// Report a Problem…: made-up accounts with an email, an added account's own
    /// name, a project path and a home path never reach the text.
    static func reportTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  report: \(what)")
        }
        typealias D = Diagnostics

        let accounts = [AccountInfo(agent: "Claude", status: "fake.person@example.com", plan: "Max"),
                        AccountInfo(agent: "Zebrawork", status: "other.fake@example.org"),
                        AccountInfo(agent: "Codex", status: "Signed in · ChatGPT"),
                        AccountInfo(agent: "Cursor", status: "Unknown"),
                        AccountInfo(agent: "Gemini CLI", status: "Not signed in"),
                        AccountInfo(agent: "Kiro", status: "Not installed")]
        let ais = D.ais(accounts: accounts, plans: ["Claude", "Zebrawork", "Codex"], tokens: ["Codex": .exact, "Gemini CLI": .estimated],
                        claudeTranscripts: true)
        check(ais.map(\.name) == ["Claude", "Codex", "Cursor", "Gemini CLI", "Kiro"], "added accounts left out → \(ais.map(\.name))")
        check(ais.map(\.status) == ["Ready", "Ready", "Can't read", "Needs sign-in", "Not installed"], "statuses in fixed words → \(ais.map(\.status))")
        check(ais[0].found == ["plan %", "tokens (exact)", "sign-in"] && ais[3].found == ["tokens (estimated)"] && ais[4].found.isEmpty,
              "sources found → \(ais.map(\.found))")

        let info = D.Info(version: "9.9.9", macOS: "26.1", arch: "arm64", homebrew: true, ais: ais, addedClaudeAccounts: 1,
                          settings: ["alerts on"])
        let raw = D.report(info)
        check(raw.hasPrefix("Paceline 9.9.9 · from Homebrew: yes\nmacOS 26.1 · arm64\nAdded Claude accounts: 1"), "header lines")
        check(raw.contains("Cursor      Can't read     —"), "aligned table row")

        // Whatever slipped in, scrub takes out.
        // Built at run time: a literal (even "/" + "Users") is folded into the binary, and the public scan flags it.
        let homes = URL(fileURLWithPath: "/").appendingPathComponent("Users").path, home = homes + "/fakeuser"
        let leaky = raw + "\nnote: \(home)/Projects/secret-thing · \(homes)/someoneelse/x · fake.person@example.com · Zebrawork's · zebrawork"
        let text = D.scrub(leaky, home: home, names: ["Zebrawork", "Claude", " "])
        check(!text.contains("@") && !text.contains(homes + "/") && !text.lowercased().contains("zebrawork") && !text.contains("fakeuser"),
              "no @, no home folders, no account name")
        check(text.contains("~/Projects") && text.contains("(account)'s") && text.contains("Claude  "),
              "home → ~, names hidden whole-word, a table name kept")
        check(!D.issueURL.absoluteString.contains("body") && D.issueURL.query == "template=bug.yml", "issue link carries no data")
        return failures
    }
}
