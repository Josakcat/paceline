import Foundation

/// Cline and its forks Roo Code and Kilo Code: VS Code extensions (also in
/// Cursor, Windsurf, VSCodium…) that log every API request with its tokens and
/// cost. One reader for all three; what differs is in `Agent`.
///
/// From their source on GitHub:
/// - Cline v4.1.26 (2026-10-26), cline/cline: tasks in <globalStorage>/tasks/<id>/
///   (apps/vscode/src/core/storage/disk.ts); `ClineMessage {ts, type, say, text,
///   modelInfo}` and `ClineApiReqInfo {tokensIn, tokensOut, cacheWrites, cacheReads,
///   cost}` (apps/vscode/src/shared/ExtensionMessage.ts); getApiMetrics.ts adds up
///   `api_req_started`, `deleted_api_reqs` and `subagent_usage`. Since 4.0 the SDK
///   also keeps sessions in ~/.cline/data/sessions/<id>/<id>.messages.json, `{messages:
///   [{ts, modelInfo:{id}, metrics:{inputTokens, outputTokens, cacheReadTokens,
///   cacheWriteTokens, cost}}]}`, where inputTokens already includes the cache
///   (sdk/packages/shared/src/storage/paths.ts, src/llms/messages.ts, services/usage.ts).
/// - Roo Code v3.54.0 (2026-05-15), RooCodeInc/Roo-Code: the same tasks/<id>/ui_messages.json
///   and `api_req_started` (src/shared/globalFileNames.ts, packages/types/src/vscode-extension-host.ts).
///   It records no model, so its requests are "unknown" with the cost it recorded.
///   A custom storage folder (roo-cline.customStoragePath) isn't followed.
/// - Kilo Code v7.8.28 (2026-11-07), Kilo-Org/kilocode: now built on OpenCode, with an
///   OpenCode-style kilo.db (read by `OpenCodeSource.kilo()`); its 4.x/5.x tasks
///   folders are Roo's format.
/// Not tried against real installs: none of them was on the Mac this was written on.
enum VSCodeAgents {
    struct Agent: Sendable {
        let name: String
        let extensionID: String
        let short: String
        let color: UInt32
        /// Cline's own folder (~/.cline/data): its CLI's tasks and the SDK's sessions.
        var clineData: URL? = nil
        /// Kilo Code 7's OpenCode-style database.
        var openCode: OpenCodeSource? = nil
        /// The editor setting that moves its storage elsewhere (Roo Code's).
        var storageSetting: String? = nil
        /// Install…: its Marketplace page, unless it's gone (see Providers).
        var install: Install? = nil
    }

    static var agents: [Agent] {
        let env = ProcessInfo.processInfo.environment
        let clineDir = env["CLINE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cline")
        return [
            Agent(name: "Cline", extensionID: "saoudrizwan.claude-dev", short: "CL", color: 0x22C55E,
                  clineData: env["CLINE_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? clineDir.appendingPathComponent("data"),
                  install: .init(page: URL(string: "https://docs.cline.bot/getting-started/installing-cline")!, pageTitle: "Cline docs",
                                 vsCodeExtension: "saoudrizwan.claude-dev")),
            Agent(name: "Roo Code", extensionID: "rooveterinaryinc.roo-cline", short: "RC", color: 0xEAB308,
                  // No install: Roo Code ended in May 2026 (Marketplace listing gone, repository archived).
                  storageSetting: "roo-cline.customStoragePath"),
            Agent(name: "Kilo Code", extensionID: "kilocode.kilo-code", short: "KC", color: 0xF97316, openCode: .kilo(),
                  install: .init(page: URL(string: "https://kilo.ai/install")!, pageTitle: "Kilo install page", vsCodeExtension: "kilocode.Kilo-Code")),
        ]
    }

    /// Editors that keep extension data under ~/Library/Application Support/<editor>/User/globalStorage.
    static let editors = ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf", "Devin", "Kiro", "Antigravity", "Antigravity IDE"]

    static var providers: [Provider] {
        agents.map { agent in
            Provider(name: agent.name, short: agent.short, group: .usage, capabilities: [.tokens, .cost], color: agent.color,
                     account: { AccountsReader.vsCodeAgent(agent) }, source: VSCodeAgentSource(agent: agent), install: agent.install)
        }
    }

    /// Each editor's app by the name `storages` gives it, for Open <editor>. VSCodium's ID is
    /// the darwinBundleIdentifier its prepare_vscode.sh sets (github.com/VSCodium/vscodium,
    /// checked 2026-11-09); the rest are the table's. Code - Insiders has no Open button:
    /// Microsoft publishes no bundle ID for it that could be checked.
    static let editorApps: [(name: String, bundleID: String)] = [
        ("VS Code", "com.microsoft.VSCode"), ("VSCodium", "com.vscodium"),
        ("Cursor", AccountsReader.cursorBundleID), ("Windsurf", AccountsReader.windsurfBundleID),
        ("Devin Desktop", AccountsReader.windsurfBundleID), ("Kiro", AccountsReader.kiroBundleID),
        ("Antigravity", "com.google.antigravity"), ("Antigravity IDE", "com.google.antigravity"),
    ]

    /// Paceline can't tell whether these are signed in (that's in the editor's secret
    /// storage), so their row opens the editor they're in: the first of "Installed · VS Code,
    /// Cursor" whose app is here. Windsurf's and Devin's folders open whichever of the two is here.
    static func openEditor(_ status: String, appName: String = AccountsReader.windsurfName,
                           isInstalled: (String) -> Bool) -> (name: String, bundleID: String)? {
        guard status.hasPrefix("Installed · ") else { return nil }
        let places = status.dropFirst("Installed · ".count).components(separatedBy: ", ")
        guard let app = places.lazy.compactMap({ place in editorApps.first { $0.name == place } }).first(where: { isInstalled($0.bundleID) })
        else { return nil }
        return app.bundleID == AccountsReader.windsurfBundleID ? (appName, app.bundleID) : app
    }

    /// Where to sign in, once the editor's open.
    static func signInHint(_ agent: String) -> String {
        "Sign in from the \(agent) panel in the editor’s sidebar, or add an API key in its settings."
    }

    /// Each editor's globalStorage folder for this extension, where it exists.
    static func storages(_ agent: Agent, appSupport: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")) -> [(editor: String, folder: URL)] {
        editors.flatMap { editor -> [(editor: String, folder: URL)] in
            let name = ["Code": "VS Code", "Devin": "Devin Desktop"][editor] ?? editor
            let user = appSupport.appendingPathComponent("\(editor)/User")
            let folders = [user.appendingPathComponent("globalStorage/\(agent.extensionID)")]
                + [agent.storageSetting.flatMap { setting(named: $0, in: user.appendingPathComponent("settings.json")) }].compactMap { $0 }
            return folders.filter { FileManager.default.fileExists(atPath: $0.path) }.map { (name, $0) }
        }
    }

    /// One string setting from an editor's settings.json, and nothing else of it.
    /// The file is JSON with comments, so the key is looked for rather than parsed.
    static func setting(named key: String, in file: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        // The first that isn't on a commented-out line.
        let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).first { match in
            guard let found = Range(match.range, in: text) else { return false }
            return !text[text.lineRange(for: found.lowerBound..<found.lowerBound)].trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        guard let match, let range = Range(match.range(at: 1), in: text) else { return nil }
        let path = text[range].replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

/// Today's requests: tasks/<id>/ui_messages.json in each editor's storage (and
/// Cline's own folder), Cline's SDK sessions, and Kilo Code 7's database.
/// Only files changed today are opened.
struct VSCodeAgentSource: UsageSource {
    let agent: VSCodeAgents.Agent
    /// Folders that hold a tasks/ folder.
    var folders: [URL]

    init(agent: VSCodeAgents.Agent, folders: [URL]? = nil) {
        self.agent = agent
        // Each folder once: two editors can point Roo Code's custom storage at the same place.
        var seen = Set<String>()
        self.folders = (folders ?? (VSCodeAgents.storages(agent).map(\.folder) + [agent.clineData].compactMap { $0 }))
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
    }

    var name: String { agent.name }
    private var sessions: URL? { agent.clineData?.appendingPathComponent("sessions") }
    var watchPaths: [URL] {
        folders.map { $0.appendingPathComponent("tasks") } + [sessions, agent.openCode?.root].compactMap { $0 }
    }
    var changeDepth: Int { 2 }
    var isInstalled: Bool {
        folders.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tasks").path) }
            || !VSCodeAgents.storages(agent).isEmpty || (agent.openCode?.isInstalled ?? false)
    }

    func usage(since dayStart: Date) -> SourceUsage {
        var result = agent.openCode?.usage(since: dayStart) ?? SourceUsage(source: name, accuracy: .exact)
        result = SourceUsage(source: name, accuracy: .exact, byModel: result.byModel, lastActivity: result.lastActivity, costs: result.costs)
        func add(_ request: VSCodeAgentLog.Request) {
            result.byModel[request.model, default: TokenCounts()] += request.counts
            if request.cost > 0 { result.costs[request.model, default: 0] += request.cost }
            result.lastActivity = max(result.lastActivity ?? request.at, request.at)
        }
        for folder in folders {
            let tasks = folder.appendingPathComponent("tasks")
            for file in filesModified(under: tasks, since: dayStart, depth: 2, where: { $0.lastPathComponent == "ui_messages.json" }) {
                let fallback = VSCodeAgentLog.model(task: file.deletingLastPathComponent())
                VSCodeAgentLog.requests(file, since: dayStart, model: fallback).forEach(add)
            }
        }
        if let sessions {
            for file in filesModified(under: sessions, since: dayStart, depth: 2, where: { $0.lastPathComponent.hasSuffix(".messages.json") }) {
                VSCodeAgentLog.sessionRequests(file, since: dayStart).forEach(add)
            }
        }
        return result
    }
}

enum VSCodeAgentLog {
    struct Request {
        let model: String
        let counts: TokenCounts
        let cost: Double
        let at: Date
    }

    /// Requests (and Cline's deleted-request and subagent totals) from a ui_messages.json.
    static func requests(_ file: URL, since: Date, model: String) -> [Request] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return messages.compactMap { request($0, since: since, model: model) }
    }

    static let countedSays: Set<String> = ["api_req_started", "deleted_api_reqs", "subagent_usage"]

    static func request(_ message: [String: Any], since: Date, model fallback: String) -> Request? {
        guard let say = message["say"] as? String, countedSays.contains(say),
              let ms = (message["ts"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: ms / 1000) >= since,
              let text = message["text"] as? String,
              let info = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { Int(count: (info[key] as? NSNumber)?.doubleValue ?? 0) }
        let counts = TokenCounts(input: int("tokensIn"), output: int("tokensOut"), cacheWrite: int("cacheWrites"), cacheRead: int("cacheReads"), messages: 1)
        guard counts.total > 0 else { return nil }
        let modelInfo = message["modelInfo"] as? [String: Any]
        let model = (modelInfo?["modelId"] ?? modelInfo?["id"] ?? modelInfo?["model"]) as? String
        return Request(model: model?.nonEmpty ?? fallback, counts: counts, cost: (info["cost"] as? NSNumber)?.doubleValue ?? 0,
                       at: Date(timeIntervalSince1970: ms / 1000))
    }

    /// Cline SDK sessions: messages with `metrics`; inputTokens includes the cache.
    static func sessionRequests(_ file: URL, since: Date) -> [Request] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (json["messages"] as? [[String: Any]] ?? []).compactMap { message in
            guard let metrics = message["metrics"] as? [String: Any], let ms = (message["ts"] as? NSNumber)?.doubleValue,
                  Date(timeIntervalSince1970: ms / 1000) >= since else { return nil }
            func int(_ key: String) -> Int { Int(count: (metrics[key] as? NSNumber)?.doubleValue ?? 0) }
            let read = int("cacheReadTokens"), write = int("cacheWriteTokens")
            let counts = TokenCounts(input: max(0, int("inputTokens") - read - write), output: int("outputTokens"),
                                     cacheWrite: write, cacheRead: read, messages: 1)
            guard counts.total > 0 else { return nil }
            let model = ((message["modelInfo"] as? [String: Any])?["id"] as? String)?.nonEmpty ?? "unknown"
            return Request(model: model, counts: counts, cost: (metrics["cost"] as? NSNumber)?.doubleValue ?? 0,
                           at: Date(timeIntervalSince1970: ms / 1000))
        }
    }

    /// The task's model from task_metadata.json's `model_usage` (newest entry),
    /// for messages that don't say; else "unknown".
    static func model(task: URL) -> String {
        guard let data = try? Data(contentsOf: task.appendingPathComponent("task_metadata.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = json["model_usage"] as? [[String: Any]],
              let latest = usage.max(by: { (($0["ts"] as? NSNumber)?.doubleValue ?? 0) < (($1["ts"] as? NSNumber)?.doubleValue ?? 0) }),
              let id = (latest["model_id"] as? String)?.nonEmpty else { return "unknown" }
        return id
    }
}

extension AccountsReader {
    /// These sign in with API keys or their own account, kept in the editor's
    /// secret storage, which Paceline doesn't read: installed, and where.
    static func vsCodeAgent(_ agent: VSCodeAgents.Agent, storages: [(editor: String, folder: URL)]? = nil) -> AccountInfo? {
        var places = (storages ?? VSCodeAgents.storages(agent)).map(\.editor)
        if let data = agent.clineData, FileManager.default.fileExists(atPath: data.path) { places.append("Cline CLI") }
        if storages == nil, let kilo = agent.openCode, kilo.isInstalled { places.append("Kilo CLI") }
        guard !places.isEmpty else { return nil }
        return AccountInfo(agent: agent.name, status: "Installed · " + places.joined(separator: ", "))
    }
}
