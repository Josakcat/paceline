import AppKit
import CryptoKit

/// "Check for Updates…" asks GitHub for the latest release when it's clicked. With
/// "Install updates automatically" on (off by default), it also asks at launch and then
/// once a day, and installs a newer release by itself. Each check is one GET; nothing is sent.
///
/// Quarantine: Paceline never adds or removes com.apple.quarantine. Files that URLSession
/// downloads don't get that attribute (only browsers and other LSFileQuarantine apps set
/// it), so there's nothing to strip, and the installed copy keeps whatever it had.
/// The .sha256 proves the zip is complete and unchanged in transit; it isn't a signature.
enum Updates {
    static let latest = URL(string: "https://api.github.com/repos/Josakcat/paceline/releases/latest")!
    static let releases = URL(string: "https://github.com/Josakcat/paceline/releases")!
    static let autoKey = "autoUpdate"
    static let zipName = "Paceline.zip"

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "v0.2.0" newer than "0.1.0"? Numbers compared part by part ("0.1.10" > "0.1.9");
    /// a pre-release ("1.0.0-beta.2") is older than its release, and any prefix
    /// before the first digit ("paceline-v1.2") is skipped.
    static func isNewer(_ tag: String, than version: String) -> Bool {
        func parse(_ s: String) -> (parts: [Int], pre: Bool) {
            let start = s.drop { !$0.isNumber }
            let core = start.prefix { $0.isNumber || $0 == "." }
            return (core.split(separator: ".").map { Int($0) ?? 0 }, start.dropFirst(core.count).first == "-")
        }
        let (a, b) = (parse(tag), parse(version))
        for i in 0..<max(a.parts.count, b.parts.count) {
            let (x, y) = (i < a.parts.count ? a.parts[i] : 0, i < b.parts.count ? b.parts[i] : 0)
            if x != y { return x > y }
        }
        return !a.pre && b.pre
    }

    // MARK: - Pure checks

    /// The hash in a .sha256 file ("<64 hex>  Paceline.zip", or the hash alone), lowercased.
    /// One or two spaces before the name; a name that's there must be `name`.
    static func parseChecksum(_ text: String, name: String = zipName) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let hash = line.prefix(64).lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        let rest = line.dropFirst(64)
        if rest.isEmpty { return hash }
        for gap in ["  ", " "] where rest.hasPrefix(gap) {
            return rest.dropFirst(gap.count) == name ? hash : nil
        }
        return nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The release's Paceline.zip and Paceline.zip.sha256, both https; nil if either is missing.
    static func assetURLs(_ release: [String: Any]) -> (zip: URL, checksum: URL)? {
        let assets = release["assets"] as? [[String: Any]] ?? []
        func url(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
                .flatMap { $0.scheme == "https" ? $0 : nil }
        }
        guard let zip = url(zipName), let checksum = url(zipName + ".sha256") else { return nil }
        return (zip, checksum)
    }

    enum InstallKind: Equatable {
        case updatable
        case homebrew
        case notUpdatable(String)
    }

    /// Can this copy replace itself? Homebrew copies never do: `brew upgrade` updates them.
    static func installKind(appPath: String, caskroomExists: Bool, parentWritable: Bool) -> InstallKind {
        let path = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
        if path.hasPrefix("/Volumes/") { return .notUpdatable("Paceline is running from a disk image. Move it to Applications first.") }
        if path.contains("/AppTranslocation/") { return .notUpdatable("macOS is running Paceline from a temporary copy. Move it to Applications and open it from there.") }
        if !path.hasSuffix(".app") { return .notUpdatable("Paceline isn't running from an app bundle.") }
        if caskroomExists { return .homebrew }
        if !parentWritable { return .notUpdatable("Paceline can't write to the folder it's in.") }
        return .updatable
    }

    /// This copy, as it is on this Mac.
    static func thisInstall() -> InstallKind {
        let path = Bundle.main.bundleURL.path
        let fm = FileManager.default
        let cask = ["/opt/homebrew/Caskroom/paceline", "/usr/local/Caskroom/paceline"].contains { fm.fileExists(atPath: $0) }
        return installKind(appPath: path, caskroomExists: cask,
                           parentWritable: fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent))
    }

    static func notUpdatableReason(_ kind: InstallKind) -> String? {
        switch kind {
        case .updatable: nil
        case .homebrew: "Paceline came from Homebrew. Run brew upgrade --cask paceline."
        case .notUpdatable(let reason): reason
        }
    }

    // MARK: - Asking GitHub

    struct Release {
        let tag: String
        let page: URL
        let assets: (zip: URL, checksum: URL)?
        var version: String { tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
    }

    static func fetchLatest() async -> Release? {
        var request = URLRequest(url: latest, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return Release(tag: tag, page: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releases, assets: assetURLs(json))
    }

    // MARK: - Check for Updates… (manual)

    @MainActor private static var installing = false

    @MainActor static func check() {
        Task {
            let found = await fetchLatest()
            let alert = NSAlert()
            var actions: [() -> Void] = []
            if let found, isNewer(found.tag, than: current) {
                alert.messageText = "Paceline \(found.version) is available"
                var reason = notUpdatableReason(thisInstall())
                if reason == nil, found.assets == nil { reason = "This release has no Paceline.zip with a checksum to install from." }
                if let reason {
                    alert.informativeText = "You have \(current). \(reason)"
                } else {
                    alert.informativeText = "You have \(current). Paceline downloads it, checks it and opens again."
                    alert.addButton(withTitle: "Install and Relaunch")
                    actions.append { install(found, automatic: false) }
                }
                alert.addButton(withTitle: "Release Page")
                actions.append { NSWorkspace.shared.open(found.page) }
                alert.addButton(withTitle: "Later")
            } else if found != nil {
                alert.messageText = "Paceline is up to date"
                alert.informativeText = "\(current) is the latest version."
            } else {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub didn't answer. You can look at the releases page yourself."
                alert.addButton(withTitle: "Open Releases")
                actions.append { NSWorkspace.shared.open(releases) }
                alert.addButton(withTitle: "OK")
            }
            NSApp.activate()
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if index >= 0, index < actions.count { actions[index]() }
        }
    }

    // MARK: - Install updates automatically

    @MainActor private static var timer: Timer?

    /// At launch, and when the setting is turned on: checks now, then once a day.
    @MainActor static func startAuto() {
        guard !Demo.isOn, Demo.defaults.bool(forKey: autoKey) else { timer?.invalidate(); timer = nil; return }
        schedule(after: 5)
    }

    @MainActor private static func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { autoTick() }
        }
    }

    @MainActor private static func autoTick() {
        guard Demo.defaults.bool(forKey: autoKey) else { return }
        // Someone's using Paceline right now: don't pull it away; try again in an hour.
        if NSApp.isActive || installing { schedule(after: 3600); return }
        schedule(after: 24 * 3600)
        Task {
            guard let found = await fetchLatest() else { return NSLog("Paceline update: GitHub didn't answer; trying again tomorrow") }
            guard isNewer(found.tag, than: current) else { return }
            if let reason = notUpdatableReason(thisInstall()) { return NSLog("Paceline update: \(found.version) not installed: \(reason)") }
            install(found, automatic: true)
        }
    }

    // MARK: - Installing

    struct Failure: Error { let reason: String }

    @MainActor static func install(_ release: Release, automatic: Bool) {
        guard !installing else { return }
        installing = true
        let appURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let version = current
        Task {
            let result: Result<Void, Failure>
            do {
                try await download(release, replacing: appURL, bundleID: bundleID, version: version)
                result = .success(())
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(Failure(reason: error.localizedDescription))
            }
            installing = false
            switch result {
            case .success:
                relaunch(appURL)
            case .failure(let failure):
                NSLog("Paceline update: \(release.version) not installed: \(failure.reason)")
                guard !automatic else { return }   // the daily check tries again tomorrow
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't install Paceline \(release.version)"
                alert.informativeText = "\(failure.reason) You can download it from the release page."
                alert.addButton(withTitle: "Release Page")
                alert.addButton(withTitle: "OK")
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            }
        }
    }

    /// Downloads, checks the sha256, unzips beside the app (same volume), checks the new
    /// app, and swaps it in. Throws before touching the installed app if anything's off.
    private static func download(_ release: Release, replacing appURL: URL, bundleID: String, version: String) async throws {
        guard let assets = release.assets else { throw Failure(reason: "The release has no Paceline.zip with a checksum.") }
        let fm = FileManager.default
        let work: URL
        do {
            work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        } catch { throw Failure(reason: "Couldn't make a folder for the download.") }
        defer { try? fm.removeItem(at: work) }

        func get(_ url: URL) async throws -> URL {
            guard url.scheme == "https" else { throw Failure(reason: "The download isn't over HTTPS.") }
            let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 120))
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https" else {
                try? fm.removeItem(at: file)
                throw Failure(reason: "The download failed.")
            }
            let kept = work.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(at: file, to: kept)
            return kept
        }
        let sumFile = try await get(assets.checksum)
        guard let expected = parseChecksum((try? String(contentsOf: sumFile, encoding: .utf8)) ?? "") else {
            throw Failure(reason: "The release's checksum file isn't readable.")
        }
        let zip = try await get(assets.zip)

        try await Task.detached {
            let fm = FileManager.default
            guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe), sha256Hex(data) == expected else {
                try? fm.removeItem(at: zip)
                throw Failure(reason: "The download doesn't match the release's checksum.")
            }
            let unzipped = work.appendingPathComponent("unzipped")
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path]) == 0 else { throw Failure(reason: "The download couldn't be unzipped.") }
            let newApp = unzipped.appendingPathComponent("Paceline.app")
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard let id = info?["CFBundleIdentifier"] as? String, id == bundleID, !bundleID.isEmpty else {
                throw Failure(reason: "The download isn't Paceline.")
            }
            guard let newVersion = info?["CFBundleShortVersionString"] as? String, isNewer(newVersion, than: version) else {
                throw Failure(reason: "The download isn't newer than \(version).")
            }
            guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
                throw Failure(reason: "The downloaded app's code signature doesn't check out.")
            }
            do {
                _ = try fm.replaceItemAt(appURL, withItemAt: newApp)
            } catch { throw Failure(reason: "Couldn't replace the app: \(error.localizedDescription)") }
        }.value
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A detached shell waits (up to 10 s) for this process to end, then opens the new app.
    @MainActor private static func relaunch(_ appURL: URL) {
        let script = """
        i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ $i -gt 50 ] && exit 0; sleep 0.2; done; /usr/bin/open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSLog("Paceline update: installed; open it again yourself") }
        NSApp.terminate(nil)
    }
}
