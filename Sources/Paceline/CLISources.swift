import Foundation

// Command-line agents that keep their sessions as JSON on disk: Gemini CLI and Amp.

/// A command on this Mac where its installers put it (npm, Homebrew, MacPorts,
/// ~/.local/bin, nvm). No shell is started to look.
enum CommandFinder {
    static func find(_ name: String, extra: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = extra + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "/opt/local/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        dirs += ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed().map { "\(nvm)/\($0)/bin" }
        return dirs.map { "\($0)/\(name)" }.first(where: FileManager.default.isExecutableFile)
    }
}

/// Lines of a JSON Lines file, memory-mapped; only lines containing `needle`
/// are parsed, so long sessions cost little.
enum JSONLines {
    static func forEach(_ file: URL, containing needle: String, _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return }
        let marker = Data(needle.utf8)
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[start..<end]
            if line.range(of: marker) != nil,
               let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { body(json) }
            start = end + 1
        }
    }
}

/// Files under `root`, `depth` levels down at most, modified since `since`.
func filesModified(under root: URL, since: Date, depth: Int, where keep: (URL) -> Bool) -> [URL] {
    guard depth > 0 else { return [] }
    let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
    return items.flatMap { url -> [URL] in
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        if values?.isDirectory == true { return filesModified(under: url, since: since, depth: depth - 1, where: keep) }
        return keep(url) && (values?.contentModificationDate ?? .distantPast) >= since ? [url] : []
    }
}

nonisolated(unsafe) private let isoParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseISODate(_ string: String?) -> Date? {
    guard let string else { return nil }
    return isoParser.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}

// MARK: - Gemini CLI

/// Gemini CLI (google-gemini/gemini-cli), read on GitHub at v0.67.0 (2026-11-04):
/// - Its folder is $GEMINI_CLI_HOME/.gemini, else ~/.gemini (packages/core/src/utils/paths.ts).
///   ~/.gemini/antigravity belongs to Antigravity, not Gemini CLI, and isn't looked at.
/// - Every session is recorded, with no switch to turn it off, to
///   tmp/<project>/chats/session-<time>-<id>.jsonl (subagents: chats/<parent>/<id>.jsonl).
///   A metadata line, then messages; a `gemini` message is written again with
///   the same id once its `tokens` are known, so the last copy counts
///   (packages/core/src/services/chatRecordingService.ts, chatRecordingTypes.ts):
///   `{"id","timestamp":"<ISO>","type":"gemini","model","tokens":{"input","output","cached","thoughts","tool","total"}}`.
///   `input` includes `cached` (Gemini's promptTokenCount does).
/// - Before about v0.39.0 a session was one session-*.json `{"messages":[…]}`;
///   those are read only when no .jsonl of the same name is beside them.
/// - Quotas stay on Google's servers (code_assist/server.ts), so no plan %.
/// Not tried against a real install: no Gemini CLI on the Mac it was written on.
struct GeminiCLISource: UsageSource {
    let name = "Gemini CLI"
    let root: URL

    init(root: URL = GeminiCLISource.home) { self.root = root }

    static var home: URL {
        let base = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(".gemini")
    }

    static var binary: String? { CommandFinder.find("gemini") }

    var chats: URL { root.appendingPathComponent("tmp") }
    var watchPaths: [URL] { [chats] }
    var changeDepth: Int { 4 }   // tmp/<project>/chats/<parent>/<file>

    /// The command, or files only Gemini CLI writes (Antigravity shares ~/.gemini
    /// and its settings.json, so those don't count).
    var isInstalled: Bool {
        Self.binary != nil || ["google_accounts.json", "oauth_creds.json", "projects.json", "tmp"].contains {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    func usage(since dayStart: Date) -> SourceUsage {
        var result = SourceUsage(source: name, accuracy: .exact)
        let files = filesModified(under: chats, since: dayStart, depth: 4) { ["jsonl", "json"].contains($0.pathExtension) }
        let names = Set(files.filter { $0.pathExtension == "jsonl" }.map { $0.deletingPathExtension().path })
        for file in files where file.path.contains("/chats/") {
            var latest: [String: GeminiCLILog.Message] = [:]
            if file.pathExtension == "jsonl" {
                JSONLines.forEach(file, containing: "\"tokens\"") { json in
                    if let message = GeminiCLILog.message(json) { latest[message.id] = message }
                }
            } else if !names.contains(file.deletingPathExtension().path),
                      let data = try? Data(contentsOf: file),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for item in json["messages"] as? [[String: Any]] ?? [] {
                    if let message = GeminiCLILog.message(item) { latest[message.id] = message }
                }
            }
            // A rewound message was still answered and billed, so it stays counted.
            for message in latest.values where message.at >= dayStart {
                result.byModel[message.model, default: TokenCounts()] += message.counts
                result.lastActivity = max(result.lastActivity ?? message.at, message.at)
            }
        }
        return result
    }
}

enum GeminiCLILog {
    struct Message {
        let id: String
        let model: String
        let counts: TokenCounts
        let at: Date
    }

    static func message(_ json: [String: Any]) -> Message? {
        guard json["type"] as? String == "gemini", let tokens = json["tokens"] as? [String: Any],
              let at = parseISODate(json["timestamp"] as? String) else { return nil }
        func number(_ key: String) -> Int { Int(count: (tokens[key] as? NSNumber)?.doubleValue ?? 0) }
        let cached = number("cached")
        let counts = TokenCounts(input: max(0, number("input") - cached) + number("tool"), output: number("output") + number("thoughts"),
                                 cacheRead: cached, messages: 1)
        guard counts.total > 0 else { return nil }
        return Message(id: json["id"] as? String ?? UUID().uuidString, model: (json["model"] as? String)?.nonEmpty ?? "unknown",
                       counts: counts, at: at)
    }
}

extension AccountsReader {
    /// google_accounts.json is `{"active": "<email>" | null, "old": [<email>…]}`,
    /// emails only (packages/core/src/utils/userAccountManager.ts), so it's read.
    /// oauth_creds.json holds the tokens: only whether it's there is checked.
    /// An API key or Vertex comes from the environment; settings.json's
    /// `security.auth.selectedType` says which was chosen.
    /// Google ended personal sign-in for Gemini CLI (0.67 says "This client is no
    /// longer supported for Gemini Code Assist for individuals"), so a
    /// GEMINI_API_KEY in the shell counts as signed in too; only whether it's set is checked.
    static func geminiCLI(home: URL = GeminiCLISource.home, installed: Bool? = nil,
                          apiKey: () -> Bool = { AccountsReader.loginShellHas("GEMINI_API_KEY") }) -> AccountInfo? {
        guard installed ?? GeminiCLISource(root: home).isInstalled else { return nil }
        let name = "Gemini CLI"
        if let data = try? Data(contentsOf: home.appendingPathComponent("google_accounts.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let email = json["active"] as? String, email.contains("@") {
            return AccountInfo(agent: name, status: email, plan: "Google account")
        }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth_creds.json").path) {
            return AccountInfo(agent: name, status: "Signed in", plan: "Google account")
        }
        let settings = (try? Data(contentsOf: home.appendingPathComponent("settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let selected = ((settings?["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
        return switch selected {
        case "gemini-api-key": AccountInfo(agent: name, status: "Signed in · API key")
        case "vertex-ai": AccountInfo(agent: name, status: "Signed in · Vertex AI")
        default: AccountInfo(agent: name, status: apiKey() ? "Signed in · API key" : "Not signed in")
        }
    }
}

// MARK: - Amp

/// Amp (ampcode.com). Not open source; from its install script
/// (ampcode.com/install.sh, read 2026-11-08), its CLI docs, and two third-party
/// readers of its files, ryoppippi/ccusage (`amp` command, beta) and the
/// csusage-adapter-amp 0.0.2 crate (parser.rs, paths.rs):
/// - Threads: ${AMP_DATA_DIR:-~/.local/share/amp}/threads/T-<id>.json, each
///   `{"id","messages":[{"role":"assistant","usage":{"model","inputTokens",
///   "outputTokens","cacheCreationInputTokens","cacheReadInputTokens","credits","timestamp"}}]}`;
///   older threads keep it in `usageLedger.events[{timestamp, model, credits, tokens:{input, output}}]`.
/// - Sign-in: secrets.json in the same folder (keys like "apiKey@https://ampcode.com/").
/// $ is the API list price of the model; Amp's `credits` aren't used, as
/// their unit isn't documented. Not tried against a real install.
struct AmpSource: UsageSource {
    let name = "Amp"
    let roots: [URL]

    init(roots: [URL] = AmpSource.dataDirs) { self.roots = roots }

    static var dataDirs: [URL] {
        if let custom = ProcessInfo.processInfo.environment["AMP_DATA_DIR"] {
            return custom.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        }
        return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/amp")]
    }

    static var binary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CommandFinder.find("amp", extra: ["\(home)/.amp/bin", "\(home)/bin", "\(home)/.bin"])
    }

    var watchPaths: [URL] { roots.map { $0.appendingPathComponent("threads") } }
    var isInstalled: Bool { Self.binary != nil || roots.contains { FileManager.default.fileExists(atPath: $0.path) } }

    func usage(since dayStart: Date) -> SourceUsage {
        var result = SourceUsage(source: name, accuracy: .exact)
        for folder in watchPaths {
            for file in filesModified(under: folder, since: dayStart, depth: 1, where: { $0.pathExtension == "json" }) {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                for call in AmpLog.calls(json) where call.at >= dayStart {
                    result.byModel[call.model, default: TokenCounts()] += call.counts
                    result.lastActivity = max(result.lastActivity ?? call.at, call.at)
                }
            }
        }
        return result
    }
}

enum AmpLog {
    struct Call {
        let model: String
        let counts: TokenCounts
        let at: Date
    }

    /// Per-message usage, or the older ledger when no message has any.
    static func calls(_ thread: [String: Any]) -> [Call] {
        func int(_ value: Any?) -> Int { Int(count: (value as? NSNumber)?.doubleValue ?? 0) }
        let messages = (thread["messages"] as? [[String: Any]] ?? []).compactMap { message -> Call? in
            guard message["role"] as? String == "assistant", let usage = message["usage"] as? [String: Any],
                  let at = parseISODate((usage["timestamp"] ?? message["timestamp"]) as? String) else { return nil }
            let counts = TokenCounts(input: int(usage["inputTokens"]), output: int(usage["outputTokens"]),
                                     cacheWrite: int(usage["cacheCreationInputTokens"]), cacheRead: int(usage["cacheReadInputTokens"]), messages: 1)
            let model = ((usage["model"] ?? message["model"]) as? String)?.nonEmpty ?? "unknown"
            return counts.total > 0 ? Call(model: model, counts: counts, at: at) : nil
        }
        if !messages.isEmpty { return messages }
        let events = (thread["usageLedger"] as? [String: Any])?["events"] as? [[String: Any]] ?? []
        return events.compactMap { event in
            guard let at = parseISODate(event["timestamp"] as? String), let tokens = event["tokens"] as? [String: Any] else { return nil }
            let counts = TokenCounts(input: int(tokens["input"]), output: int(tokens["output"]), messages: 1)
            return counts.total > 0 ? Call(model: (event["model"] as? String)?.nonEmpty ?? "unknown", counts: counts, at: at) : nil
        }
    }
}

extension AccountsReader {
    /// secrets.json: only its top-level key names are looked at ("apiKey@<server>"),
    /// never the values.
    static func amp(dataDirs: [URL] = AmpSource.dataDirs, installed: Bool? = nil) -> AccountInfo? {
        guard installed ?? AmpSource(roots: dataDirs).isInstalled else { return nil }
        let signedIn = dataDirs.contains { dir in
            topLevelKeys(dir.appendingPathComponent("secrets.json")).contains { $0.hasPrefix("apiKey@") }
        }
        return AccountInfo(agent: "Amp", status: signedIn ? "Signed in" : "Not signed in")
    }

    /// The names at the top of a JSON object; the values are dropped unread.
    static func topLevelKeys(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return Array(json.keys)
    }
}
