import Foundation

extension SelfTest {
    /// Install updates: the .sha256 file, the hash, the release's assets, and which copies may replace themselves.
    static func updateTests() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  updates: \(what)")
        }

        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        check(Updates.parseChecksum("\(abc)  Paceline.zip\n") == abc && Updates.parseChecksum("\(abc) Paceline.zip") == abc
              && Updates.parseChecksum(abc) == abc, "sha256 file: two spaces, one space, or the hash alone")
        check(Updates.parseChecksum("\(abc.uppercased())  Paceline.zip") == abc, "an uppercase hash is lowercased")
        check(Updates.parseChecksum("\(abc)  Other.zip") == nil && Updates.parseChecksum("\(abc)   Paceline.zip") == nil
              && Updates.parseChecksum("\(abc)Paceline.zip") == nil, "a wrong name, three spaces or no space is refused")
        check(Updates.parseChecksum("\(abc.dropLast())  Paceline.zip") == nil && Updates.parseChecksum("") == nil,
              "a 63-character hash or an empty file is refused")
        check(Updates.parseChecksum("<html>Not Found</html>") == nil && Updates.parseChecksum(String(repeating: "z", count: 64)) == nil,
              "junk and non-hex are refused")

        check(Updates.sha256Hex(Data("abc".utf8)) == abc, "sha256 of \"abc\" is the known value")
        check(Updates.sha256Hex(Data("abd".utf8)) != abc, "other bytes don't match it")

        func release(_ json: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        let both = release("""
        {"tag_name": "v0.2.0", "assets": [
          {"name": "Paceline.dmg", "browser_download_url": "https://github.com/Josakcat/paceline/releases/download/v0.2.0/Paceline.dmg"},
          {"name": "Paceline.zip.sha256", "browser_download_url": "https://github.com/Josakcat/paceline/releases/download/v0.2.0/Paceline.zip.sha256"},
          {"name": "Paceline.zip", "browser_download_url": "https://github.com/Josakcat/paceline/releases/download/v0.2.0/Paceline.zip"}]}
        """)
        let picked = Updates.assetURLs(both)
        check(picked?.zip.lastPathComponent == "Paceline.zip" && picked?.checksum.lastPathComponent == "Paceline.zip.sha256",
              "assets: the zip and its .sha256 by exact name")
        let noSum = release("""
        {"tag_name": "v0.2.0", "assets": [
          {"name": "Paceline.zip", "browser_download_url": "https://github.com/Josakcat/paceline/releases/download/v0.2.0/Paceline.zip"}]}
        """)
        let plainHTTP = release("""
        {"assets": [{"name": "Paceline.zip", "browser_download_url": "http://example.com/Paceline.zip"},
          {"name": "Paceline.zip.sha256", "browser_download_url": "https://example.com/Paceline.zip.sha256"}]}
        """)
        check(Updates.assetURLs(noSum) == nil && Updates.assetURLs(release("{}")) == nil, "assets: no .sha256 or no assets → nothing to install")
        check(Updates.assetURLs(plainHTTP) == nil, "assets: a plain http URL is refused")

        func kind(_ path: String, cask: Bool = false, writable: Bool = true) -> Updates.InstallKind {
            Updates.installKind(appPath: path, caskroomExists: cask, parentWritable: writable)
        }
        check(kind(NSHomeDirectory() + "/Applications/Paceline.app") == .updatable && kind("/Applications/Paceline.app") == .updatable,
              "~/Applications and /Applications can update")
        check(kind("/Applications/Paceline.app", cask: true) == .homebrew
              && Updates.notUpdatableReason(.homebrew)?.contains("brew upgrade --cask paceline") == true,
              "a Caskroom means Homebrew: brew upgrade, never self-replace")
        let volumes = kind("/Volumes/Paceline/Paceline.app")
        let translocated = kind("/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/Paceline.app")
        let readOnly = kind("/Applications/Paceline.app", writable: false)
        func blocked(_ k: Updates.InstallKind) -> Bool { if case .notUpdatable = k { true } else { false } }
        check(blocked(volumes) && blocked(translocated) && blocked(readOnly) && blocked(kind("/usr/local/bin/Paceline")),
              "a disk image, AppTranslocation, a read-only folder or no .app can't update")
        return failures
    }
}
