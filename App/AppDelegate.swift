import AppKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?

    /// URLs that arrived from Finder before applicationDidFinishLaunching
    /// completed. Flushed once mainWindowController is ready.
    private var pendingURLs: [URL] = []

    // Custom entry point — no nib/storyboard, so we set the delegate manually
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.setup()
        let wc = MainWindowController()
        mainWindowController = wc
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Open any files that Finder requested before the window existed.
        for url in pendingURLs {
            wc.openFile(at: url)
        }
        pendingURLs.removeAll()

        wc.startCrashRecovery()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let wc = mainWindowController else { return .terminateNow }
        // If window close already confirmed discard, don't ask again
        if wc.closingConfirmed { return .terminateNow }
        return wc.canClose() ? .terminateNow : .terminateCancel
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if let wc = mainWindowController {
            wc.openFile(at: url)
        } else {
            pendingURLs.append(url)
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let wc = mainWindowController {
            for url in urls { wc.openFile(at: url) }
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}
