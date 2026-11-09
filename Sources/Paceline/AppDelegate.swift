import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        controller.start()
        self.controller = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
