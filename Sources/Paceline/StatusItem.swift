import AppKit

/// The menu bar item: each AI's logo with its reading (plan % left, or $ today),
/// or the Paceline mark when there's nothing to show yet.
/// Left click toggles the drop-down; right click shows `makeMenu()`.
@MainActor
final class StatusItemController: NSObject {
    var onClick: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    private var item: NSStatusItem?
    /// The app's mark, until there's an AI logo to show.
    private let mark: NSImage? = PacelineMark.template(width: 18)

    /// One AI in the menu bar: its logo, or a short label when its app isn't installed.
    struct Segment {
        let icon: NSImage?
        let label: String?
        let text: String
        var low = false     // orange, this AI only
        var rows: [AIReading.Row] = []  // Two rows: 5h over Week; empty = `text` alone
        var stale = false   // old data: dimmed
        /// What the icon shows (the AI and its badge): a new NSImage each update says nothing.
        var iconKey: String? = nil

        /// Draws the same: same logo, text and colours (a Row's countdown only matters as orange or not).
        func drawsLike(_ other: Segment) -> Bool {
            (iconKey != nil ? iconKey == other.iconKey : icon === other.icon) && (icon == nil) == (other.icon == nil)
                && label == other.label && text == other.text && low == other.low && stale == other.stale
                && rows.map { [$0.text, $0.window, "\($0.low)", "\($0.warn)"] } == other.rows.map { [$0.text, $0.window, "\($0.low)", "\($0.warn)"] }
        }
    }

    /// Nothing to redraw: every segment draws the same and nothing else changed.
    static func sameDrawing(_ a: [Segment], _ b: [Segment], warning: Bool, _ otherWarning: Bool, tooltip: String?, _ otherTooltip: String?,
                            spoken: String?, _ otherSpoken: String?, style: MenuBarStyle, _ otherStyle: MenuBarStyle) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.drawsLike($1) }
            && warning == otherWarning && tooltip == otherTooltip && spoken == otherSpoken && style == otherStyle
    }

    /// The last update, redrawn when the menu bar turns light or dark.
    private var last: (segments: [Segment], warning: Bool, tooltip: String?, spoken: String?, style: MenuBarStyle)?
    private var appearanceObservation: NSKeyValueObservation?

    var isVisible: Bool { item != nil }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = mark
            item.button?.imagePosition = .imageLeading
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // One line always: a longer title widens the item instead of wrapping.
            item.button?.cell?.wraps = false
            item.button?.cell?.usesSingleLineMode = true
            item.button?.cell?.lineBreakMode = .byClipping
            item.button?.setAccessibilityHelp("Click for usage details. Right-click for options.")
            appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let last = self.last, last.style == .twoRows else { return }
                    self.update(segments: last.segments, warning: last.warning, tooltip: last.tooltip, spoken: last.spoken, style: last.style, force: true)
                }
            }
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            last = nil  // a new item starts blank: draw the next update
        }
    }

    /// `spoken` is what VoiceOver reads: the logos and the Two rows image say nothing.
    /// The same values as last time draw nothing, unless `force` (the bar turned light or dark).
    func update(segments: [Segment], warning: Bool, tooltip: String? = nil, spoken: String? = nil, style: MenuBarStyle = .compact, force: Bool = false) {
        guard let item, let button = item.button else { return }
        if !force, let last, Self.sameDrawing(last.segments, segments, warning: last.warning, warning, tooltip: last.tooltip, tooltip,
                                               spoken: last.spoken, spoken, style: last.style, style) { return }
        last = (segments, warning, tooltip, spoken, style)
        button.toolTip = tooltip
        button.setAccessibilityLabel(spoken.map { "AI Usage: \($0)" } ?? "AI Usage")
        // Logos replace the mark; with only text readings (or none) the mark stays.
        let logos = segments.contains { $0.icon != nil }
        if style == .twoRows, logos {
            button.attributedTitle = NSAttributedString()
            button.image = Self.twoRows(segments, appearance: button.effectiveAppearance)
            item.length = (button.image?.size.width ?? 0) + 6
            return
        }
        button.image = logos ? nil : mark
        button.attributedTitle = Self.title(segments, warning: warning)
        item.length = Self.compactLength(title: button.attributedTitle, image: button.image)
    }

    /// Measured from the title itself: once the length is fixed, fittingSize
    /// answers for the current width and wraps a longer title instead.
    /// The button's own insets (5pt for text, 8 with an image beside it), plus 3pt a side.
    static func compactLength(title: NSAttributedString, image: NSImage?) -> CGFloat {
        let text = title.length > 0 ? ceil(title.size().width) : 0
        let picture = image?.size.width ?? 0
        let insets: CGFloat = text == 0 ? 1 : picture == 0 ? 5 : 8
        return text + picture + insets + 6
    }

    /// Packed tight: kerning instead of spaces, slightly tighter digits and a
    /// small "%". Monospaced digits so it doesn't jiggle. Behind logos only a
    /// low AI's number is orange; without logos, `warning` turns it all orange.
    static func title(_ segments: [Segment], warning: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let logos = segments.contains { $0.icon != nil }
        var base: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0.5]
        if warning && !logos { base[.foregroundColor] = MenuBarInk.warning(left: nil) }
        let title = NSMutableAttributedString()
        /// Space after what's been added so far.
        func gap(_ points: CGFloat) {
            if title.length > 0 { title.addAttribute(.kern, value: points, range: NSRange(location: title.length - 1, length: 1)) }
        }
        if !logos, !segments.isEmpty { title.append(NSAttributedString(string: " ", attributes: base)) }  // after the mark
        for (i, segment) in segments.enumerated() {
            if i > 0 { gap(5) }
            var attributes = base
            // Old data is dimmed, low or not: it may have reset since.
            if segment.stale { attributes[.foregroundColor] = MenuBarInk.stale }
            else if segment.low { attributes[.foregroundColor] = MenuBarInk.warning(text: segment.text) }
            if let icon = segment.icon {
                // Text kerning doesn't move an attachment; the logo's own clear edge is the gap.
                let attachment = NSTextAttachment()
                attachment.image = icon
                // Centred on the digits rather than sitting on the baseline.
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
                title.append(NSAttributedString(attachment: attachment))
            } else if let label = segment.label {
                title.append(NSAttributedString(string: label, attributes: attributes))
                gap(3)
            }
            if segment.text.hasSuffix("%") {
                var digits = attributes
                digits[.kern] = -0.5
                title.append(NSAttributedString(string: String(segment.text.dropLast()), attributes: digits))
                var small = attributes
                small[.font] = NSFont.systemFont(ofSize: 7, weight: .medium)
                title.append(NSAttributedString(string: "%", attributes: small))
            } else {
                title.append(NSAttributedString(string: segment.text, attributes: attributes))
            }
        }
        return title
    }

    /// Two rows: each logo, then a column with the five hours over the week
    /// (right-aligned, no %), or one centred row. Drawn as one image in the
    /// menu bar's own appearance, so the numbers read on light and dark bars.
    static func twoRows(_ segments: [Segment], appearance: NSAppearance, height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        typealias Column = (icon: NSImage?, rows: [AIReading.Row], width: CGFloat, stale: Bool)
        let columns: [Column] = segments.map { segment in
            let rows = segment.rows.isEmpty ? [AIReading.Row(text: segment.text, low: segment.low)] : segment.rows
            let width = rows.map { NSAttributedString(string: $0.text, attributes: [.font: font]).size().width }.max() ?? 0
            return (segment.icon, rows, ceil(width), segment.stale)
        }
        let logoGap: CGFloat = 1.5, aiGap: CGFloat = 5
        let width = columns.reduce(0) { $0 + ($1.icon?.size.width ?? 0) + logoGap + $1.width } + aiGap * CGFloat(max(0, columns.count - 1))
        return NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 0
                for column in columns {
                    if let icon = column.icon {
                        icon.draw(in: NSRect(x: x, y: ((height - icon.size.height) / 2).rounded(), width: icon.size.width, height: icon.size.height))
                        x += icon.size.width + logoGap
                    }
                    // Baselines: two rows 2pt apart around the middle, or one centred.
                    let baselines = column.rows.count > 1
                        ? [height / 2 + 1, height / 2 - 1 - font.capHeight]
                        : [(height - font.capHeight) / 2]
                    for (row, baseline) in zip(column.rows, baselines) {
                        // labelColor in the menu bar's vibrant appearance comes out clear in an
                        // image; MenuBarInk's are plain colours, picked by the drawing appearance.
                        let color = column.stale ? MenuBarInk.stale : row.warn ? MenuBarInk.warning(text: row.text) : MenuBarInk.text
                        let text = NSAttributedString(string: row.text, attributes: [.font: font, .foregroundColor: color])
                        text.draw(at: NSPoint(x: x + column.width - text.size().width, y: baseline.rounded() + font.descender))
                    }
                    x += column.width + aiGap
                }
            }
            return true
        }
    }

    /// The last reading drawn on a plain light or dark bar at 2x, for `--debug snapshot`
    /// (the item's own view draws on nothing, so its text can't be judged).
    func preview(dark: Bool, padding: CGFloat = 8) -> NSImage? {
        guard let last, let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        let height = NSStatusBar.system.thickness
        let logos = last.segments.contains { $0.icon != nil }
        let picture: NSImage? = last.style == .twoRows && logos ? Self.twoRows(last.segments, appearance: appearance) : nil
        let title = picture == nil ? Self.title(last.segments, warning: last.warning) : nil
        let content = picture?.size.width ?? ceil(title?.size().width ?? 0) + (logos ? 0 : (mark?.size.width ?? 0))
        let size = NSSize(width: content + padding * 2, height: height)
        let image = NSImage(size: size, flipped: false) { [mark] rect in
            appearance.performAsCurrentDrawingAppearance {
                (dark ? MenuBarInk.darkBar : MenuBarInk.lightBar).setFill()
                rect.fill()
                if let picture {
                    picture.draw(in: NSRect(x: padding, y: 0, width: picture.size.width, height: height))
                } else if let title {
                    var x = padding
                    if !logos, let mark {
                        mark.draw(in: NSRect(x: x, y: ((height - mark.size.height) / 2).rounded(), width: mark.size.width, height: mark.size.height))
                        x += mark.size.width
                    }
                    title.draw(at: NSPoint(x: x, y: ((height - title.size().height) / 2).rounded()))
                }
            }
            return true
        }
        return image
    }

    /// The icon's frame in screen coordinates, to hang the drop-down from.
    var buttonFrame: NSRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    var screen: NSScreen? { item?.button?.window?.screen }
    var buttonView: NSView? { item?.button }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let menu = makeMenu?(), let button = item?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        } else {
            onClick?()
        }
    }
}

/// An NSMenuItem that runs a closure, so menus don't need @objc targets.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// One AI's line in the menu bar, e.g. Claude "72%" or Antigravity "$1.20".
struct AIReading: Equatable, Sendable {
    let name: String
    let text: String
    let low: Bool
    let lastActive: Date?
    /// Two rows style: the five hours, then the week, each with its own low.
    var rows: [Row] = []

    struct Row: Equatable, Sendable {
        let text: String
        let low: Bool
        var window = ""     // "5h" or "Week"
        var runsOut: TimeInterval? = nil   // at this pace, gone this long before the reset

        /// Orange-worthy: low, or on pace to run out.
        var warn: Bool { low || runsOut != nil }
    }

    /// The soonest a window runs out, if one will.
    var runsOut: TimeInterval? { rows.compactMap(\.runsOut).min() }
    private var runsOutNote: String { runsOut.map { ", runs out in \(PlanWindow.duration($0))" } ?? "" }
    /// "as of 7 h ago" when the plan behind the numbers is old.
    var staleNote: String? = nil

    /// "5h 62% · Week 38% left", or "$1.20 today".
    var summary: String {
        rows.isEmpty ? text + (text.hasSuffix("%") ? " left" : " today")
            : rows.map { "\($0.window) \($0.text)%" }.joined(separator: " · ") + " left" + runsOutNote
    }

    /// The menu bar's tooltip: a line per AI.
    static func tooltip(_ readings: [AIReading]) -> String {
        readings.map { "\($0.name): \($0.summary)" + ($0.staleNote.map { " · \($0)" } ?? "") }.joined(separator: "\n")
    }

    /// For VoiceOver: "Claude 5-hour 62% left, weekly 38% left; Antigravity weekly 12% left, low, as of 1 d ago".
    static func spoken(_ readings: [AIReading]) -> String {
        readings.map { reading in
            let parts = reading.rows.isEmpty ? [reading.summary]
                : reading.rows.map { "\(PlanWindow.spokenName($0.window)) \($0.text)% left" }
            let low = reading.low || reading.rows.contains(where: \.low)
            return "\(reading.name) " + parts.joined(separator: ", ") + (low ? ", low" : "") + (reading.rows.isEmpty ? "" : reading.runsOutNote)
                + (reading.staleNote.map { ", \($0)" } ?? "")
        }.joined(separator: "; ")
    }

    /// Short enough to sit beside others in the menu bar.
    var short: String { AILogos.short(for: name, badge: badge) }

    /// Drawn on the logo's corner to tell an extra account apart (set by the model).
    var badge: String? = nil

    /// Every AI, or only the one used last. Never-used AIs sort last; ties keep
    /// the list order (Claude first).
    static func shown(_ readings: [AIReading], shows: MenuBarShows) -> [AIReading] {
        guard shows == .latest else { return readings }
        let latest = readings.enumerated().max { a, b in
            let (x, y) = (a.element.lastActive ?? .distantPast, b.element.lastActive ?? .distantPast)
            return x != y ? x < y : a.offset > b.offset
        }
        return latest.map { [$0.element] } ?? []
    }

    /// The menu bar as plain text, for when no logos are available. A lone
    /// reading goes without its label; with several AIs each gets one.
    static func title(_ readings: [AIReading], shows: MenuBarShows) -> (text: String, low: Bool) {
        let shown = shown(readings, shows: shows)
        let labelled = readings.count > 1
        let text = shown.map { labelled ? "\($0.short) \($0.text)" : $0.text }.joined(separator: "  ")
        return (text, shown.contains(where: \.low))
    }
}

/// Each AI's logo, taken from its app on this Mac (so nothing is bundled),
/// sized for the menu bar. Without an app to take it from (a CLI, an
/// extension, or the app isn't here), the same grey letter badge for all.
@MainActor
enum AILogos {
    private static var cache: [String: NSImage?] = [:]

    /// "OC", "C2" for a second Claude account, or the name's first two letters.
    nonisolated static func short(for name: String, badge: String? = nil) -> String {
        if let badge { return "C" + badge }
        return Providers.named(name)?.short ?? String(name.prefix(2)).uppercased()
    }

    /// The app's own icon, if it's installed. An extra Claude account wears Claude's.
    static func appIcon(for name: String, size: CGFloat = 18) -> NSImage? {
        let key = "\(name)@\(size)"
        if let cached = cache[key] { return cached }
        let owner = Providers.named(name) ?? (badge(for: name) == nil ? nil : Providers.named("Claude"))
        let image = owner?.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { url -> NSImage in
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        // Not found isn't kept: an app installed later gets its logo without a relaunch.
        if image != nil { cache[key] = image }
        return image
    }

    /// The logo, or the letter badge.
    static func icon(for name: String, size: CGFloat = 18) -> NSImage {
        appIcon(for: name, size: size) ?? letters(short(for: name, badge: badge(for: name)), canvas: NSSize(width: size, height: size))
    }

    /// A grey rounded square with white letters: readable on light and dark
    /// menu bars alike, and plainly not anyone's logo.
    static func letters(_ text: String, canvas size: NSSize) -> NSImage {
        let key = "letters:\(text)@\(size.width)x\(size.height)"
        if let cached = cache[key], let cached { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            let side = min(size.width, size.height)
            let box = NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side).insetBy(dx: side * 0.04, dy: side * 0.04)
            NSColor(white: 0.46, alpha: 1).setFill()
            NSBezierPath(roundedRect: box, xRadius: side * 0.24, yRadius: side * 0.24).fill()
            let fontSize = side * (text.count > 2 ? 0.36 : 0.46)
            let label = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white, .kern: -0.2])
            let t = label.size()
            label.draw(at: NSPoint(x: box.midX - t.width / 2, y: box.midY - t.height / 2))
            return true
        }
        image.accessibilityDescription = text
        cache[key] = image
        return image
    }

    /// The menu bar logo: 14pt, its clear side margins cropped, and a badge
    /// (an extra account's number) drawn into its top-right corner.
    static let menuBarSize = NSSize(width: 11.5, height: 14)

    /// The 2, 3, … that tells extra Claude accounts apart, wherever their logo shows.
    nonisolated static func badge(for name: String, accounts: [ClaudeAccount] = ClaudeAccounts.load()) -> String? {
        ClaudeAccounts.badge(for: name, in: accounts)
    }

    static func menuBarIcon(for name: String, badge: String?) -> NSImage {
        // Letters need the full 14pt square; a logo's clear sides are cropped.
        appIcon(for: name, size: menuBarSize.height) == nil ? letters(short(for: name, badge: badge), canvas: NSSize(width: 14, height: 14))
            : badged(name, badge: badge, canvas: menuBarSize)
    }

    /// The logo with its badge (if any) at `size`, for the panel and Settings.
    static func listIcon(for name: String, size: CGFloat) -> NSImage {
        guard let badge = badge(for: name), appIcon(for: name, size: size) != nil else { return icon(for: name, size: size) }
        return badged(name, badge: badge, canvas: NSSize(width: size, height: size))
    }

    /// The logo centred on `canvas` (a narrower canvas crops its clear sides),
    /// with the badge drawn into its top-right corner.
    private static func badged(_ name: String, badge: String?, canvas size: NSSize) -> NSImage {
        guard let icon = appIcon(for: name, size: size.height) else { return letters(short(for: name, badge: badge), canvas: size) }
        let key = "\(name)@\(size.width)x\(size.height)\(badge ?? "")"
        if let cached = cache[key], let cached { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: (size.width - size.height) / 2, y: 0, width: size.height, height: size.height))
            if let badge {
                let d = size.height * 0.54
                let dot = NSRect(x: size.width - d, y: size.height - d, width: d, height: d)
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
                let text = NSAttributedString(string: badge, attributes: [
                    .font: NSFont.systemFont(ofSize: d * 0.87, weight: .heavy), .foregroundColor: NSColor.windowBackgroundColor])
                let t = text.size()
                text.draw(at: NSPoint(x: dot.midX - t.width / 2, y: dot.midY - t.height / 2))
            }
            return true
        }
        cache[key] = image
        return image
    }
}

/// Menu bar text that keeps 4.5:1 on a light bar and a dark one (the self-test
/// checks it on a greyer light bar and a lighter dark bar than usual). The
/// system orange and red are too light on a light bar, so deeper ones there,
/// and a lighter red on a dark bar. Dynamic: the bar's own appearance picks.
enum MenuBarInk {
    static let lightBar = NSColor(srgbRed: 0.86, green: 0.86, blue: 0.86, alpha: 1)
    static let darkBar = NSColor(srgbRed: 0.23, green: 0.23, blue: 0.23, alpha: 1)

    static let text = dynamic(light: NSColor(white: 0, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.9))
    static let stale = dynamic(light: NSColor(white: 0, alpha: 0.62), dark: NSColor(white: 1, alpha: 0.62))
    static let orange = dynamic(light: NSColor(hex: 0x9A4500), dark: NSColor(hex: 0xFF9F0A))
    static let red = dynamic(light: NSColor(hex: 0xB3001B), dark: NSColor(hex: 0xFF8A80))

    /// Red at 10% or less, orange otherwise (low, or on course to run out).
    static func warning(left: Int?) -> NSColor { (left ?? 100) <= 10 ? red : orange }
    static func warning(text: String) -> NSColor {
        warning(left: Int(text.hasSuffix("%") ? String(text.dropLast()) : text))
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    /// WCAG contrast of `color` (its alpha laid over `bar`) on `bar`, as `appearance` draws it.
    static func contrast(_ color: NSColor, on bar: NSColor, dark: Bool) -> CGFloat {
        var resolved = color
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? .currentDrawing()).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        guard let bg = bar.usingColorSpace(.sRGB) else { return 0 }
        let a = resolved.alphaComponent
        func lum(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let fg = lum(resolved.redComponent * a + bg.redComponent * (1 - a), resolved.greenComponent * a + bg.greenComponent * (1 - a),
                     resolved.blueComponent * a + bg.blueComponent * (1 - a))
        let back = lum(bg.redComponent, bg.greenComponent, bg.blueComponent)
        return (max(fg, back) + 0.05) / (min(fg, back) + 0.05)
    }
}

/// One warning rule for the panel and the menu bar: orange at 20% left or
/// less, red at 10% or less.
enum Warning {
    static func color(left: Int) -> NSColor? { left <= 10 ? .systemRed : left <= 20 ? .systemOrange : nil }

    /// From a reading's own text, "8%" or "8".
    static func color(text: String) -> NSColor? {
        Int(text.hasSuffix("%") ? String(text.dropLast()) : text).flatMap(color(left:))
    }
}
