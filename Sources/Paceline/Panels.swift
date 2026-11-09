import AppKit
import SwiftUI

/// Borderless, non-activating, floats over every Space and full-screen apps.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The app is never active, so the first click has to count.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A regular window (Settings), built on first show. The app is an accessory
/// app, so it activates itself to take keyboard focus.
@MainActor
final class AppWindow<Content: View> {
    private let title: String
    private let size: NSSize
    private let content: () -> Content
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// Settings shows account emails, so it follows "Hide from screen sharing" too.
    var sharingType: NSWindow.SharingType = .readOnly {
        didSet { window?.sharingType = sharingType }
    }

    init(title: String, size: NSSize, content: @escaping () -> Content) {
        self.title = title
        self.size = size
        self.content = content
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: content())
            // The window's size is ours (fitContent), not SwiftUI's ideal size per tab.
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(size)
            window.contentMinSize = NSSize(width: 460, height: 200)
            window.isReleasedWhenClosed = false
            window.sharingType = sharingType
            window.center()
            self.window = window
            // Closed, it's let go: SwiftUI's form and its tabs held ~30 MB for the
            // rest of the run otherwise. Opening it again builds it anew.
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let observer = self.closeObserver { NotificationCenter.default.removeObserver(observer) }
                    self.closeObserver = nil
                    self.fitTask?.cancel()
                    let closing = self.window
                    self.window = nil
                    DispatchQueue.main.async { closing?.contentViewController = nil }
                }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private var fitTask: Task<Void, Never>?

    /// The shown form's content is `formHeight` tall: the window takes that plus
    /// what isn't the form (the tab bar), keeping its top edge where it is and
    /// never going past the bottom of the screen (taller content scrolls).
    /// Settled a moment later, so a burst of layout changes moves it once.
    func fitContent(toForm formHeight: CGFloat) {
        fitTask?.cancel()
        fitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.applyFit(formHeight)
        }
    }

    private func applyFit(_ formHeight: CGFloat) {
        guard let window, let content = window.contentView, let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              let form = Self.scrollViews(in: content).max(by: { $0.frame.height < $1.frame.height }) else { return }
        let target = (formHeight + content.frame.height - form.frame.height).rounded()
        let frame = window.frame
        let wanted = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content.frame.width, height: target)).height
        let height = min(wanted, frame.maxY - visible.minY)
        guard abs(height - frame.height) >= 1 else { return }
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
                        display: true, animate: window.isVisible)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    var contentView: NSView? { window?.isVisible == true ? window?.contentView : nil }
    var sheetView: NSView? { window?.attachedSheet?.contentView }
}

