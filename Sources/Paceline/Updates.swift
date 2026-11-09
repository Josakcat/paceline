import AppKit

/// "Check for Updates…": asks GitHub for the latest release only when it's
/// clicked (there's no automatic check), then offers its page in the browser.
enum Updates {
    static let latest = URL(string: "https://api.github.com/repos/Josakcat/paceline/releases/latest")!
    static let releases = URL(string: "https://github.com/Josakcat/paceline/releases")!

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

    /// One request, then an alert.
    @MainActor static func check() {
        Task {
            var request = URLRequest(url: latest, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let found: (tag: String, page: URL)? = await {
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tag = json["tag_name"] as? String else { return nil }
                return (tag, (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releases)
            }()
            let alert = NSAlert()
            if let found, isNewer(found.tag, than: current) {
                alert.messageText = "Paceline \(found.tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))) is available"
                alert.informativeText = "You have \(current). The release page has the download and what's new."
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Later")
            } else if found != nil {
                alert.messageText = "Paceline is up to date"
                alert.informativeText = "\(current) is the latest version."
            } else {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub didn't answer. You can look at the releases page yourself."
                alert.addButton(withTitle: "Open Releases")
                alert.addButton(withTitle: "OK")
            }
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn, alert.buttons.count > 1 {
                NSWorkspace.shared.open(found?.page ?? releases)
            }
        }
    }
}
