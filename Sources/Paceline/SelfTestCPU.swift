import AppKit

extension SelfTest {
    /// The Codex rollout cache: same file → no new read, changed file or new day → read again.
    static func cpuLeanTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  cpu: \(what)")
        }
        func line(_ time: String, _ input: Int) -> String {
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":10}}}}"#
        }
        func sum(_ r: CodexLog.Result?) -> [Int] {
            r.map { $0.byModel.values.reduce(into: [0, 0, 0]) { $0[0] += $1.input; $0[1] += $1.output; $0[2] += $1.messages } } ?? []
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paceline-cpu-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        let head = #"{"type":"turn_context","payload":{"model":"gpt-test"}}"#
        try? (head + "\n" + line("2026-11-10T01:00:00Z", 100) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let day = Date(timeIntervalSince1970: 1_762_700_000)  // 2025-11-09, before the lines
        let cache = CodexLogCache()

        let first = cache.read(file.path, since: day), second = cache.read(file.path, since: day)
        let direct = CodexLog.read(FileManager.default.contents(atPath: file.path) ?? Data(), since: day)
        check(cache.reads == 1 && sum(first) == sum(second) && sum(first) == sum(direct) && sum(first) == [100, 10, 1],
              "the same file twice is parsed once and gives the same totals as reading it directly")

        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data((line("2026-11-10T02:00:00Z", 250) + "\n").utf8))
            try? h.close()
        }
        let grown = cache.read(file.path, since: day)
        check(cache.reads == 2 && sum(grown) == [250, 10, 2], "a file that grew is read again")

        let later = Date(timeIntervalSince1970: 1_794_274_200)  // 2026-11-10 01:30Z: between the two lines
        let nextDay = cache.read(file.path, since: later)
        check(cache.reads == 3 && sum(nextDay) == [150, 0, 1], "a new day doesn't reuse the old day's totals")

        cache.keep(only: [])
        _ = cache.read(file.path, since: later)
        check(cache.reads == 4, "files no longer in today's set are forgotten")
        check(cache.read(dir.appendingPathComponent("gone.jsonl").path, since: day) == nil, "a missing file reads as nothing")
        check(TokenMonitor.notTranscripts == ["memory", "tool-results"] && !TokenMonitor.notTranscripts.contains("subagents"),
              "Claude's walk skips memory/ and tool-results/ but still reads subagents/")
        failures += eventTests()
        return failures
    }

    /// FSEvents paths → files and sources, when to walk everything, and skipping an unchanged menu bar.
    static func eventTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  events: \(what)")
        }
        let real = "/tmp/home/.claude-work/projects", shown = "/tmp/home/link/projects"
        check(TokenMonitor.transcript(real + "/-proj/abc.jsonl", realRoot: real, root: shown) == shown + "/-proj/abc.jsonl",
              "a changed transcript is read under the path the walk uses (symlinked account folder)")
        check(TokenMonitor.transcript(real + "/-proj/abc/subagents/agent-1.jsonl", realRoot: real, root: shown) != nil,
              "a subagent's transcript counts")
        check(TokenMonitor.transcript(real + "/-proj/memory/x.jsonl", realRoot: real, root: shown) == nil
              && TokenMonitor.transcript(real + "/-proj/abc/tool-results/t.jsonl", realRoot: real, root: shown) == nil,
              "memory/ and tool-results/ are never read")
        check(TokenMonitor.transcript(real + "/-proj/abc.json", realRoot: real, root: shown) == nil
              && TokenMonitor.transcript(real + "/-proj", realRoot: real, root: shown) == nil
              && TokenMonitor.transcript(real + "x/-proj/a.jsonl", realRoot: real, root: shown) == nil,
              "folders, other files and a look-alike folder name nothing")

        let roots = [["/tmp/home/.codex", "/tmp/home/.codex/sessions/2026/11/10"], ["/tmp/home/.gemini/tmp"], ["/tmp/home/.gemini/antigravity/conversations"]]
        check(FSEvents.owners(of: "/tmp/home/.codex/sessions/2026/11/11/rollout-new.jsonl", roots: roots) == [0],
              "a new day's Codex folder (not watched by name) still belongs to Codex")
        check(FSEvents.owners(of: "/tmp/home/.codex/state_5.sqlite-wal", roots: roots) == [0]
              && FSEvents.owners(of: "/tmp/home/.gemini/tmp/p/chats/s.json", roots: roots) == [1]
              && FSEvents.owners(of: "/tmp/home/.gemini/antigravity/conversations/", roots: roots) == [2],
              "each changed path is its own source's")
        let codex = CodexSource()
        let rel = { FSEvents.relative($0, roots: roots[0]) }
        check(rel("/tmp/home/.codex/sessions/2026/11/11/r.jsonl") == "sessions/2026/11/11/r.jsonl"
              && !codex.ignoresChange(rel("/tmp/home/.codex/sessions/2026/11/11/r.jsonl"))
              && !codex.ignoresChange(rel("/tmp/home/.codex/state_5.sqlite-wal"))
              && !codex.ignoresChange(rel("/tmp/home/.codex/archived_sessions/r.jsonl")),
              "Codex: a rollout, the threads database or an archived rollout changing redoes Codex")
        check(codex.ignoresChange(rel("/tmp/home/.codex/logs_2.sqlite-wal")) && codex.ignoresChange(rel("/tmp/home/.codex/models_cache.json")) && codex.ignoresChange(rel("/tmp/home/.codex/state_5.sqlite-shm"))
              && codex.ignoresChange(rel("/tmp/home/.codex/plugins/cache/a/b.json")) && !AntigravitySource().ignoresChange("x.db-wal")
              && AntigravitySource().ignoresChange("x.db-shm"),
              "Codex: its logs database, model cache, plugin cache and -shm (touched by our own reads) don't; other sources every change but -shm")
        check(FSEvents.owners(of: "/tmp/home/.gemini/settings.json", roots: roots).isEmpty
              && FSEvents.owners(of: "/tmp/home/.codexfoo/a", roots: roots).isEmpty, "a path under no watched folder names no source")

        let now = Date()
        check(!FSEvents.walkDue(lastWalk: now.addingTimeInterval(-60), now: now, newDay: false, mustRescan: false),
              "a minute after a walk: read only what changed")
        check(FSEvents.walkDue(lastWalk: .distantPast, now: now, newDay: false, mustRescan: false), "the first pass walks everything")
        check(FSEvents.walkDue(lastWalk: now.addingTimeInterval(-300), now: now, newDay: false, mustRescan: false),
              "every 5 minutes a full walk")
        check(FSEvents.walkDue(lastWalk: now, now: now, newDay: true, mustRescan: false)
              && FSEvents.walkDue(lastWalk: now, now: now, newDay: false, mustRescan: true), "a new day or lost events walk at once")
        let lost: [Int] = [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                           kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged]
        check(lost.allSatisfy { FSEvents.mustRescan(FSEventStreamEventFlags($0)) }
              && !FSEvents.mustRescan(FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)),
              "dropped events, rescan-subfolders and a moved root mean walk; a modified file doesn't")

        typealias S = StatusItemController.Segment
        let row = AIReading.Row(text: "40", low: false, window: "5h", runsOut: 1200)
        func seg(_ text: String, runsOut: TimeInterval? = 1200, key: String = "Claude|") -> S {
            S(icon: NSImage(size: NSSize(width: 14, height: 14)), label: nil, text: text,
              rows: [AIReading.Row(text: row.text, low: row.low, window: row.window, runsOut: runsOut)], iconKey: key)
        }
        func same(_ a: [S], _ b: [S], tip: String? = "t", style: MenuBarStyle = .compact) -> Bool {
            StatusItemController.sameDrawing(a, b, warning: false, false, tooltip: "t", tip, spoken: "s", "s", style: .compact, style)
        }
        check(same([seg("40%")], [seg("40%", runsOut: 1140)]), "the same reading (new icon object, countdown a minute on) isn't redrawn")
        check(!same([seg("40%")], [seg("39%")]) && !same([seg("40%")], [seg("40%", runsOut: nil)])
              && !same([seg("40%")], [seg("40%", key: "Claude|2")]) && !same([seg("40%")], [seg("40%"), seg("1%")]),
              "a new number, colour, badge or AI is redrawn")
        check(!same([seg("40%")], [seg("40%")], tip: "u") && !same([seg("40%")], [seg("40%")], style: .twoRows),
              "a new tooltip or style is redrawn")
        return failures
    }
}
