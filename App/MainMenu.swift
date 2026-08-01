import AppKit

class MainMenu {

    // MARK: - Public entry point

    static func setup() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        mainMenu.addItem(buildAppMenu())
        mainMenu.addItem(buildFileMenu())
        mainMenu.addItem(buildEditMenu())
        mainMenu.addItem(buildSearchMenu())
        mainMenu.addItem(buildViewMenu())
        mainMenu.addItem(buildBookmarksMenu())
        mainMenu.addItem(buildWindowMenu())
        mainMenu.addItem(buildHelpMenu())
    }

    // MARK: - App menu (TextEditor)

    private static func buildAppMenu() -> NSMenuItem {
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About TextEditor",
                         action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                         keyEquivalent: "")

        appMenu.addItem(.separator())

        // Services submenu
        let servicesMenu = NSMenu(title: "Services")
        NSApp.servicesMenu = servicesMenu
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide TextEditor",
                         action: #selector(NSApplication.hide(_:)),
                         keyEquivalent: "h")

        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others",
                                              action: #selector(NSApplication.hideOtherApplications(_:)),
                                              keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]

        appMenu.addItem(withTitle: "Show All",
                         action: #selector(NSApplication.unhideAllApplications(_:)),
                         keyEquivalent: "")

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Quit TextEditor",
                         action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")

        return appMenuItem
    }

    // MARK: - File menu

    private static func buildFileMenu() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        let menuItem = NSMenuItem()
        menuItem.submenu = menu

        menu.addItem(withTitle: "New",
                      action: #selector(EditorTabViewController.newDocument(_:)),
                      keyEquivalent: "n")

        menu.addItem(withTitle: "Open...",
                      action: #selector(EditorTabViewController.openDocument(_:)),
                      keyEquivalent: "o")

        // Open Recent submenu
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = RecentMenuDelegate.shared
        let recentItem = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu

        menu.addItem(withTitle: "Close Tab",
                      action: #selector(EditorTabViewController.closeTab(_:)),
                      keyEquivalent: "w")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Save",
                      action: #selector(EditorTabViewController.saveDocument(_:)),
                      keyEquivalent: "s")

        let saveAsItem = menu.addItem(withTitle: "Save As...",
                                       action: #selector(EditorTabViewController.saveDocumentAs(_:)),
                                       keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(withTitle: "Revert to Saved",
                      action: #selector(EditorTabViewController.revertToSaved(_:)),
                      keyEquivalent: "")

        menu.addItem(.separator())

        // Quit is on the app menu, but some users expect it here too on non-Mac-native ports.
        // Omit from File menu -- macOS convention places Quit only in the app menu.

        return menuItem
    }

    // MARK: - Edit menu

    private static func buildEditMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        let menuItem = NSMenuItem()
        menuItem.submenu = menu

        // Standard first-responder actions so NSTextView handles them automatically
        menu.addItem(withTitle: "Undo",
                      action: Selector(("undo:")),
                      keyEquivalent: "z")

        let redoItem = menu.addItem(withTitle: "Redo",
                                     action: Selector(("redo:")),
                                     keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut",
                      action: #selector(NSText.cut(_:)),
                      keyEquivalent: "x")

        menu.addItem(withTitle: "Copy",
                      action: #selector(NSText.copy(_:)),
                      keyEquivalent: "c")

        menu.addItem(withTitle: "Paste",
                      action: #selector(NSText.paste(_:)),
                      keyEquivalent: "v")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Select All",
                      action: #selector(NSText.selectAll(_:)),
                      keyEquivalent: "a")

        return menuItem
    }

    // MARK: - Search menu

    private static func buildSearchMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Search")
        let menuItem = NSMenuItem()
        menuItem.submenu = menu

        menu.addItem(withTitle: "Find...",
                      action: #selector(EditorTabViewController.showFindPanel(_:)),
                      keyEquivalent: "f")

        let replaceItem = menu.addItem(withTitle: "Replace...",
                                        action: #selector(EditorTabViewController.showReplacePanel(_:)),
                                        keyEquivalent: "f")
        replaceItem.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(withTitle: "Find Next",
                      action: #selector(EditorTabViewController.findNext(_:)),
                      keyEquivalent: "g")

        let findPrevItem = menu.addItem(withTitle: "Find Previous",
                                         action: #selector(EditorTabViewController.findPrevious(_:)),
                                         keyEquivalent: "G")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        let findInFilesItem = menu.addItem(withTitle: "Find in Files...",
                                            action: #selector(EditorTabViewController.showFindInFiles(_:)),
                                            keyEquivalent: "F")
        findInFilesItem.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        menu.addItem(withTitle: "Go to Line...",
                      action: #selector(EditorTabViewController.goToLine(_:)),
                      keyEquivalent: "l")

        return menuItem
    }

    // MARK: - View menu

    private static func buildViewMenu() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        let menuItem = NSMenuItem()
        menuItem.submenu = menu

        menu.addItem(withTitle: "Font...",
                      action: #selector(EditorTabViewController.showFontPanel(_:)),
                      keyEquivalent: "")

        menu.addItem(.separator())

        let wordWrapItem = menu.addItem(withTitle: "Word Wrap",
                                         action: #selector(EditorTabViewController.toggleWordWrap(_:)),
                                         keyEquivalent: "")
        wordWrapItem.state = .off

        return menuItem
    }

    // MARK: - Bookmarks menu

    private static func buildBookmarksMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Bookmarks")
        let menuItem = NSMenuItem()
        menuItem.submenu = menu

        let toggleItem = menu.addItem(withTitle: "Toggle Bookmark",
                                       action: #selector(EditorTabViewController.toggleBookmark(_:)),
                                       keyEquivalent: "")
        toggleItem.keyEquivalent = "\u{F705}" // F2
        toggleItem.keyEquivalentModifierMask = [.command]
        // Cmd+F2 for toggle

        menu.addItem(.separator())

        let nextItem = menu.addItem(withTitle: "Next Bookmark",
                                     action: #selector(EditorTabViewController.nextBookmark(_:)),
                                     keyEquivalent: "")
        nextItem.keyEquivalent = "\u{F705}" // F2
        nextItem.keyEquivalentModifierMask = []

        let prevItem = menu.addItem(withTitle: "Previous Bookmark",
                                     action: #selector(EditorTabViewController.previousBookmark(_:)),
                                     keyEquivalent: "")
        prevItem.keyEquivalent = "\u{F705}" // F2
        prevItem.keyEquivalentModifierMask = [.shift]

        menu.addItem(.separator())

        menu.addItem(withTitle: "Clear All Bookmarks",
                      action: #selector(EditorTabViewController.clearAllBookmarks(_:)),
                      keyEquivalent: "")

        return menuItem
    }

    // MARK: - Window menu

    private static func buildWindowMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        let menuItem = NSMenuItem()
        menuItem.submenu = menu
        NSApp.windowsMenu = menu

        menu.addItem(withTitle: "Minimize",
                      action: #selector(NSWindow.performMiniaturize(_:)),
                      keyEquivalent: "m")

        menu.addItem(withTitle: "Zoom",
                      action: #selector(NSWindow.performZoom(_:)),
                      keyEquivalent: "")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Bring All to Front",
                      action: #selector(NSApplication.arrangeInFront(_:)),
                      keyEquivalent: "")

        return menuItem
    }

    // MARK: - Recent menu delegate

    /// Populates the "Open Recent" submenu dynamically from NSDocumentController.
    private class RecentMenuDelegate: NSObject, NSMenuDelegate {
        static let shared = RecentMenuDelegate()

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()

            let recentPaths = PersistenceService.shared.loadRecentFiles()
            if recentPaths.isEmpty {
                let noItems = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
                noItems.isEnabled = false
                menu.addItem(noItems)
            } else {
                for path in recentPaths {
                    let url = URL(fileURLWithPath: path)
                    let item = NSMenuItem(title: url.lastPathComponent,
                                          action: #selector(openRecentFile(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = url
                    item.toolTip = path
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
            let clearItem = menu.addItem(withTitle: "Clear Menu",
                                         action: #selector(clearRecentFiles(_:)),
                                         keyEquivalent: "")
            // Without an explicit target the action is resolved via the
            // responder chain, which never reaches this delegate — the item
            // would stay permanently disabled.
            clearItem.target = self
        }

        @objc private func clearRecentFiles(_ sender: Any?) {
            PersistenceService.shared.saveRecentFiles([])
            NSDocumentController.shared.clearRecentDocuments(sender)
        }

        @objc private func openRecentFile(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            (NSApp.delegate as? AppDelegate)?.mainWindowController?.openFile(at: url)
        }
    }

    // MARK: - Help menu

    private static func buildHelpMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        let menuItem = NSMenuItem()
        menuItem.submenu = menu
        NSApp.helpMenu = menu

        // macOS provides a standard search field in the Help menu automatically
        // when you set NSApp.helpMenu.

        return menuItem
    }
}
