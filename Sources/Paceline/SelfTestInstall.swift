import Foundation

extension SelfTest {
    /// Install…: every AI has a way, only to its maker's sites, and the script waits for Return.
    static func installTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  install: \(what)")
        }

        let missing = Providers.all.filter { $0.install == nil || ($0.install?.command == nil && $0.install?.links.isEmpty != false) }
        check(missing.map(\.name) == ["Roo Code"], "every AI but Roo Code (ended) has a command or a page → missing \(missing.map(\.name))")
        let bad = Providers.all.flatMap { provider in
            (provider.install?.allURLs ?? []).filter { url in
                url.scheme == "vscode" ? !url.absoluteString.hasPrefix("vscode:extension/")
                    : url.scheme != "https" || !Install.officialHosts.contains(url.host() ?? "")
            }.map { "\(provider.name): \($0)" }
        }
        check(bad.isEmpty, "every URL is https on a listed host (or vscode:extension/) → \(bad)")
        check(Providers.all.allSatisfy { $0.install?.command.map { $0.hasPrefix("curl -fsSL https://") || $0.hasPrefix("npm install -g ") } ?? true }
              && Providers.all.compactMap(\.install?.brew) == ["brew install gemini-cli"],
              "commands are the makers' curl installers or npm; brew only Gemini CLI's homebrew/core formula")
        check(Providers.named("Gemini CLI")?.install?.note?.contains("GEMINI_API_KEY") == true
              && Install.needs(Providers.named("Gemini CLI")?.install?.command)?.tool == "npm", "Gemini CLI: npm, and says personal sign-in ended")
        check(Install.needs(Providers.named("Amp")?.install?.command) == nil && Providers.named("Cursor")?.install?.command == nil
              && Providers.named("Cline")?.install?.vsCodeExtension == "saoudrizwan.claude-dev",
              "curl needs nothing first; Cursor is a page; Cline is an extension")

        // The script, run for real: nothing without Return; with it, the command exactly once.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let odd = "it's; $(touch PWNED) `touch PWNED` & \"x\""
        let command = "printf ran >> RAN | cat"
        let text = Install.script(command, agent: "Amp \(odd)")
        let readLine = text.range(of: "read -r answer || exit 1")
        let runLine = text.range(of: "/bin/bash -c ")
        check(readLine != nil && runLine != nil && readLine!.upperBound <= runLine!.lowerBound, "the read comes before the command")
        func run(input: String) -> (out: String, ran: Bool) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("RAN"))
            guard let file = try? SignInLauncher.write(text: text, prefix: "install", in: dir.appendingPathComponent("out")) else { return ("", false) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [file.path]
            process.currentDirectoryURL = dir
            process.environment = ["PATH": "/usr/bin:/bin", "TERM": "dumb"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try? process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (out, (try? String(contentsOf: dir.appendingPathComponent("RAN"), encoding: .utf8)) == "ran")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cancelled = run(input: "")
        check(!cancelled.ran && cancelled.out.contains(command) && cancelled.out.contains("Press Return"),
              "no Return: it shows the command and runs nothing")
        let confirmed = run(input: "\n")
        check(confirmed.ran && confirmed.out.contains("Done."), "Return: the command runs, pipe and all")
        check(confirmed.out.contains("Amp \(odd)") && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("PWNED").path),
              "an odd name prints as it is and runs nothing")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("out").path)) ?? []
        check(left.isEmpty, "the install file removes itself")
        return failures
    }
}
