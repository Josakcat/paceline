import Foundation

/// Where Paceline keeps what it can't get back for free: the saved plan
/// numbers (`claude-usage*.json`, `antigravity-usage.json`) and the 30-day
/// history. Application Support, because macOS may empty ~/Library/Caches at
/// any time. Only throwaway things (the build copy) stay in Caches.
enum DataFolder {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let url = home.appendingPathComponent("Library/Application Support/Paceline")
    /// Where versions up to 0.1.8 saved the plan numbers.
    static let oldURL = home.appendingPathComponent("Library/Caches/Paceline")

    /// The files that used to live in `oldURL` and belong in `url`.
    static func isOurs(_ name: String) -> Bool {
        name.hasSuffix(".json") && (name.hasPrefix("claude-usage") || name == "antigravity-usage.json")
    }

    /// Moves each of our files from `old` to `new` unless `new` already has one
    /// by that name. Leaves everything else in `old` alone. Returns the names moved.
    @discardableResult
    static func migrate(from old: URL = oldURL, to new: URL = url, fileManager fm: FileManager = .default) -> [String] {
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return [] }
        var moved: [String] = []
        for name in names.sorted() where isOurs(name) {
            let target = new.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            if (try? fm.moveItem(at: old.appendingPathComponent(name), to: target)) != nil { moved.append(name) }
        }
        return moved
    }
}
