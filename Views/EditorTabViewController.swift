import AppKit

class EditorTabViewController: NSViewController, TabBarViewDelegate, DirSearchResultsDelegate, NSMenuItemValidation, FindPanelDelegate, FindInFilesDelegate {

    // MARK: - UI components

    private let splitView = NSSplitView()
    private let tabBar = TabBarView()
    private let editorContainer = NSView()
    private let statusBar = StatusBarView()
    let dirResultsView = DirSearchResultsView()
    private let topPane = NSView()
    /// One banner shared by every tab — it only ever describes the active
    /// document, and the pending state itself lives on `TabDocument`.
    private let changeBanner = FileChangeBanner()

    // MARK: - Tab state

    private(set) var tabs: [(document: TabDocument, scrollView: NSScrollView, editorView: EditorView, syntaxHighlighter: SyntaxHighlighter)] = []
    private(set) var activeIndex: Int = -1

    weak var windowController: MainWindowController?

    // MARK: - Find/Replace state

    private var findPanelController: FindPanelController?
    private var findMatches: [(location: Int, length: Int)] = []
    private var findMatchIndex: Int = -1
    private var lastFindNeedle: String = ""
    private var lastFindOptions: FindOptions = FindOptions()
    private var findUpdateWorkItem: DispatchWorkItem?
    /// Incremental-scan state: the scan resumes from `findScanCursor` each
    /// runloop turn, and `findScanGeneration` retires the chunks of a scan that
    /// a newer needle or an edit has invalidated.
    private var findScanCursor = 0
    private var findScanGeneration = 0
    private var findScanActive = false
    private var findLimitReached = false
    private var findScrollObserver: Any?
    /// The character range the last highlight pass painted, so the next one can
    /// clear exactly that instead of the whole document.
    private var findHighlightedRange: NSRange?
    /// The current match is painted even when it is off screen, so it is tracked
    /// on its own. Folding it into `findHighlightedRange` would stretch that hull
    /// from the match to the viewport — scroll far enough on a big document and
    /// clearing it costs as much as clearing everything.
    private var findCurrentHighlightedRange: NSRange?

    // MARK: - Find in Files state

    private var findInFilesController: FindInFilesController?
    /// Cancellation token for the run currently feeding the results pane.
    private var dirSearch: FileSearchService.Handle?
    /// Bumped per run so a late callback from a superseded search can't write
    /// to the pane — including hiding the Stop button of the run that replaced it.
    private var dirSearchGeneration = 0
    private var dirHistory: [String] = PersistenceService.shared.loadDirHistory()

    // MARK: - Convenience accessors

    var activeDocument: TabDocument? {
        guard tabs.indices.contains(activeIndex) else { return nil }
        return tabs[activeIndex].document
    }

    var activeEditor: EditorView? {
        guard tabs.indices.contains(activeIndex) else { return nil }
        return tabs[activeIndex].editorView
    }

    // MARK: - Lifecycle

    override func loadView() {
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view = mainView

        // Top pane: tabBar + editorContainer + statusBar
        topPane.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        tabBar.delegate = self

        topPane.addSubview(tabBar)
        topPane.addSubview(editorContainer)
        topPane.addSubview(statusBar)

        // Pinned to the top of the editor area with a zero height when idle,
        // so the editor below it needs no separate layout for the two states.
        changeBanner.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(changeBanner)
        NSLayoutConstraint.activate([
            changeBanner.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            changeBanner.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            changeBanner.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
        ])

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),

            editorContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: topPane.bottomAnchor),
        ])

        // SplitView: top pane + dir results (collapsed by default)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self

        splitView.addArrangedSubview(topPane)
        splitView.addArrangedSubview(dirResultsView)
        dirResultsView.isHidden = true
        dirResultsView.delegate = self
        dirResultsView.onCloseRequested = { [weak self] in
            self?.hideDirResults()
        }

        mainView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: mainView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(self,
                                                selector: #selector(editorDidChange(_:)),
                                                name: .editorDidChange,
                                                object: nil)

        startWatchingForExternalChanges()

        createNewTab()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        windowController?.updateTitle()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Block-based observers aren't covered by removeObserver(self).
        endFindHighlightObservation()
    }

    // MARK: - Disambiguating tab titles

    /// When multiple tabs share the same file name, prefix with parent directory to disambiguate.
    private func updateAllTabTitles() {
        // Count how many tabs share each base filename
        var nameCounts: [String: Int] = [:]
        for tab in tabs {
            let name = tab.document.displayName
            nameCounts[name, default: 0] += 1
        }

        for (i, tab) in tabs.enumerated() {
            let doc = tab.document
            let baseName = doc.displayName
            var title = baseName
            if nameCounts[baseName, default: 0] > 1, let url = doc.fileURL {
                let parentDir = url.deletingLastPathComponent().lastPathComponent
                title = "\(parentDir)/\(baseName)"
            }
            tabBar.updateTab(at: i,
                             tab: TabBarView.Tab(title: title, isDirty: doc.isDirty, tooltip: doc.tooltipText))
        }
    }

    // MARK: - Tab creation

    func createNewTab(fileURL: URL? = nil, onLoaded: (() -> Void)? = nil) {
        let doc = TabDocument()
        let (scrollView, editorView) = makeEditorScrollView()
        let highlighter = SyntaxHighlighter()
        highlighter.tabDocument = doc
        editorView.textStorage?.delegate = highlighter

        editorView.tabDocument = doc
        editorView.statusUpdateDelegate = statusBar

        if let url = fileURL {
            loadFile(into: doc, editorView: editorView, syntaxHighlighter: highlighter, url: url, completion: onLoaded)
        } else {
            onLoaded?()
        }

        tabs.append((document: doc, scrollView: scrollView, editorView: editorView, syntaxHighlighter: highlighter))

        tabBar.addTab(TabBarView.Tab(title: doc.displayName, isDirty: false, tooltip: doc.tooltipText))
        activateTab(at: tabs.count - 1)
        updateAllTabTitles()

        if let url = fileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            PersistenceService.shared.addRecentFile(url.path)
        }
    }

    // MARK: - Tab restoration (crash recovery)

    func restoreTab(content: String, originalURL: URL?) {
        let doc = TabDocument()
        setFileURL(originalURL, on: doc)
        if let url = originalURL {
            doc.language = SyntaxLanguage.detect(fileName: url.lastPathComponent)
        }

        let (scrollView, editorView) = makeEditorScrollView()
        let highlighter = SyntaxHighlighter()
        highlighter.tabDocument = doc
        editorView.textStorage?.delegate = highlighter
        editorView.tabDocument = doc
        editorView.statusUpdateDelegate = statusBar
        editorView.string = content  // delegate rebuilds the line index + syntax caches

        if let url = originalURL, FileManager.default.fileExists(atPath: url.path) {
            // Use FileService.readFile so we get the same LF normalization +
            // line-ending detection as a fresh open. Otherwise a CRLF file's
            // raw disk content wouldn't match the LF-normalized backup, and
            // we'd false-positive as dirty.
            if let result = try? FileService.shared.readFile(at: url) {
                doc.savedContent = result.content
                doc.lineEnding = result.lineEnding
                doc.encoding = result.encoding
                doc.hasBOM = result.hasBOM
                doc.diskState = result.diskState
                doc.isDirty = (content != result.content)
            } else {
                doc.savedContent = ""
                doc.isDirty = true
            }
        } else {
            doc.savedContent = ""
            doc.isDirty = !content.isEmpty
        }

        tabs.append((document: doc, scrollView: scrollView, editorView: editorView, syntaxHighlighter: highlighter))
        tabBar.addTab(TabBarView.Tab(title: doc.displayName, isDirty: doc.isDirty, tooltip: doc.tooltipText))
        activateTab(at: tabs.count - 1)
        updateAllTabTitles()
    }

    // MARK: - Tab closing

    /// Removes a single tab at `index` without adjusting active tab or tab bar selection.
    /// Returns `true` if the tab was actually removed, `false` if the user cancelled
    /// or the index is out of bounds (e.g. stale context-menu tag after tabs changed).
    private func removeSingleTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        let doc = tabs[index].document
        if doc.isDirty && !confirmDiscard(for: doc) { return false }
        if let url = doc.fileURL { FileWatchService.shared.unwatch(url) }
        let sv = tabs[index].scrollView
        if sv.superview == editorContainer { sv.removeFromSuperview() }
        tabs.remove(at: index)
        tabBar.removeTab(at: index)
        return true
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard removeSingleTab(at: index) else { return }

        if tabs.isEmpty {
            activeIndex = -1
            createNewTab()
        } else {
            activateTab(at: min(tabBar.selectedIndex, tabs.count - 1))
        }
        updateAllTabTitles()
        windowController?.updateTitle()
    }

    func closeCurrentTab() {
        guard activeIndex >= 0 else { return }
        closeTab(at: activeIndex)
    }

    func closeTabsToLeft(of index: Int) {
        for i in stride(from: index - 1, through: 0, by: -1) {
            _ = removeSingleTab(at: i)
        }
        activateTab(at: tabBar.selectedIndex)
        updateAllTabTitles()
        windowController?.updateTitle()
    }

    func closeTabsToRight(of index: Int) {
        for i in stride(from: tabs.count - 1, through: index + 1, by: -1) {
            _ = removeSingleTab(at: i)
        }
        activateTab(at: tabBar.selectedIndex)
        updateAllTabTitles()
        windowController?.updateTitle()
    }

    func closeAllTabs() {
        guard confirmDiscardAll() else { return }
        // All dirty tabs handled — force-close everything
        for i in stride(from: tabs.count - 1, through: 0, by: -1) {
            if let url = tabs[i].document.fileURL { FileWatchService.shared.unwatch(url) }
            let sv = tabs[i].scrollView
            if sv.superview == editorContainer { sv.removeFromSuperview() }
            tabs.remove(at: i)
            tabBar.removeTab(at: i)
        }
        activeIndex = -1
        createNewTab()
        windowController?.updateTitle()
    }

    func confirmDiscardAll() -> Bool {
        let dirtyDocs = tabs.filter { $0.document.isDirty }
        guard !dirtyDocs.isEmpty else { return true }

        if dirtyDocs.count == 1 {
            return confirmDiscard(for: dirtyDocs[0].document)
        }

        // Multiple dirty files — ask once with Save All / Don't Save / Cancel
        let alert = NSAlert()
        alert.messageText = "You have \(dirtyDocs.count) unsaved documents."
        alert.informativeText = "Do you want to save all changes before closing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for tab in dirtyDocs {
                if !saveDocumentInternal(tab.document) { return false }
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func confirmDiscard(for doc: TabDocument) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to \"\(doc.displayName)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveDocumentInternal(doc)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: - Tab activation

    func activateTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }

        // Match offsets belong to the document they were found in. Drop them
        // (and the highlights they painted) before the editor underneath changes.
        if activeIndex != index {
            cancelFindScan()
            clearFindHighlights()
            findMatches.removeAll()
            findMatchIndex = -1
        }

        if activeIndex >= 0, tabs.indices.contains(activeIndex) {
            let currentSV = tabs[activeIndex].scrollView
            if currentSV.superview == editorContainer { currentSV.removeFromSuperview() }
        }

        activeIndex = index
        tabBar.selectTab(at: index)

        let scrollView = tabs[index].scrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: changeBanner.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
        ])

        view.window?.makeFirstResponder(tabs[index].editorView)
        statusBar.updateFromTextView(tabs[index].editorView)
        updateChangeBanner()
        windowController?.updateTitle()

        // Re-run the open search against the document that just became active.
        if let panel = findPanelController, panel.window?.isVisible == true, !panel.findText.isEmpty {
            runFind(needle: panel.findText, options: panel.currentOptions)
        }
    }

    // MARK: - Open or focus existing tab

    func openOrFocusTab(url: URL, onLoaded: (() -> Void)? = nil) {
        for (i, tab) in tabs.enumerated() {
            if tab.document.fileURL == url {
                activateTab(at: i)
                onLoaded?()
                return
            }
        }

        // Reuse current tab if it's empty untitled
        if let doc = activeDocument, doc.fileURL == nil, !doc.isDirty,
           activeEditor?.string.isEmpty == true {
            loadFile(into: tabs[activeIndex].document, editorView: tabs[activeIndex].editorView,
                     syntaxHighlighter: tabs[activeIndex].syntaxHighlighter, url: url, completion: onLoaded)
            updateAllTabTitles()
            windowController?.updateTitle()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            PersistenceService.shared.addRecentFile(url.path)
            return
        }

        createNewTab(fileURL: url, onLoaded: onLoaded)
    }

    // MARK: - File loading

    private func loadFile(into doc: TabDocument, editorView: EditorView, syntaxHighlighter: SyntaxHighlighter, url: URL, completion: (() -> Void)? = nil) {
        setFileURL(url, on: doc)
        doc.language = SyntaxLanguage.detect(fileName: url.lastPathComponent)

        // Read file off main thread to avoid blocking UI on large files
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try FileService.shared.readFile(at: url)
                DispatchQueue.main.async {
                    doc.savedContent = result.content
                    doc.lineEnding = result.lineEnding
                    doc.encoding = result.encoding
                    doc.hasBOM = result.hasBOM
                    doc.diskState = result.diskState
                    doc.isDirty = false
                    doc.externalChange = nil
                    doc.acknowledgedChange = nil

                    // Assigning `string` edits the text storage, so the
                    // highlighter's delegate rebuilds the line index and the
                    // syntax caches from the new content. Building them *before*
                    // this line meant the delegate spliced on top of an index it
                    // had already rebuilt, doubling the line count.
                    editorView.string = result.content
                    editorView.applyEditorFont(AppTheme.monoFont)
                    editorView.textColor = NSColor.black
                    editorView.setSelectedRange(NSRange(location: 0, length: 0))
                    editorView.scrollToBeginningOfDocument(nil)

                    if let ts = editorView.textStorage {
                        syntaxHighlighter.highlightAll(in: ts)
                    }
                    self?.updateChangeBanner()
                    completion?()
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Failed to open file"
                    alert.runModal()
                    completion?()
                }
            }
        }
    }

    // MARK: - File saving

    @discardableResult
    private func saveDocumentInternal(_ doc: TabDocument) -> Bool {
        if let url = doc.fileURL {
            return writeFile(doc: doc, to: url)
        } else {
            return saveDocumentAsInternal(doc)
        }
    }

    @discardableResult
    private func saveDocumentAsInternal(_ doc: TabDocument) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = doc.displayName
        if let url = doc.fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writeFile(doc: doc, to: url)
    }

    private func writeFile(doc: TabDocument, to url: URL) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.document === doc }) else { return false }
        guard confirmOverwriteIfChangedOnDisk(doc, at: url) else { return false }

        let content = tabs[index].editorView.string
        do {
            doc.diskState = try FileService.shared.saveFile(
                content: content, to: url,
                lineEnding: doc.lineEnding,
                encoding: doc.encoding,
                hasBOM: doc.hasBOM)
            setFileURL(url, on: doc)
            doc.savedContent = content
            doc.isDirty = false
            // Whatever the file looked like before, this tab is now what it
            // holds — the save just resolved the conflict.
            doc.externalChange = nil
            doc.acknowledgedChange = nil
            let language = SyntaxLanguage.detect(fileName: url.lastPathComponent)
            if language != doc.language {
                // Save As can change the language. Marking dirty only queues the
                // multi-line rescan; nothing repaints until the next keystroke,
                // so the colours would stay those of the old language.
                doc.language = language
                doc.markSyntaxDirtyAll()
                if let textStorage = tabs[index].editorView.textStorage {
                    tabs[index].syntaxHighlighter.highlightAll(in: textStorage)
                }
            }

            tabBar.updateTab(at: index,
                             tab: TabBarView.Tab(title: doc.displayName, isDirty: false, tooltip: doc.tooltipText))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            PersistenceService.shared.addRecentFile(url.path)
            updateChangeBanner()
            windowController?.updateTitle()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Failed to save file"
            alert.runModal()
            return false
        }
    }

    /// Guards against dropping another program's edits on the floor. If the
    /// file no longer matches what we last read or wrote, the user decides
    /// whether their buffer still wins. Returns `true` if the save may go
    /// ahead.
    ///
    /// Only applies when overwriting the file this tab came from — Save As to
    /// some other path is already gated by the save panel's own overwrite
    /// prompt.
    private func confirmOverwriteIfChangedOnDisk(_ doc: TabDocument, at url: URL) -> Bool {
        guard url == doc.fileURL,
              let known = doc.diskState,
              let current = FileService.diskState(of: url),
              current != known else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(url.lastPathComponent)” has changed on disk"
        alert.informativeText = "Another program modified this file after you opened it. "
            + "Saving replaces those changes with the version in this tab."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - External change detection

    /// Keeps the watch set in step with `doc.fileURL`. Every assignment to
    /// that property goes through here, so no tab can end up pointing at a
    /// file nobody is watching.
    private func setFileURL(_ url: URL?, on doc: TabDocument) {
        let previous = doc.fileURL
        guard previous != url else { return }
        doc.fileURL = url
        if let previous = previous { FileWatchService.shared.unwatch(previous) }
        if let url = url { FileWatchService.shared.watch(url) }
    }

    private func startWatchingForExternalChanges() {
        FileWatchService.shared.setOnChange { [weak self] path in
            self?.checkForExternalChanges(paths: [path])
        }

        // The watcher is the fast path, not the only one: kqueue is unreliable
        // on network volumes, and an atomic replace leaves a short window where
        // nothing is watching the path. A sweep whenever the app comes forward
        // costs one stat per tab and covers both.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        FileWatchService.shared.rearmLostWatches()
        checkForExternalChanges()
    }

    /// Re-stats the files behind open tabs and acts on whatever no longer
    /// matches what was last read or written. `paths` limits the sweep to the
    /// canonical paths a watcher reported; `nil` checks every tab.
    ///
    /// A watcher event is a hint, never a verdict — the editor's own saves
    /// raise events too, and they compare equal here because saving records
    /// the new disk state.
    private func checkForExternalChanges(paths: Set<String>? = nil) {
        for index in tabs.indices {
            let doc = tabs[index].document
            guard let url = doc.fileURL, let known = doc.diskState else { continue }
            if let paths = paths, !paths.contains(FileSearchService.canonicalPath(url)) { continue }

            guard let current = FileService.diskState(of: url) else {
                // Gone. The buffer is now the only copy of this file, so it is
                // marked unsaved rather than emptied, and never auto-anything.
                if doc.externalChange != .deleted, doc.acknowledgedChange != .missing {
                    doc.externalChange = .deleted
                    doc.isDirty = true
                    // The editor recomputes dirty on every keystroke by
                    // comparing against savedContent. Left alone, a stray
                    // keystroke and an undo would clear the marker and the tab
                    // would close without a prompt — losing the only copy.
                    // `restoreTab` clears it for the same reason.
                    doc.savedContent = ""
                    tabBar.updateTab(at: index,
                                     tab: TabBarView.Tab(title: doc.displayName,
                                                         isDirty: true,
                                                         tooltip: doc.tooltipText))
                }
                continue
            }

            if current == known {
                // Deleted and put back byte for byte (a checkout that came back
                // around) — nothing left to tell the user about.
                if doc.externalChange == .deleted { doc.externalChange = nil }
                doc.acknowledgedChange = nil
                continue
            }

            if doc.isDirty {
                // Silent if this is the same change the user already dismissed.
                // A *further* change gets a fresh banner.
                if doc.acknowledgedChange != .state(current) {
                    doc.externalChange = .modified
                }
            } else {
                // Only the tab being looked at says so; a branch switch can
                // reload twenty tabs and twenty notices would be noise.
                reloadFromDisk(index: index, announce: index == activeIndex)
            }
        }
        updateChangeBanner()
        windowController?.updateTitle()
    }

    // MARK: - Reloading from disk

    /// Where the caret and the viewport were, in terms that survive the file
    /// changing underneath them. Absolute offsets would not: text inserted
    /// above moves everything below it.
    private struct EditorPosition {
        let line: Int
        let column: Int
        let topLine: Int
    }

    private func capturePosition(index: Int) -> EditorPosition {
        let editor = tabs[index].editorView
        let doc = tabs[index].document
        let length = (editor.string as NSString).length

        let caret = min(editor.selectedRange().location, length)
        let line = doc.lineIndex(forCharOffset: caret)
        let lineStart = doc.lineStartOffsets.indices.contains(line) ? doc.lineStartOffsets[line] : 0

        var topLine = line
        if let layoutManager = editor.layoutManager, let container = editor.textContainer {
            let visible = visibleCharacterRange(of: editor,
                                                layoutManager: layoutManager,
                                                container: container)
            topLine = doc.lineIndex(forCharOffset: min(visible.location, length))
        }

        return EditorPosition(line: line, column: caret - lineStart, topLine: topLine)
    }

    /// Puts the caret back on the same line and column, and the same line back
    /// at the top of the viewport, both clamped to a file that may now be
    /// shorter.
    private func restorePosition(_ position: EditorPosition, index: Int) {
        let editor = tabs[index].editorView
        let doc = tabs[index].document
        let starts = doc.lineStartOffsets
        guard !starts.isEmpty else { return }
        let length = (editor.string as NSString).length

        let line = min(position.line, starts.count - 1)
        let lineEnd = line + 1 < starts.count ? starts[line + 1] - 1 : length
        let caret = min(starts[line] + position.column, max(starts[line], lineEnd))
        editor.setSelectedRange(NSRange(location: min(caret, length), length: 0))

        let topLine = min(position.topLine, starts.count - 1)
        guard let layoutManager = editor.layoutManager, let container = editor.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: starts[topLine], length: 0),
            actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)

        // Scrolled directly rather than via scrollRangeToVisible, which would
        // only guarantee the line is somewhere on screen — the point is to put
        // it back exactly where it was. Clamped because the file may have lost
        // enough lines that the old top is now past the end.
        //
        // Horizontally it goes home, to the start of the line. That is *not*
        // x = 0: the line-number ruler makes the clip view's resting origin
        // negative (-42 with the default gutter), so hard-coding zero scrolls
        // the text left by the width of the gutter and eats the first few
        // characters of every line. `constrainBoundsRect` is what knows where
        // the real left edge is, so ask for far-left and let it clamp.
        let clipView = tabs[index].scrollView.contentView
        let maxY = max(0, editor.frame.height - clipView.bounds.height)
        let y = min(max(0, rect.origin.y + editor.textContainerOrigin.y), maxY)
        let home = clipView.constrainBoundsRect(
            NSRect(origin: NSPoint(x: -100_000, y: y), size: clipView.bounds.size))
        clipView.scroll(to: NSPoint(x: home.origin.x, y: y))
        tabs[index].scrollView.reflectScrolledClipView(clipView)
    }

    /// Re-reads the file behind `index` and puts the buffer back where it was.
    ///
    /// The undo stack is dropped: what it would restore is a version of the
    /// document that exists neither on disk nor in the buffer, and stepping
    /// back into it would silently make the tab dirty against a file the user
    /// never edited.
    private func reloadFromDisk(index: Int, announce: Bool) {
        guard tabs.indices.contains(index) else { return }
        let doc = tabs[index].document
        guard let url = doc.fileURL else { return }
        let position = capturePosition(index: index)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? FileService.shared.readFile(at: url)
            DispatchQueue.main.async {
                guard let self = self, let result = result else { return }
                // Tabs can be closed or reordered while the read is in flight.
                guard let index = self.tabs.firstIndex(where: { $0.document === doc }) else { return }
                let editor = self.tabs[index].editorView

                // Set before the buffer: assigning `string` runs the editor's
                // dirty check against savedContent, and the old value would
                // make the freshly reloaded tab look edited.
                doc.savedContent = result.content
                doc.lineEnding = result.lineEnding
                doc.encoding = result.encoding
                doc.hasBOM = result.hasBOM
                doc.diskState = result.diskState
                doc.isDirty = false
                doc.externalChange = nil
                doc.acknowledgedChange = nil

                editor.string = result.content
                editor.applyEditorFont(AppTheme.monoFont)
                editor.textColor = NSColor.black
                editor.undoManager?.removeAllActions()

                if let ts = editor.textStorage {
                    self.tabs[index].syntaxHighlighter.highlightAll(in: ts)
                }
                // Bookmarks are line numbers, and the file may have lost lines.
                doc.bookmarks = doc.bookmarks.filter { $0 < doc.lineStartOffsets.count }

                self.restorePosition(position, index: index)
                self.updateAllTabTitles()
                self.updateChangeBanner()
                self.windowController?.updateTitle()

                if index == self.activeIndex {
                    self.statusBar.updateFromTextView(editor)
                    // Match offsets belong to the text that has just been
                    // replaced; re-run the search against what is there now.
                    if let panel = self.findPanelController,
                       panel.window?.isVisible == true, !panel.findText.isEmpty {
                        self.runFind(needle: panel.findText, options: panel.currentOptions)
                    } else {
                        self.clearFindHighlights()
                        self.findMatches.removeAll()
                        self.findMatchIndex = -1
                    }
                }
                if announce { self.statusBar.flash("Reloaded from disk") }
            }
        }
    }

    // MARK: - External change banner

    /// The banner always describes the active tab; the pending state itself
    /// lives on each document, so switching tabs just redraws.
    private func updateChangeBanner() {
        guard let doc = activeDocument, let change = doc.externalChange else {
            changeBanner.hide()
            return
        }

        switch change {
        case .modified:
            changeBanner.show(
                message: "“\(doc.displayName)” changed on disk. This tab has unsaved changes.",
                primary: ("Reload", { [weak self] in
                    // Looked up on click, not captured: tabs can be dragged
                    // into a different order while the banner is up.
                    guard let self = self,
                          let index = self.tabs.firstIndex(where: { $0.document === doc })
                    else { return }
                    self.reloadFromDisk(index: index, announce: true)
                }),
                secondary: ("Keep Mine", { [weak self] in
                    doc.externalChange = nil
                    if let url = doc.fileURL {
                        doc.acknowledgedChange = FileService.diskState(of: url).map { .state($0) }
                    }
                    self?.updateChangeBanner()
                }))
        case .deleted:
            changeBanner.show(
                message: "“\(doc.displayName)” no longer exists on disk.",
                primary: ("Save", { [weak self] in
                    guard let self = self else { return }
                    self.saveDocumentInternal(doc)
                    self.updateChangeBanner()
                }),
                secondary: ("Dismiss", { [weak self] in
                    doc.externalChange = nil
                    doc.acknowledgedChange = .missing
                    self?.updateChangeBanner()
                }))
        }
    }

    // MARK: - Make editor scroll view

    private func makeEditorScrollView() -> (NSScrollView, EditorView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // Find highlights only cover the viewport, so scrolling has to re-paint.
        scrollView.contentView.postsBoundsChangedNotifications = true

        let contentSize = scrollView.contentSize
        let editorView = EditorView(frame: NSRect(origin: .zero, size: contentSize))
        editorView.minSize = NSSize(width: 0, height: contentSize.height)
        editorView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editorView.isVerticallyResizable = true
        editorView.isHorizontallyResizable = false
        editorView.autoresizingMask = [.width]
        editorView.textContainer?.widthTracksTextView = true
        editorView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        editorView.isEditable = true
        editorView.isSelectable = true
        editorView.allowsUndo = true
        editorView.delegate = self

        scrollView.documentView = editorView

        // Line number ruler — only attaches if the editor's scroll view is set up.
        if let rulerView = LineNumberRulerView(textView: editorView) {
            scrollView.verticalRulerView = rulerView
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        return (scrollView, editorView)
    }

    // MARK: - Notifications

    @objc private func editorDidChange(_ notification: Notification) {
        guard let editor = notification.object as? EditorView else { return }
        guard let index = tabs.firstIndex(where: { $0.editorView === editor }) else { return }
        let doc = tabs[index].document
        tabBar.updateTab(at: index,
                         tab: TabBarView.Tab(title: doc.displayName, isDirty: doc.isDirty, tooltip: doc.tooltipText))
        windowController?.updateTitle()
    }

    // MARK: - Dir results

    func showDirResults() {
        dirResultsView.isHidden = false
        // Force frames directly
        let h = splitView.frame.height
        let topHeight = h * 0.65
        let bottomHeight = h * 0.35 - splitView.dividerThickness
        topPane.frame = NSRect(x: 0, y: bottomHeight + splitView.dividerThickness, width: splitView.frame.width, height: topHeight)
        dirResultsView.frame = NSRect(x: 0, y: 0, width: splitView.frame.width, height: bottomHeight)
        splitView.adjustSubviews()
    }

    func hideDirResults() {
        // Closing the pane always ends the run behind it — otherwise workers
        // keep churning through the tree with nowhere to put their results.
        dirSearch?.cancel()
        dirSearch = nil
        dirResultsView.setRunning(false)
        dirResultsView.isHidden = true
        topPane.frame = splitView.bounds
        splitView.adjustSubviews()
        activeEditor?.window?.makeFirstResponder(activeEditor)
    }

    // DirSearchResultsDelegate
    func dirSearchResults(_ view: DirSearchResultsView, didSelectResult result: DirSearchResult) {
        openOrFocusTab(url: result.fileURL) { [weak self] in
            self?.activeEditor?.scrollToLine(result.lineNumber)
        }
    }

    // MARK: - TabBarViewDelegate

    func tabBar(_ tabBar: TabBarView, didSelectTabAt index: Int) {
        activateTab(at: index)
    }

    func tabBar(_ tabBar: TabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabBar(_ tabBar: TabBarView, didMoveTabFrom fromIndex: Int, to toIndex: Int) {
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)
        activeIndex = toIndex
    }

    func tabBar(_ tabBar: TabBarView, contextMenuForTabAt index: Int) -> NSMenu? {
        let menu = NSMenu()

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextMenuClose(_:)), keyEquivalent: "")
        closeItem.tag = index
        closeItem.target = self
        menu.addItem(closeItem)

        menu.addItem(.separator())

        let closeLeftItem = NSMenuItem(title: "Close All to the Left", action: #selector(contextMenuCloseLeft(_:)), keyEquivalent: "")
        closeLeftItem.tag = index
        closeLeftItem.target = self
        closeLeftItem.isEnabled = index > 0
        menu.addItem(closeLeftItem)

        let closeRightItem = NSMenuItem(title: "Close All to the Right", action: #selector(contextMenuCloseRight(_:)), keyEquivalent: "")
        closeRightItem.tag = index
        closeRightItem.target = self
        closeRightItem.isEnabled = index < tabs.count - 1
        menu.addItem(closeRightItem)

        menu.addItem(.separator())

        let closeAllItem = NSMenuItem(title: "Close All", action: #selector(contextMenuCloseAll(_:)), keyEquivalent: "")
        closeAllItem.target = self
        menu.addItem(closeAllItem)

        if tabs[index].document.fileURL != nil {
            menu.addItem(.separator())

            let copyPathItem = NSMenuItem(title: "Copy Full Path", action: #selector(contextMenuCopyPath(_:)), keyEquivalent: "")
            copyPathItem.tag = index
            copyPathItem.target = self
            menu.addItem(copyPathItem)

            let copyNameItem = NSMenuItem(title: "Copy File Name", action: #selector(contextMenuCopyFileName(_:)), keyEquivalent: "")
            copyNameItem.tag = index
            copyNameItem.target = self
            menu.addItem(copyNameItem)

            menu.addItem(.separator())

            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextMenuRevealInFinder(_:)), keyEquivalent: "")
            revealItem.tag = index
            revealItem.target = self
            menu.addItem(revealItem)
        }

        return menu
    }

    @objc private func contextMenuClose(_ sender: NSMenuItem) { closeTab(at: sender.tag) }
    @objc private func contextMenuCloseLeft(_ sender: NSMenuItem) { closeTabsToLeft(of: sender.tag) }
    @objc private func contextMenuCloseRight(_ sender: NSMenuItem) { closeTabsToRight(of: sender.tag) }
    @objc private func contextMenuCloseAll(_ sender: NSMenuItem) { closeAllTabs() }
    @objc private func contextMenuCopyPath(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), let url = tabs[sender.tag].document.fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc private func contextMenuCopyFileName(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), let url = tabs[sender.tag].document.fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
    }
    @objc private func contextMenuRevealInFinder(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), let url = tabs[sender.tag].document.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Menu actions (responder chain)

    @objc func newDocument(_ sender: Any?) { createNewTab() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if !FileService.isBinaryFile(url) {
                openOrFocusTab(url: url)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        saveDocumentInternal(doc)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        saveDocumentAsInternal(doc)
    }

    @objc func closeTab(_ sender: Any?) { closeCurrentTab() }

    /// Throws the buffer away and re-reads the file. Clean tabs get this on
    /// their own when the file changes; this is the manual door for a tab with
    /// unsaved edits, so it asks first.
    @objc func revertToSaved(_ sender: Any?) {
        guard let doc = activeDocument, doc.fileURL != nil else { return }

        if doc.isDirty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Revert “\(doc.displayName)” to the version on disk?"
            alert.informativeText = "Your unsaved changes will be lost."
            alert.addButton(withTitle: "Revert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        reloadFromDisk(index: activeIndex, announce: true)
    }

    // MARK: - Search (custom Find/Replace panel)

    @objc func showFindPanel(_ sender: Any?) {
        guard activeEditor != nil else { return }
        presentFindPanel(withReplace: false)
    }

    @objc func showReplacePanel(_ sender: Any?) {
        guard activeEditor != nil else { return }
        presentFindPanel(withReplace: true)
    }

    @objc func findNext(_ sender: Any?) {
        guard activeEditor != nil else { return }
        if let panel = findPanelController, panel.window?.isVisible == true {
            let needle = panel.findText
            guard !needle.isEmpty else { return }
            advanceMatch(forward: true, needle: needle, options: panel.currentOptions)
        } else if !lastFindNeedle.isEmpty {
            advanceMatch(forward: true, needle: lastFindNeedle, options: lastFindOptions)
        }
    }

    @objc func findPrevious(_ sender: Any?) {
        guard activeEditor != nil else { return }
        if let panel = findPanelController, panel.window?.isVisible == true {
            let needle = panel.findText
            guard !needle.isEmpty else { return }
            advanceMatch(forward: false, needle: needle, options: panel.currentOptions)
        } else if !lastFindNeedle.isEmpty {
            advanceMatch(forward: false, needle: lastFindNeedle, options: lastFindOptions)
        }
    }

    private func presentFindPanel(withReplace: Bool) {
        if let existing = findPanelController, let win = existing.window, win.isVisible {
            existing.setReplaceVisible(withReplace)
            if let sel = activeEditor?.selectedText(), !sel.contains("\n") {
                existing.prefillWithSelection(sel)
            }
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = FindPanelController(withReplace: withReplace)
        panel.delegate = self
        findPanelController = panel

        if let sel = activeEditor?.selectedText(), !sel.contains("\n") {
            panel.prefillWithSelection(sel)
        }

        if let parentWin = view.window {
            panel.showPanel(relativeTo: parentWin)
        } else {
            panel.showWindow(nil)
        }
    }

    // MARK: - FindPanelDelegate

    func findPanel(_ panel: FindPanelController, findNext needle: String, options: FindOptions) {
        advanceMatch(forward: true, needle: needle, options: options)
    }

    func findPanel(_ panel: FindPanelController, findPrev needle: String, options: FindOptions) {
        advanceMatch(forward: false, needle: needle, options: options)
    }

    func findPanel(_ panel: FindPanelController, replace needle: String, with replacement: String, options: FindOptions) {
        doReplace(needle: needle, replacement: replacement, options: options)
    }

    func findPanel(_ panel: FindPanelController, replaceAll needle: String, with replacement: String, options: FindOptions) {
        doReplaceAll(needle: needle, replacement: replacement, options: options)
    }

    func findPanelDidClose(_ panel: FindPanelController) {
        // Cancel the editor-typing debounce; if it fired after this cleanup
        // it would re-apply highlights with the panel already closed.
        findUpdateWorkItem?.cancel()
        findUpdateWorkItem = nil
        cancelFindScan()
        endFindHighlightObservation()
        clearFindHighlights()
        findMatches.removeAll()
        findMatchIndex = -1
        panel.updateMatchCount("")
    }

    func findPanel(_ panel: FindPanelController, searchTextChanged needle: String, options: FindOptions) {
        runFind(needle: needle, options: options) { [weak self] in
            guard let self = self, !self.findMatches.isEmpty else { return }
            self.jumpToNearestMatch()
            self.goToMatch()
        }
    }

    // MARK: - Find engine

    // Both halves of the old one-shot path were measured on a 50MB document
    // holding ~960k matches: scanning it took 377ms and applying one temporary
    // attribute per match took 1.56s — and the whole thing ran twice per
    // keystroke. Scanning is now spread across runloop turns and highlighting
    // is limited to what is actually on screen.
    private static let findScanBudget: TimeInterval = 0.02
    private static let findMatchLimit = 200_000
    private static let findScanCheckStride = 256
    /// Upper bound on one literal `range(of:)` call, in UTF-16 units, so a
    /// needle with no match left in the document still yields the runloop.
    private static let findScanWindow = 1 << 20

    /// Restarts the incremental scan. `completion` runs once the whole document
    /// has been scanned — never for an empty needle or an invalid pattern, and
    /// never for a scan that a newer one superseded.
    private func runFind(needle: String, options: FindOptions, completion: (() -> Void)? = nil) {
        guard activeEditor != nil else { return }

        lastFindNeedle = needle
        lastFindOptions = options
        cancelFindScan()
        beginFindHighlightObservation()
        findMatches.removeAll(keepingCapacity: true)
        findMatchIndex = -1
        findLimitReached = false
        clearFindHighlights()

        guard !needle.isEmpty else {
            findPanelController?.updateMatchCount("")
            return
        }
        if options.useRegex, findRegex(needle: needle, options: options) == nil {
            findPanelController?.updateMatchCount("Invalid regex")
            return
        }

        findScanCursor = 0
        findScanActive = true
        scanFindChunk(generation: findScanGeneration, completion: completion)
    }

    /// Invalidates the scan in flight: the next chunk sees a stale generation
    /// and drops itself. Called whenever the document or the needle changes.
    private func cancelFindScan() {
        findScanGeneration += 1
        findScanActive = false
    }

    private func findRegex(needle: String, options: FindOptions) -> NSRegularExpression? {
        var regexOptions: NSRegularExpression.Options = []
        if !options.matchCase { regexOptions.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: needle, options: regexOptions)
    }

    /// Scans for at most `findScanBudget` seconds, then hands the runloop back
    /// and resumes in the next turn so typing stays responsive.
    ///
    /// The regex branch is the one exception: `enumerateMatches` only calls back
    /// on a match, so a pattern that matches nothing runs to the end of the
    /// document inside a single chunk. Splitting that into windows is not sound
    /// — a regex match has no bounded length, so any window edge could cut one
    /// in half — and the 300ms debounce hides it in practice.
    private func scanFindChunk(generation: Int, completion: (() -> Void)?) {
        guard generation == findScanGeneration, let editor = activeEditor else { return }

        let text = editor.string as NSString
        let length = text.length
        let options = lastFindOptions
        let needle = lastFindNeedle
        let deadline = Date().addingTimeInterval(Self.findScanBudget)
        var sinceCheck = 0
        var cursor = findScanCursor

        if options.useRegex, let regex = findRegex(needle: needle, options: options) {
            var interrupted = false
            // The search range starts mid-document whenever a chunk resumes, so
            // the default bounds semantics would be wrong there: `^` would match
            // at the resume point, and `\b`/lookbehind would be blind to the text
            // just before it. Transparent + non-anchoring bounds make a resumed
            // chunk see the same document a single pass from 0 would.
            regex.enumerateMatches(in: editor.string,
                                   options: [.withTransparentBounds, .withoutAnchoringBounds],
                                   range: NSRange(location: cursor, length: length - cursor)) { match, _, stop in
                // An empty match doesn't move the cursor, so pausing on one would
                // rescan the same spot forever — only real matches can interrupt.
                guard let found = match?.range, found.length > 0 else { return }
                cursor = NSMaxRange(found)
                if !options.wholeWord || self.isWholeWord(in: text, range: found) {
                    self.findMatches.append((location: found.location, length: found.length))
                }
                if self.findMatches.count >= Self.findMatchLimit {
                    self.findLimitReached = true
                    stop.pointee = true
                    interrupted = true
                    return
                }
                sinceCheck += 1
                if sinceCheck >= Self.findScanCheckStride {
                    sinceCheck = 0
                    if Date() >= deadline {
                        stop.pointee = true
                        interrupted = true
                    }
                }
            }
            if !interrupted { cursor = length }
        } else {
            var searchOptions: NSString.CompareOptions = []
            if !options.matchCase { searchOptions.insert(.caseInsensitive) }

            // A needle that isn't in the document produces no callbacks to check
            // the deadline in, and one `range(of:)` over the tail is a full O(n)
            // scan — the exact hitch this chunking exists to avoid. So each call
            // is bounded to a window, and the deadline is re-checked per window
            // as well as per match.
            //
            // On a miss the window holds no complete match, so re-scanning its
            // last `overlap` units can't produce a duplicate at any overlap size
            // — it only recovers a match that straddles the window edge. Sized
            // well past the needle because a case- or width-insensitive match
            // can be longer than the needle it matched (ß/SS, decomposed
            // diacritics); still negligible against a 1 MB window.
            let overlap = (needle as NSString).length * 4 + 4

            while cursor < length {
                let windowEnd = min(length, cursor + Self.findScanWindow)
                let found = text.range(of: needle, options: searchOptions,
                                       range: NSRange(location: cursor, length: windowEnd - cursor))
                if found.location == NSNotFound {
                    if windowEnd >= length { cursor = length; break }
                    cursor = max(windowEnd - overlap, cursor + 1)
                    if Date() >= deadline { break }
                    continue
                }
                if !options.wholeWord || isWholeWord(in: text, range: found) {
                    findMatches.append((location: found.location, length: found.length))
                }
                cursor = found.location + max(found.length, 1)
                if findMatches.count >= Self.findMatchLimit {
                    findLimitReached = true
                    break
                }
                sinceCheck += 1
                if sinceCheck >= Self.findScanCheckStride {
                    sinceCheck = 0
                    if Date() >= deadline { break }
                }
            }
        }

        findScanCursor = cursor
        applyFindHighlights()

        if cursor >= length || findLimitReached {
            findScanActive = false
            updateMatchCountLabel()
            completion?()
        } else {
            updateMatchCountLabel()
            DispatchQueue.main.async { [weak self] in
                self?.scanFindChunk(generation: generation, completion: completion)
            }
        }
    }

    /// One uncapped pass in a single call. Replace All must never work from the
    /// capped or still-growing list — it would rewrite part of the document and
    /// report the whole thing as done.
    private func collectAllMatches(needle: String, options: FindOptions) -> [(location: Int, length: Int)] {
        guard let editor = activeEditor, !needle.isEmpty else { return [] }
        let text = editor.string as NSString
        let length = text.length
        var results: [(location: Int, length: Int)] = []

        if options.useRegex {
            guard let regex = findRegex(needle: needle, options: options) else { return [] }
            regex.enumerateMatches(in: editor.string,
                                   range: NSRange(location: 0, length: length)) { match, _, _ in
                guard let found = match?.range, found.length > 0 else { return }
                if !options.wholeWord || self.isWholeWord(in: text, range: found) {
                    results.append((location: found.location, length: found.length))
                }
            }
        } else {
            var searchOptions: NSString.CompareOptions = []
            if !options.matchCase { searchOptions.insert(.caseInsensitive) }
            var cursor = 0
            while cursor < length {
                let found = text.range(of: needle, options: searchOptions,
                                       range: NSRange(location: cursor, length: length - cursor))
                if found.location == NSNotFound { break }
                if !options.wholeWord || isWholeWord(in: text, range: found) {
                    results.append((location: found.location, length: found.length))
                }
                cursor = found.location + max(found.length, 1)
            }
        }
        return results
    }

    private func updateMatchCountLabel() {
        guard let panel = findPanelController else { return }
        if findMatches.isEmpty {
            panel.updateMatchCount(findScanActive ? "Searching…" : "No matches")
        } else if findLimitReached {
            panel.updateMatchCount("\(findMatches.count)+ matches")
        } else if findScanActive {
            panel.updateMatchCount("\(findMatches.count) matches…")
        } else {
            panel.updateMatchCount("\(findMatches.count) matches")
        }
    }

    private func isWholeWord(in text: NSString, range: NSRange) -> Bool {
        text.isWholeWord(range: range)
    }

    private func advanceMatch(forward: Bool, needle: String, options: FindOptions) {
        // Re-run find if needle or options changed
        let needsRerun = needle != lastFindNeedle
            || options.matchCase != lastFindOptions.matchCase
            || options.wholeWord != lastFindOptions.wholeWord
            || options.useRegex != lastFindOptions.useRegex
            || findMatches.isEmpty
        if needsRerun {
            // After the first find, jump to the nearest match — deferred until
            // the scan finishes so "nearest" is measured against the whole
            // document, not just the part scanned so far.
            runFind(needle: needle, options: options) { [weak self] in
                guard let self = self, !self.findMatches.isEmpty else { return }
                self.jumpToNearestMatch()
                self.goToMatch()
            }
            return
        }

        if forward {
            findMatchIndex += 1
            if findMatchIndex >= findMatches.count {
                if options.wrapAround {
                    findMatchIndex = 0
                } else {
                    findMatchIndex = findMatches.count - 1
                    NSSound.beep()
                }
            }
        } else {
            findMatchIndex -= 1
            if findMatchIndex < 0 {
                if options.wrapAround {
                    findMatchIndex = findMatches.count - 1
                } else {
                    findMatchIndex = 0
                    NSSound.beep()
                }
            }
        }

        goToMatch()
    }

    private func jumpToNearestMatch() {
        guard let editor = activeEditor, !findMatches.isEmpty else { return }
        let caret = editor.selectedRange().location
        var bestIndex = 0
        var bestDist = Int.max
        for (i, m) in findMatches.enumerated() {
            let dist = abs(m.location - caret)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }
        findMatchIndex = bestIndex
    }

    private func goToMatch() {
        guard let editor = activeEditor,
              let layoutManager = editor.layoutManager,
              let textContainer = editor.textContainer,
              findMatches.indices.contains(findMatchIndex) else { return }

        let match = findMatches[findMatchIndex]
        let range = NSRange(location: match.location, length: match.length)
        let textLength = (editor.string as NSString).length
        guard NSMaxRange(range) <= textLength else { return }

        editor.setSelectedRange(range)

        // Scroll to center the match vertically
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let matchRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let matchY = matchRect.origin.y + editor.textContainerOrigin.y

        if let scrollView = editor.enclosingScrollView {
            let visibleHeight = scrollView.contentView.bounds.height
            let targetY = max(0, matchY - visibleHeight / 2)
            let clipBounds = scrollView.contentView.bounds
            scrollView.contentView.scroll(to: NSPoint(x: clipBounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        editor.showFindIndicator(for: range)

        applyFindHighlights()

        let total = findLimitReached ? "\(findMatches.count)+" : "\(findMatches.count)"
        findPanelController?.updateMatchCount("\(findMatchIndex + 1) of \(total)")
    }

    // MARK: - Find highlighting

    /// Highlights only the matches inside the visible rectangle, and re-runs on
    /// scroll. Painting every match cost 1.56s on a document with ~960k of them;
    /// a viewport never holds more than a screenful.
    ///
    /// The clearing side is scoped just as tightly. `removeTemporaryAttribute`
    /// over a whole laid-out 50MB document measured ~175ms — as a per-scroll-tick
    /// cost that is its own hang — so only the previously painted window and the
    /// current viewport get cleared.
    private func applyFindHighlights() {
        guard let editor = activeEditor,
              let layoutManager = editor.layoutManager,
              let container = editor.textContainer else { return }

        let length = (editor.string as NSString).length
        let visible = visibleCharacterRange(of: editor, layoutManager: layoutManager, container: container)

        clearPaintedHighlights(layoutManager: layoutManager, alsoClearing: visible, documentLength: length)
        guard !findMatches.isEmpty else { return }

        let visibleEnd = NSMaxRange(visible)
        var lowest = Int.max
        var highest = 0

        func paint(_ range: NSRange, _ color: NSColor) {
            guard range.location >= 0, NSMaxRange(range) <= length else { return }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            lowest = min(lowest, range.location)
            highest = max(highest, NSMaxRange(range))
        }

        var index = firstMatchIndex(endingAfter: visible.location)
        while index < findMatches.count, findMatches[index].location < visibleEnd {
            let match = findMatches[index]
            paint(NSRange(location: match.location, length: match.length), AppTheme.findHighlightBg)
            index += 1
        }

        findHighlightedRange = highest > lowest
            ? NSRange(location: lowest, length: highest - lowest)
            : nil

        // Painted last so it wins over the plain highlight, and tracked apart
        // from the viewport hull since it may sit anywhere in the document.
        if findMatches.indices.contains(findMatchIndex) {
            let current = findMatches[findMatchIndex]
            let range = NSRange(location: current.location, length: current.length)
            if range.location >= 0, NSMaxRange(range) <= length {
                layoutManager.addTemporaryAttribute(.backgroundColor,
                                                    value: AppTheme.findCurrentBg,
                                                    forCharacterRange: range)
                findCurrentHighlightedRange = range
            }
        }
    }

    private func visibleCharacterRange(of editor: EditorView,
                                       layoutManager: NSLayoutManager,
                                       container: NSTextContainer) -> NSRange {
        var rect = editor.visibleRect
        rect.origin.x -= editor.textContainerOrigin.x
        rect.origin.y -= editor.textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    /// Clears the window painted last time plus `alsoClearing` — an edit can
    /// shift text out from under the tracked range, and the viewport is the only
    /// place a leftover would be visible.
    private func clearPaintedHighlights(layoutManager: NSLayoutManager,
                                        alsoClearing extra: NSRange,
                                        documentLength: Int) {
        let document = NSRange(location: 0, length: documentLength)
        for range in [findHighlightedRange, findCurrentHighlightedRange, extra].compactMap({ $0 }) {
            let clamped = NSIntersectionRange(range, document)
            if clamped.length > 0 {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
            }
        }
        findHighlightedRange = nil
        findCurrentHighlightedRange = nil
    }

    /// Binary search: matches are collected in ascending order.
    private func firstMatchIndex(endingAfter location: Int) -> Int {
        var low = 0
        var high = findMatches.count
        while low < high {
            let mid = (low + high) / 2
            if findMatches[mid].location + findMatches[mid].length <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Scrolling brings different matches into view, so the highlight pass has
    /// to run again. Cheap: it only ever paints a screenful.
    private func beginFindHighlightObservation() {
        guard findScrollObserver == nil else { return }
        findScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let clipView = note.object as? NSClipView,
                  clipView === self.activeEditor?.enclosingScrollView?.contentView,
                  !self.findMatches.isEmpty else { return }
            self.applyFindHighlights()
        }
    }

    private func endFindHighlightObservation() {
        guard let observer = findScrollObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        findScrollObserver = nil
    }

    private func clearFindHighlights() {
        guard let editor = activeEditor,
              let layoutManager = editor.layoutManager,
              let container = editor.textContainer else { return }
        let length = (editor.string as NSString).length
        let visible = visibleCharacterRange(of: editor, layoutManager: layoutManager, container: container)
        clearPaintedHighlights(layoutManager: layoutManager, alsoClearing: visible, documentLength: length)
    }

    // MARK: - Replace

    private func doReplace(needle: String, replacement: String, options: FindOptions) {
        guard let editor = activeEditor,
              findMatches.indices.contains(findMatchIndex) else {
            runFind(needle: needle, options: options) { [weak self] in
                guard let self = self, !self.findMatches.isEmpty else { return }
                self.jumpToNearestMatch()
                self.goToMatch()
            }
            return
        }

        let match = findMatches[findMatchIndex]
        let range = NSRange(location: match.location, length: match.length)
        let textLength = (editor.string as NSString).length
        guard NSMaxRange(range) <= textLength else { return }

        var actualReplacement = replacement
        if options.useRegex {
            if let regex = try? NSRegularExpression(pattern: needle,
                                                     options: options.matchCase ? [] : [.caseInsensitive]) {
                let matchedStr = (editor.string as NSString).substring(with: range)
                actualReplacement = regex.stringByReplacingMatches(
                    in: matchedStr,
                    range: NSRange(location: 0, length: (matchedStr as NSString).length),
                    withTemplate: replacement
                )
            }
        }

        editor.setSelectedRange(range)
        editor.insertText(actualReplacement, replacementRange: range)

        let savedIndex = findMatchIndex
        runFind(needle: needle, options: options) { [weak self] in
            guard let self = self, !self.findMatches.isEmpty else { return }
            self.findMatchIndex = min(savedIndex, self.findMatches.count - 1)
            self.goToMatch()
        }
    }

    private func doReplaceAll(needle: String, replacement: String, options: FindOptions) {
        guard let editor = activeEditor else { return }

        // Deliberately not the incremental list: that one is capped and may
        // still be growing, which would rewrite part of the document and then
        // report the whole thing as replaced.
        let matches = collectAllMatches(needle: needle, options: options)
        guard !matches.isEmpty else {
            findPanelController?.updateMatchCount("No matches")
            return
        }
        cancelFindScan()

        let count = matches.count

        // Template expansion ($1, $2, ...) is resolved against the whole document
        // up front, keyed by match location. Re-matching the isolated substring
        // instead — as this used to — drops the surrounding context, so a pattern
        // with lookaround fails to re-match and the "replacement" is the original
        // text put back verbatim. Doing it before the loop also means every
        // expansion sees the document as it was, not as the reverse-order edits
        // have left it. This is what FileSearchService.Matcher already does.
        var expansions: [Int: String] = [:]
        if options.useRegex,
           let rx = try? NSRegularExpression(pattern: needle,
                                             options: options.matchCase ? [] : [.caseInsensitive]) {
            let original = editor.string
            let text = original as NSString
            rx.enumerateMatches(in: original, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                guard let match = match, match.range.length > 0 else { return }
                if options.wholeWord, !self.isWholeWord(in: text, range: match.range) { return }
                expansions[match.range.location] = rx.replacementString(
                    for: match, in: original, offset: 0, template: replacement)
            }
        }

        editor.undoManager?.beginUndoGrouping()

        for match in matches.reversed() {
            let range = NSRange(location: match.location, length: match.length)
            let actualReplacement = expansions[match.location] ?? replacement

            editor.setSelectedRange(range)
            editor.insertText(actualReplacement, replacementRange: range)
        }

        editor.undoManager?.endUndoGrouping()

        findMatches.removeAll()
        findMatchIndex = -1
        clearFindHighlights()

        findPanelController?.updateMatchCount("Replaced \(count) matches")
    }

    @objc func showFindInFiles(_ sender: Any?) {
        guard let parentWindow = view.window else { return }

        if findInFilesController == nil {
            findInFilesController = FindInFilesController()
            findInFilesController?.delegate = self
        }

        // Load and set folder history
        dirHistory = PersistenceService.shared.loadDirHistory()
        findInFilesController?.setFolderHistory(dirHistory)

        // Pre-fill from current file path and selection
        let currentPath = activeDocument?.fileURL?.path
        let selection = activeEditor?.selectedText()

        findInFilesController?.showPanel(relativeTo: parentWindow,
                                          currentFilePath: currentPath,
                                          selectedText: selection)
    }

    @objc func goToLine(_ sender: Any?) {
        guard let editor = activeEditor else { return }

        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let lineCount = activeDocument?.lineStartOffsets.count
            ?? (editor.string as NSString).lineCount
        alert.informativeText = "Line number (1 - \(lineCount)):"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = "\(editor.currentLineNumber() + 1)"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let lineNum = Int(input.stringValue), lineNum > 0 {
            editor.scrollToLine(lineNum)
        }
    }

    // MARK: - View

    @objc func showFontPanel(_ sender: Any?) {
        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.setSelectedFont(AppTheme.monoFont(size: AppTheme.fontSize), isMultiple: false)
        fontManager.orderFrontFontPanel(sender)
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        guard let editor = activeEditor, let doc = activeDocument else { return }
        let newState = !editor.wordWrapEnabled
        editor.wordWrapEnabled = newState
        doc.wordWrap = newState
        if let menuItem = sender as? NSMenuItem {
            menuItem.state = newState ? .on : .off
        }
    }

    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }

        // Store the whole font, not just its size: the highlighter and the
        // gutter both draw from AppTheme, so anything it doesn't record gets
        // painted over on the next pass.
        AppTheme.baseFont = fontManager.convert(AppTheme.baseFont)

        for tab in tabs {
            // Font and tab stops together — see EditorView.applyEditorFont.
            tab.editorView.applyEditorFont(AppTheme.monoFont)
            if let ts = tab.editorView.textStorage {
                tab.syntaxHighlighter.highlightAll(in: ts)
            }
            // Gutter width is derived from the digit width of the same font.
            (tab.scrollView.verticalRulerView as? LineNumberRulerView)?.fontDidChange()
        }
    }

    // MARK: - Bookmarks

    @objc func toggleBookmark(_ sender: Any?) {
        guard let editor = activeEditor, let doc = activeDocument else { return }
        let line = editor.currentLineNumber()
        if doc.bookmarks.contains(line) {
            doc.bookmarks.remove(line)
        } else {
            doc.bookmarks.insert(line)
        }
        editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    @objc func nextBookmark(_ sender: Any?) {
        guard let editor = activeEditor, let doc = activeDocument, !doc.bookmarks.isEmpty else { return }
        let current = editor.currentLineNumber()
        let sorted = doc.bookmarks.sorted()
        let next = sorted.first(where: { $0 > current }) ?? sorted.first!
        editor.scrollToLine(next + 1) // scrollToLine is 1-based
    }

    @objc func previousBookmark(_ sender: Any?) {
        guard let editor = activeEditor, let doc = activeDocument, !doc.bookmarks.isEmpty else { return }
        let current = editor.currentLineNumber()
        let sorted = doc.bookmarks.sorted()
        let prev = sorted.last(where: { $0 < current }) ?? sorted.last!
        editor.scrollToLine(prev + 1)
    }

    @objc func clearAllBookmarks(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        doc.bookmarks.removeAll()
        activeEditor?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: - Validate menu items

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument(_:)):
            return activeDocument?.isDirty ?? false
        case #selector(saveDocumentAs(_:)):
            return activeDocument != nil
        case #selector(revertToSaved(_:)):
            return activeDocument?.fileURL != nil
        case #selector(closeTab(_:)):
            return !tabs.isEmpty
        case #selector(toggleWordWrap(_:)):
            menuItem.state = (activeEditor?.wordWrapEnabled ?? true) ? .on : .off
            return activeEditor != nil
        case #selector(toggleBookmark(_:)), #selector(nextBookmark(_:)),
             #selector(previousBookmark(_:)), #selector(clearAllBookmarks(_:)):
            return activeEditor != nil
        case #selector(showFindPanel(_:)), #selector(showReplacePanel(_:)),
             #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(goToLine(_:)):
            return activeEditor != nil
        default:
            return true
        }
    }
}

// MARK: - NSSplitViewDelegate

extension EditorTabViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return subview === dirResultsView
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.bounds.height - 100
    }
}

// MARK: - NSTextViewDelegate

extension EditorTabViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard notification.object is EditorView else { return }

        // The edit invalidated every offset the running scan is collecting.
        cancelFindScan()

        // Debounce find re-run: wait 300ms after last keystroke to avoid O(n) scan per char
        if let panel = findPanelController, panel.window?.isVisible == true {
            let needle = panel.findText
            if !needle.isEmpty {
                findUpdateWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.runFind(needle: needle, options: panel.currentOptions) { [weak self] in
                        guard let self = self, !self.findMatches.isEmpty else { return }
                        self.jumpToNearestMatch()
                        self.goToMatch()
                    }
                }
                findUpdateWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
            }
        }
    }
}

// MARK: - FindInFilesDelegate (drives FileSearchService)

extension EditorTabViewController {

    func findInFiles(_ controller: FindInFilesController,
                     didSelectResult result: DirSearchResult) {
        openOrFocusTab(url: result.fileURL) { [weak self] in
            self?.activeEditor?.scrollToLine(result.lineNumber)
        }
    }

    func findInFiles(_ controller: FindInFilesController,
                     searchFor needle: String, replaceWith replacement: String?,
                     inFolder folder: String, fileTypes: String,
                     exclude: String, options: FindInFilesOptions) {

        // Replacing rewrites files on disk with no undo — confirm first.
        if replacement != nil {
            let alert = NSAlert()
            alert.messageText = "Replace All in Files"
            alert.informativeText = "Replace all occurrences of \"\(needle)\" in matching files under:\n\(folder)\n\nFiles are modified on disk. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace All")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // Files open with unsaved edits must not be rewritten under the user;
        // open-and-clean tabs are reloaded after the replace finishes.
        let dirtyOpenPaths = Set(tabs.filter { $0.document.isDirty }.compactMap { $0.document.fileURL?.path })

        PersistenceService.shared.addDirHistory(folder, to: &dirHistory)

        // Whatever is still running belongs to an older request: stop it, and
        // bump the generation so nothing it does from here on reaches the pane.
        dirSearch?.cancel()
        dirSearchGeneration += 1
        let generation = dirSearchGeneration
        let isReplacing = replacement != nil

        dirResultsView.clearResults()
        dirResultsView.setStatus(isReplacing ? "Replacing…" : "Searching…")
        dirResultsView.setRunning(true)
        dirResultsView.onStopClicked = { [weak self] in
            guard let self = self, generation == self.dirSearchGeneration else { return }
            self.dirSearch?.cancel()
            self.dirResultsView.setStatus("Stopping…")
        }
        showDirResults()

        var request = FileSearchService.Request(
            needle: needle,
            replacement: replacement,
            folder: URL(fileURLWithPath: folder),
            fileTypes: fileTypes,
            exclude: exclude,
            options: FileSearchService.Options(matchCase: options.matchCase,
                                               wholeWord: options.wholeWord,
                                               useRegex: options.useRegex,
                                               lookInSubfolders: options.lookInSubfolders))
        request.skipPaths = dirtyOpenPaths

        dirSearch = FileSearchService.shared.start(
            request,
            onBatch: { [weak self] batch in
                guard let self = self, generation == self.dirSearchGeneration else { return }
                self.dirResultsView.addResults(batch)
            },
            onProgress: { [weak self] progress in
                guard let self = self, generation == self.dirSearchGeneration else { return }
                let verb = isReplacing ? "Replacing" : "Searching"
                // The file total keeps climbing while the walk is still going.
                let total = progress.stillScanning ? "\(progress.filesFound)+" : "\(progress.filesFound)"
                self.dirResultsView.setStatus(
                    "\(verb)… \(progress.matches) matches (\(progress.filesSearched)/\(total) files)")
            },
            onFinish: { [weak self] summary in
                guard let self = self, generation == self.dirSearchGeneration else { return }
                self.dirSearch = nil
                self.dirResultsView.setRunning(false)
                self.dirResultsView.setStatus(
                    EditorTabViewController.searchStatusText(for: summary, replacing: isReplacing))
                self.reloadTabs(matching: Set(summary.modifiedPaths))
            })
    }

    private static func searchStatusText(for summary: FileSearchService.Summary,
                                         replacing: Bool) -> String {
        if let failure = summary.failure { return failure }

        var status: String
        if replacing {
            status = "Replaced \(summary.matches) matches in \(summary.modifiedPaths.count) files"
            if !summary.skippedPaths.isEmpty {
                status += " (\(summary.skippedPaths.count) files skipped: unsaved changes)"
            }
        } else {
            status = "\(summary.matches) matches in \(summary.filesSearched) files"
        }
        if summary.cancelled { status += " (stopped)" }
        if summary.limitReached { status += " (limit reached)" }
        return status
    }

    /// Reloads open, clean tabs whose files were rewritten on disk by a replace.
    /// Paths are compared symlink-resolved on both sides.
    private func reloadTabs(matching paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for tab in tabs {
            guard let url = tab.document.fileURL,
                  paths.contains(FileSearchService.canonicalPath(url)) else { continue }
            loadFile(into: tab.document, editorView: tab.editorView,
                     syntaxHighlighter: tab.syntaxHighlighter, url: url)
        }
    }

}


// MARK: - EditorView helper

extension EditorView {
    func selectedText() -> String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        return (string as NSString).substring(with: range)
    }
}
