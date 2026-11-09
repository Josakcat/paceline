import Foundation

/// An extra Claude Code account: its own config folder, used through
/// CLAUDE_CONFIG_DIR. The main one (~/.claude) is plain "Claude" and isn't listed.
struct ClaudeAccount: Codable, Equatable, Identifiable, Sendable {
    let id: String          // file-safe: claude-usage-<id>.json, `--claude-limits <id>`
    var name: String        // what the panel and menu bar call it
    var configDir: String   // absolute path

    var configURL: URL { URL(fileURLWithPath: configDir) }
}

/// The list of extra accounts, kept in UserDefaults ("claudeAccounts").
enum ClaudeAccounts {
    static let key = "claudeAccounts"
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The saved list; before anything is saved, and only on a Mac that had
    /// AgentPet, its ~/.claude-account2 shows up as "Claude 2" (its files,
    /// `--claude-limits account2` and badge carry on). Once the list is saved,
    /// even empty, that's it. Elsewhere, found ~/.claude-* folders are added by hand.
    static func load(_ defaults: UserDefaults = Demo.defaults, home: URL = home, legacy: Bool = Legacy.agentPetWasHere) -> [ClaudeAccount] {
        if Demo.isOn && !Demo.isNewUser { return Demo.accounts }
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode([ClaudeAccount].self, from: data)) ?? []
        }
        let folder = home.appendingPathComponent(".claude-account2")
        guard legacy, !Demo.isOn, FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return [ClaudeAccount(id: "account2", name: "Claude 2", configDir: folder.path)]
    }

    static func save(_ accounts: [ClaudeAccount], _ defaults: UserDefaults = Demo.defaults) {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: key) }
    }

    /// "Work Team" → "work-team": lowercase letters, digits and dashes only, so
    /// it's safe in a file name (no "/", no ".."); "account" if nothing's left.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let slug = String(words.joined(separator: "-").prefix(32))
        return slug.isEmpty ? "account" : slug
    }

    /// The slug, made unique ("work", "work-2", …) among `existing` ids, ids the
    /// app uses itself ("claude" is the main account's: Fetch fresh numbers would
    /// save into its file), and ids whose limits file a removed account left
    /// behind (a new account mustn't start with someone else's numbers).
    static func newID(for name: String, existing: [ClaudeAccount],
                      leftover: (String) -> Bool = { FileManager.default.fileExists(atPath: PlanUsageReader.claudeFile(account: $0).path) }) -> String {
        let base = slug(name)
        let reserved = Set(Providers.all.map { slug($0.name) } + ["claude", "main", "account"])
        var id = reserved.contains(base) ? "\(base)-2" : base, n = reserved.contains(base) ? 3 : 2
        while existing.contains(where: { $0.id == id }) || leftover(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// Why a new account's name won't do, if it won't: empty, or already used.
    static func nameProblem(_ name: String, existing: [ClaudeAccount]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give it a name." }
        if Providers.all.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) || existing.contains(where: { $0.name == trimmed }) { return "That name is taken." }
        return nil
    }

    /// Why a folder won't do for a new account: none chosen, the main account's
    /// (~/.claude, or home itself, whose .claude.json is the main account's), or
    /// another's. Symlinks are followed, so a link to one of those is caught.
    static func folderProblem(_ dir: String, existing: [ClaudeAccount], home: String = NSHomeDirectory()) -> String? {
        if dir.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a folder." }
        func real(_ path: String) -> String { URL(fileURLWithPath: standardized(path)).resolvingSymlinksInPath().path }
        let path = real(dir)
        if path == real(home) { return "Your home folder holds the main account’s sign-in; choose a folder inside it." }
        if path == real(home + "/.claude") { return "~/.claude is the main account’s folder." }
        if existing.contains(where: { real($0.configDir) == path }) { return "Another account uses this folder." }
        return nil
    }

    /// The name typed for a found folder, or, if that won't do (empty, taken:
    /// the alert's button can't always re-check while typing), the folder's
    /// own ("Work"), numbered until it's free.
    static func usableName(_ name: String, dir: String, existing: [ClaudeAccount]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if nameProblem(trimmed, existing: existing) == nil { return trimmed }
        let base = Suggestions.defaultName(for: dir)
        var candidate = base, n = 2
        while nameProblem(candidate, existing: existing) != nil { candidate = "\(base) \(n)"; n += 1 }
        return candidate
    }

    /// The listed account a CLAUDE_CONFIG_DIR points at, if any ("~" and "/x/../" allowed).
    static func account(forConfigDir dir: String, in accounts: [ClaudeAccount]) -> ClaudeAccount? {
        let path = standardized(dir)
        return accounts.first { standardized($0.configDir) == path }
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// "~/…" for showing, when it's under home.
    static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A path for a shell command to paste: `~/…` bare when every character is
    /// harmless there, else the whole path in single quotes (a ' inside as '\'').
    static func shellPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,@%=:")
        if path.unicodeScalars.allSatisfy(plain.contains) {
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        return shellQuote(path)
    }

    /// Anything as one single-quoted shell word.
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// The badge on an extra account's Claude logo: 2, 3, … in list order.
    static func badge(for name: String, in accounts: [ClaudeAccount]) -> String? {
        accounts.firstIndex { $0.name == name }.map { String($0 + 2) }
    }

    enum StatusLineResult: Equatable { case added, alreadySet, noFolder, unreadable }

    /// Adds `"statusLine": {"type": "command", "command": …}` to an account's
    /// settings.json as one line after its opening brace: the rest of the file
    /// stays byte for byte (order, spacing, escapes), a symlinked file stays a
    /// link (the file it points to is written) and keeps its permissions.
    /// Never replaces a status line that's there, and never touches a file it
    /// can't read, or can't read as a JSON object.
    static func addStatusLine(command: String, toSettingsIn dir: URL) -> StatusLineResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return .noFolder }
        let file = dir.appendingPathComponent("settings.json").resolvingSymlinksInPath()
        guard let entry = try? JSONSerialization.data(withJSONObject: ["type": "command", "command": command], options: [.sortedKeys, .withoutEscapingSlashes])
        else { return .unreadable }
        let line = #""statusLine": "# + String(decoding: entry, as: UTF8.self)
        var text = "{\n  \(line)\n}\n"
        if fm.fileExists(atPath: file.path) {
            guard let data = fm.contents(atPath: file.path) else { return .unreadable }   // there, but not readable
            let original = String(decoding: data, as: UTF8.self)
            if !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let brace = original.firstIndex(of: "{") else { return .unreadable }
                guard json["statusLine"] == nil else { return .alreadySet }
                text = original[...brace] + "\n  " + line + (json.isEmpty ? "\n" : ",") + original[original.index(after: brace)...]
            }
        }
        let permissions = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions]
        guard (try? Data(text.utf8).write(to: file, options: .atomic)) != nil else { return .unreadable }
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        return .added
    }
}
