import AppKit
import SwiftUI

/// How the menu bar drop-down looks, all adjustable in Settings → Appearance.
/// Liquid Glass needs macOS 26; older systems use the frosted blur.
struct GlassAppearance: Codable, Equatable, Sendable {
    enum Material: String, Codable, CaseIterable, Sendable {
        case liquid, frosted
        var label: String { self == .liquid ? "Liquid Glass" : "Frosted" }
    }

    enum Tint: String, Codable, CaseIterable, Sendable {
        case none, orange, blue, purple, green, pink, graphite
        var label: String { rawValue.capitalized }
        var color: NSColor? {
            switch self {
            case .none: nil
            case .orange: NSColor(hex: 0xFF9F0A)
            case .blue: NSColor(hex: 0x0A84FF)
            case .purple: NSColor(hex: 0x8E5CF6)
            case .green: NSColor(hex: 0x30D158)
            case .pink: NSColor(hex: 0xFF5E9A)
            case .graphite: NSColor(hex: 0x5A5A64)
            }
        }
    }

    var material = Material.liquid
    var clear = false          // Liquid Glass "clear" style: more see-through
    var tint = Tint.none
    var tintStrength = 0.35    // 0…1
    var dim = 0.15             // 0…0.6, a dark layer under the content for legibility
    var roundness = 1.0        // 0…1, 1 = the default pill

    static let standard = GlassAppearance()
    static var liquidAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    /// Corner radius for a given default (18 for the drop-down).
    func radius(_ full: CGFloat) -> CGFloat { 8 + (full - 8) * roundness }

    init() {}

    // Missing keys fall back to the defaults, so older saved settings still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        material = try c.decodeIfPresent(Material.self, forKey: .material) ?? .liquid
        clear = try c.decodeIfPresent(Bool.self, forKey: .clear) ?? false
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? .none
        tintStrength = try c.decodeIfPresent(Double.self, forKey: .tintStrength) ?? 0.35
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? 0.15
        roundness = try c.decodeIfPresent(Double.self, forKey: .roundness) ?? 1
    }
}

/// The drop-down's background: Liquid Glass where
/// available (and chosen), else the frosted HUD blur, with tint and dim on top.
struct GlassSurface: View {
    let appearance: GlassAppearance
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    /// Clear glass and Increase Contrast get a floor of darkness so small text stays legible.
    private var dim: Double {
        max(appearance.dim, appearance.clear ? 0.2 : 0, contrast == .increased ? 0.35 : 0)
    }

    var body: some View {
        ZStack {
            if #available(macOS 26, *), appearance.material == .liquid {
                LiquidGlass(radius: radius, clear: appearance.clear,
                            tint: appearance.tint.color?.withAlphaComponent(appearance.tintStrength))
            } else {
                GlassBackground()
                if let tint = appearance.tint.color {
                    Color(nsColor: tint).opacity(appearance.tintStrength * 0.5)
                }
            }
            Color.black.opacity(dim)
        }
    }
}

/// NSGlassEffectView as a plain background (the SwiftUI content sits on top).
@available(macOS 26, *)
private struct LiquidGlass: NSViewRepresentable {
    let radius: CGFloat
    let clear: Bool
    let tint: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView { NSGlassEffectView() }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = radius
        view.style = clear ? .clear : .regular
        view.tintColor = tint
    }
}

/// The Paceline mark: three chevrons riding in line, faint to solid, front
/// one last. Drawn on a 130-unit grid, y down.
enum PacelineMark {
    static let chevrons: [[CGPoint]] = [28, 53, 78].map { x in
        [CGPoint(x: x, y: 47), CGPoint(x: x + 18, y: 65), CGPoint(x: x, y: 83)]
    }
    static let opacities: [CGFloat] = [0.3, 0.6, 1]

    /// The brand's mint: Settings' tint for switches and sliders (rather than
    /// the system accent, which may be red and look like "delete"). macOS only
    /// uses an app's own accent colour when the user's is Multicolor, so this
    /// is set in SwiftUI too. A deeper mint in light mode, where it's also the
    /// colour of link-style buttons' text (5:1 on white, 34D399 is under 2:1).
    static let mint = Color(nsColor: MenuBarInk.dynamic(light: NSColor(hex: 0x0A7350), dark: NSColor(hex: 0x34D399)))
    /// A deeper mint for prominent buttons, so their white titles read.
    static let deepMint = Color(hex: 0x12936B)

    /// Small renderings (the tiny app icons, the menu bar): the faint ones
    /// darker, or the back chevron melts into what's behind it.
    static let smallOpacities: [CGFloat] = [0.55, 0.8, 1]

    /// Strokes the chevrons in a y-down context already in grid units.
    static func draw(in ctx: CGContext, color: NSColor, opacities: [CGFloat] = opacities, lineWidth: CGFloat = 11) {
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (points, alpha) in zip(chevrons, opacities) {
            ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            ctx.addLines(between: points)
            ctx.strokePath()
        }
    }

    /// The app's own small icon (menu bar, panel header): only the chevrons,
    /// `width` points wide, a template so it takes the menu bar's colour.
    static func template(width: CGFloat = 18) -> NSImage {
        let bounds = CGRect(x: 22.5, y: 41.5, width: 79, height: 47)   // the chevrons and half their stroke
        let scale = width / bounds.width
        let image = NSImage(size: NSSize(width: width, height: (bounds.height * scale).rounded(.up)), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            draw(in: ctx, color: .black, opacities: smallOpacities)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Paceline"
        return image
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
