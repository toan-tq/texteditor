import AppKit

class MainWindowController: NSWindowController {
    let editorTabVC = EditorTabViewController()

    convenience init() {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.85
        let maxH = screen.height * 0.85
        var w = maxW
        var h = w * 9.0 / 16.0
        if h > maxH {
            h = maxH
            w = h * 16.0 / 9.0
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Text Editor"
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
        window.contentViewController = editorTabVC

        editorTabVC.windowController = self
    }

    /// Set to `true` after the user has already confirmed discard via windowShouldClose,
    /// so applicationShouldTerminate doesn't show the same dialog again.
    var closingConfirmed = false

    func canClose() -> Bool {
        guard editorTabVC.confirmDiscardAll() else { return false }
        closingConfirmed = true
        CrashRecoveryService.shared.stop()
        CrashRecoveryService.shared.cleanupBackups()
        return true
    }

    func openFile(at url: URL) {
        editorTabVC.openOrFocusTab(url: url)
    }

    func updateTitle() {
        guard let doc = editorTabVC.activeDocument else {
            window?.title = "Text Editor"
            window?.isDocumentEdited = false
            return
        }
        window?.title = doc.displayName + " \u{2014} Text Editor"
        window?.isDocumentEdited = doc.isDirty

        // Set represented URL so macOS shows proxy icon + path in title bar
        if let url = doc.fileURL {
            window?.representedURL = url
        } else {
            window?.representedURL = nil
        }
    }

    func startCrashRecovery() {
        if let restored = CrashRecoveryService.shared.restoreBackups() {
            for (filePath, content) in restored {
                let url = filePath.map { URL(fileURLWithPath: $0) }
                editorTabVC.restoreTab(content: content, originalURL: url)
            }
        }
        CrashRecoveryService.shared.start { [weak self] in
            // Runs on main thread (Timer fires on main runloop). Capture every
            // mutable TabDocument field into an immutable snapshot so the
            // background writer never reads them concurrently with edits.
            guard let self = self else { return [] }
            return self.editorTabVC.tabs.map { tab in
                CrashRecoveryService.TabSnapshot(
                    identity: ObjectIdentifier(tab.document),
                    filePath: tab.document.fileURL?.path,
                    content: tab.editorView.string,
                    isDirty: tab.document.isDirty
                )
            }
        }
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closingConfirmed = false
        return canClose()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        updateTitle()
    }
}
