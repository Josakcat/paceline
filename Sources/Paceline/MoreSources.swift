import Foundation

// MARK: - OpenCode

/// OpenCode keeps sessions in $XDG_DATA_HOME/opencode (default
/// ~/.local/share/opencode). From anomalyco/opencode (formerly sst/opencode),
/// read on GitHub for v1.19.5 (2026-10-28):
/// - opencode.db (opencode-<channel>.db off the main channels; OPENCODE_DB
///   overrides it), table `session_message(id, session_id, type, data, time_created…)`:
///   `data` of an assistant row is `{"type":"assistant","model":{"id","providerID"},
///   "cost":…, "tokens":{"input","output","reasoning","cache":{"read","write"}},
///   "time":{"created":<ms>}}` (packages/core/src/session/sql.ts,
///   packages/schema/src/session-message.ts, token-usage.ts).
/// - Older versions: the same message in v1's shape, `{"role":"assistant",
///   "modelID","providerID","cost","tokens":{…},"time":{"created":<ms>}}`
///   (packages/schema/src/v1/session.ts), in a `message(id, session_id, data)`
///   table or as storage/message/<session>/<message>.json files.
/// OpenCode has no plan limit of its own (it uses API keys or a provider's
/// account), so it's tokens and $ only; $ is the cost OpenCode recorded.
/// Not tried against a real install: no OpenCode on the Mac it was written on.
/// Kilo Code 7 is built on OpenCode and keeps the same tables in
/// ~/.local/share/kilo/kilo.db, so it's read here too, with its own names.
struct OpenCodeSource: UsageSource {
    let name: String
    let root: URL
    /// "opencode": opencode.db, opencode-<channel>.db; Kilo: "kilo" (it can also have opencode-<channel>.db).
    var databasePrefixes = ["opencode"]
    var databaseVariable = "OPENCODE_DB"

    init(root: URL = OpenCodeSource.dataDir, name: String = "OpenCode") {
        self.root = root
        self.name = name
    }

    /// Kilo Code 7 (Kilo-Org/kilocode v7.8.28, 2026-11-07): packages/core/src/global.ts
    /// (data dir $XDG_DATA_HOME/kilo) and packages/opencode/src/storage/db.ts (kilo.db,
    /// kilo-<channel>.db or opencode-<channel>.db; KILO_DB overrides).
    static func kilo(root: URL = kiloDataDir) -> OpenCodeSource {
        var source = OpenCodeSource(root: root, name: "Kilo Code")
        source.databasePrefixes = ["kilo", "opencode-"]
        source.databaseVariable = "KILO_DB"
        return source
    }

    static var kiloDataDir: URL { dataDir.deletingLastPathComponent().appendingPathComponent("kilo") }

    static var dataDir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("opencode")
    }

    static var binary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.opencode/bin/opencode", "\(home)/.local/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
            .first(where: FileManager.default.isExecutableFile)
    }

    var databases: [URL] {
        if let custom = ProcessInfo.processInfo.environment[databaseVariable], custom != ":memory:" {
            return [URL(fileURLWithPath: custom, relativeTo: root)]
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { file in databasePrefixes.contains { file.lastPathComponent.hasPrefix($0) } && file.pathExtension == "db" }
    }

    var watchPaths: [URL] { [root] }
    /// The command, a database or saved messages: an empty log folder alone isn't OpenCode.
    var isInstalled: Bool {
        (name == "OpenCode" && Self.binary != nil) || !databases.isEmpty
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("storage/message").path)
    }

    func usage(since dayStart: Date) -> SourceUsage {
        var result = SourceUsage(source: name, accuracy: .exact)
        var seen: Set<String> = []
        func add(_ data: Data) {
            guard let message = OpenCodeLog.message(data, since: dayStart), seen.insert(message.id).inserted else { return }
            result.byModel[message.model, default: TokenCounts()] += message.counts
            if message.cost > 0 { result.costs[message.model, default: 0] += message.cost }
            result.lastActivity = max(result.lastActivity ?? message.at, message.at)
        }
        let since = Int(dayStart.timeIntervalSince1970 * 1000)
        for file in databases {
            guard let db = SQLiteFile(file) else { continue }
            db.forEachRow("SELECT data FROM session_message WHERE type = 'assistant' AND time_created >= \(since)") { add(Data($0.text(0).utf8)) }
            db.forEachRow("SELECT data FROM message") { add(Data($0.text(0).utf8)) }   // older versions; filtered by time when parsed
        }
        let storage = root.appendingPathComponent("storage/message")
        if let walk = FileManager.default.enumerator(at: storage, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let file as URL in walk where file.pathExtension == "json" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard modified >= dayStart, let data = try? Data(contentsOf: file) else { continue }
                add(data)
            }
        }
        return result
    }
}

enum OpenCodeLog {
    struct Message {
        let id: String
        let model: String
        let counts: TokenCounts
        let cost: Double
        let at: Date
    }

    /// An assistant message from either shape, if it's from `since` on and has tokens.
    static func message(_ data: Data, since: Date) -> Message? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["type"] as? String == "assistant" || json["role"] as? String == "assistant",
              let tokens = json["tokens"] as? [String: Any],
              let created = ((json["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue else { return nil }
        let at = Date(timeIntervalSince1970: created / 1000)
        guard at >= since else { return nil }
        let model = (json["model"] as? [String: Any])?["id"] as? String ?? json["modelID"] as? String ?? "unknown"
        func number(_ value: Any?) -> Int { Int(count: (value as? NSNumber)?.doubleValue ?? 0) }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let counts = TokenCounts(input: number(tokens["input"]), output: number(tokens["output"]) + number(tokens["reasoning"]),
                                 cacheWrite: number(cache["write"]), cacheRead: number(cache["read"]), messages: 1)
        guard counts.total > 0 else { return nil }
        return Message(id: json["id"] as? String ?? UUID().uuidString, model: model, counts: counts,
                       cost: (json["cost"] as? NSNumber)?.doubleValue ?? 0, at: at)
    }
}

extension AccountsReader {
    /// OpenCode signs in per provider into auth.json. Only whether that file
    /// is there is looked at; it's never opened (its values are keys and tokens).
    static func openCode(dataDir: URL = OpenCodeSource.dataDir, installed: Bool = OpenCodeSource().isInstalled) -> AccountInfo? {
        guard installed else { return nil }
        let auth = dataDir.appendingPathComponent("auth.json")
        let size = (try? FileManager.default.attributesOfItem(atPath: auth.path)[.size] as? Int) ?? 0
        return AccountInfo(agent: "OpenCode", status: size > 2 ? "Signed in" : "Not signed in")
    }

    // MARK: - Cursor

    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    static let cursorState = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    /// The only rows asked for: the cached email and plan. The access and
    /// refresh tokens beside them are never selected.
    static let cursorKeys = ["cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType"]

    /// Cursor's usage is on its servers (it needs the session token), so only
    /// who's signed in and the plan, from the app's own state.
    static func cursor(state: URL = cursorState, installed: Bool? = nil) -> AccountInfo? {
        let hasState = FileManager.default.fileExists(atPath: state.path)
        guard installed ?? (installedApp(cursorBundleID) || hasState) else { return nil }
        var values: [String: String] = [:]
        if hasState, let db = SQLiteFile(state, copy: false) {
            let keys = cursorKeys.map { "'\($0)'" }.joined(separator: ", ")
            db.forEachRow("SELECT key, value FROM ItemTable WHERE key IN (\(keys))") { values[$0.text(0)] = $0.text(1) }
        }
        guard let email = values["cursorAuth/cachedEmail"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), email.contains("@") else {
            return AccountInfo(agent: "Cursor", status: "Not signed in")
        }
        let plan = values["cursorAuth/stripeMembershipType"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            .replacingOccurrences(of: "_", with: " ").capitalized.nonEmpty
        return AccountInfo(agent: "Cursor", status: email, plan: plan)
    }

    static let cursorUsagePage = URL(string: "https://cursor.com/dashboard?tab=usage")!
}
