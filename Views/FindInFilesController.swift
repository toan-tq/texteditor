import AppKit

protocol FindInFilesDelegate: AnyObject {
    func findInFiles(_ controller: FindInFilesController, didSelectResult result: DirSearchResult)
    func findInFiles(_ controller: FindInFilesController, searchFor needle: String, replaceWith: String?,
                     inFolder: String, fileTypes: String, exclude: String, options: FindInFilesOptions)
}

struct FindInFilesOptions {
    var matchCase: Bool = false
    var wholeWord: Bool = false
    var useRegex: Bool = false
    var lookInSubfolders: Bool = true
}

class FindInFilesController: NSWindowController, NSTextFieldDelegate {
    weak var delegate: FindInFilesDelegate?

    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let fileTypesField = NSTextField()
    private let excludeScrollView = NSScrollView()
    private let excludeField = NSTextView()
    private let folderCombo = NSComboBox()
    private let excludePresetCombo = NSPopUpButton(frame: .zero, pullsDown: false)

    private let findLabel = NSTextField(labelWithString: "Find:")
    private let replaceFieldLabel = NSTextField(labelWithString: "Replace:")
    private let fileTypesLabel = NSTextField(labelWithString: "File Types:")
    private let excludeLabel = NSTextField(labelWithString: "Exclude:")
    private let folderLabel = NSTextField(labelWithString: "In Folder:")

    private let matchCaseButton = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeWordButton = NSButton(checkboxWithTitle: "Match Whole Word", target: nil, action: nil)
    private let regexButton = NSButton(checkboxWithTitle: "Use Regular Expressions", target: nil, action: nil)
    private let subfoldersButton = NSButton(checkboxWithTitle: "Look in Subfolders", target: nil, action: nil)

    private let findAllButton = NSButton(title: "Find All", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let toggleButton = NSButton(title: "Replace >>", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let browseButton = NSButton(title: "...", target: nil, action: nil)

    private var replaceVisible = false
    private var dirHistory: [String] = []
    private var eventMonitor: Any?

    // Replace row height constraint for toggling visibility
    private var replaceRowHeightConstraint: NSLayoutConstraint?

    // Exclude presets ported from Java
    private let presets: [(name: String, patterns: [String])] = [
        ("C++/Qt", ["build", "out", "tests", "CMakeFiles", "*.o", "*.obj", "*.a", "*.lib",
                     "*.so", "*.dylib", "*.dll", "*.exe", "*.moc", "*.qrc", "moc_*", "ui_*", "qrc_*"]),
        ("Python", ["__pycache__", "*.pyc", "*.pyo", "*.egg-info", "dist", "*.egg",
                     ".tox", ".venv", "venv", "env"]),
        ("Node.js", ["node_modules", "dist", "build", ".next", "coverage", "*.min.js", "*.map",
                      "package-lock.json", "yarn.lock"]),
        ("Java", ["target", "build", "out", ".gradle", "*.class", "*.jar", "*.war"]),
        ("Swift", [".build", "DerivedData", "*.o", "*.dSYM", "Pods", "Carthage"]),
        ("None", [])
    ]

    private static let panelWidth: CGFloat = 560
    private static let panelHeightFind: CGFloat = 340
    private static let panelHeightReplace: CGFloat = 370

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: FindInFilesController.panelWidth,
                                height: FindInFilesController.panelHeightFind),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find in Files"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.minSize = NSSize(width: 480, height: 300)

        self.init(window: panel)
        self.replaceVisible = false

        // Configure the exclude text view
        excludeField.isRichText = false
        excludeField.font = AppTheme.monoFont(size: AppTheme.fontSize)
        excludeField.isVerticallyResizable = true
        excludeField.isHorizontallyResizable = false
        excludeField.autoresizingMask = [.width]

        setupUI()
        setReplaceVisible(false)
    }

    // MARK: - UI Construction

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        let margin: CGFloat = 14
        let vSpacing: CGFloat = 6
        let labelWidth: CGFloat = 80

        // Configure find field
        findField.font = AppTheme.monoFont(size: AppTheme.fontSize)
        findField.placeholderString = "Search text"
        findField.delegate = self
        findField.translatesAutoresizingMaskIntoConstraints = false

        // Configure replace field
        replaceField.font = AppTheme.monoFont(size: AppTheme.fontSize)
        replaceField.placeholderString = "Replacement text"
        replaceField.translatesAutoresizingMaskIntoConstraints = false

        // File types field
        fileTypesField.font = AppTheme.monoFont(size: AppTheme.fontSize)
        fileTypesField.stringValue = "*"
        fileTypesField.placeholderString = "*.java;*.py;*.swift"
        fileTypesField.translatesAutoresizingMaskIntoConstraints = false

        // Exclude preset combo
        excludePresetCombo.translatesAutoresizingMaskIntoConstraints = false
        for preset in presets {
            excludePresetCombo.addItem(withTitle: preset.name)
        }
        excludePresetCombo.target = self
        excludePresetCombo.action = #selector(presetChanged)

        // Exclude text view in scroll view
        excludeScrollView.hasVerticalScroller = true
        excludeScrollView.borderType = .bezelBorder
        excludeScrollView.translatesAutoresizingMaskIntoConstraints = false
        excludeField.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        excludeField.textContainer?.widthTracksTextView = true
        excludeScrollView.documentView = excludeField
        // Set default exclude to C++/Qt preset
        excludeField.string = presets[0].patterns.joined(separator: "\n")

        // Folder combo
        folderCombo.isEditable = true
        folderCombo.font = AppTheme.monoFont(size: AppTheme.fontSize)
        folderCombo.translatesAutoresizingMaskIntoConstraints = false
        folderCombo.completes = true

        // Browse button
        browseButton.target = self
        browseButton.action = #selector(browseClicked)
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.bezelStyle = .rounded

        // Labels
        findLabel.translatesAutoresizingMaskIntoConstraints = false
        replaceFieldLabel.translatesAutoresizingMaskIntoConstraints = false
        fileTypesLabel.translatesAutoresizingMaskIntoConstraints = false
        excludeLabel.translatesAutoresizingMaskIntoConstraints = false
        folderLabel.translatesAutoresizingMaskIntoConstraints = false

        // Options checkboxes
        matchCaseButton.translatesAutoresizingMaskIntoConstraints = false
        wholeWordButton.translatesAutoresizingMaskIntoConstraints = false
        regexButton.translatesAutoresizingMaskIntoConstraints = false
        subfoldersButton.translatesAutoresizingMaskIntoConstraints = false
        subfoldersButton.state = .on  // Look in Subfolders on by default

        // Buttons
        findAllButton.target = self
        findAllButton.action = #selector(findAllClicked)
        // NOTE: no "\r" keyEquivalent — a window-wide default button meant
        // Enter in ANY field (folder combo, file types...) silently kicked
        // off a search behind the panel. Enter is handled per-field via
        // NSTextFieldDelegate instead (see control(_:textView:doCommandBy:)).
        findAllButton.translatesAutoresizingMaskIntoConstraints = false

        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
        replaceAllButton.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // Button column — all buttons identical size, text centered
        let allButtons = [findAllButton, replaceAllButton, toggleButton, closeButton]
        let buttonWidth: CGFloat = 120
        let buttonHeight: CGFloat = 24
        for btn in allButtons {
            btn.bezelStyle = .rounded
            btn.alignment = .center
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: buttonWidth),
                btn.heightAnchor.constraint(equalToConstant: buttonHeight),
            ])
        }
        let buttonStack = NSStackView(views: allButtons)
        buttonStack.orientation = .vertical
        buttonStack.spacing = 4
        buttonStack.distribution = .equalSpacing
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        // Options row: 2x2 grid
        let optLeftCol = NSStackView(views: [matchCaseButton, regexButton])
        optLeftCol.orientation = .vertical
        optLeftCol.alignment = .leading
        optLeftCol.spacing = 4
        optLeftCol.translatesAutoresizingMaskIntoConstraints = false

        let optRightCol = NSStackView(views: [wholeWordButton, subfoldersButton])
        optRightCol.orientation = .vertical
        optRightCol.alignment = .leading
        optRightCol.spacing = 4
        optRightCol.translatesAutoresizingMaskIntoConstraints = false

        let optionsRow = NSStackView(views: [optLeftCol, optRightCol])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 16
        optionsRow.translatesAutoresizingMaskIntoConstraints = false

        // Add subviews
        contentView.addSubview(findLabel)
        contentView.addSubview(findField)
        contentView.addSubview(replaceFieldLabel)
        contentView.addSubview(replaceField)
        contentView.addSubview(fileTypesLabel)
        contentView.addSubview(fileTypesField)
        contentView.addSubview(excludeLabel)
        contentView.addSubview(excludePresetCombo)
        contentView.addSubview(excludeScrollView)
        contentView.addSubview(folderLabel)
        contentView.addSubview(folderCombo)
        contentView.addSubview(browseButton)
        contentView.addSubview(optionsRow)
        contentView.addSubview(buttonStack)

        let replaceRowHeight = makeReplaceRowHeightConstraint(visible: replaceVisible)
        self.replaceRowHeightConstraint = replaceRowHeight

        NSLayoutConstraint.activate([
            // Row 1: Find
            findLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            findLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            findLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            findField.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            findField.leadingAnchor.constraint(equalTo: findLabel.trailingAnchor, constant: 4),
            findField.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),

            // Row 2: Replace (toggled)
            replaceFieldLabel.topAnchor.constraint(equalTo: findLabel.bottomAnchor, constant: vSpacing),
            replaceFieldLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            replaceFieldLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            replaceRowHeight,

            replaceField.centerYAnchor.constraint(equalTo: replaceFieldLabel.centerYAnchor),
            replaceField.leadingAnchor.constraint(equalTo: replaceFieldLabel.trailingAnchor, constant: 4),
            replaceField.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),

            // Row 3: File Types
            fileTypesLabel.topAnchor.constraint(equalTo: replaceFieldLabel.bottomAnchor, constant: vSpacing),
            fileTypesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            fileTypesLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            fileTypesField.centerYAnchor.constraint(equalTo: fileTypesLabel.centerYAnchor),
            fileTypesField.leadingAnchor.constraint(equalTo: fileTypesLabel.trailingAnchor, constant: 4),
            fileTypesField.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),

            // Row 4: Exclude preset combo
            excludeLabel.topAnchor.constraint(equalTo: fileTypesLabel.bottomAnchor, constant: vSpacing),
            excludeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            excludeLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            excludePresetCombo.centerYAnchor.constraint(equalTo: excludeLabel.centerYAnchor),
            excludePresetCombo.leadingAnchor.constraint(equalTo: excludeLabel.trailingAnchor, constant: 4),
            excludePresetCombo.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),

            // Row 5: Exclude text (multi-line), skip label column
            excludeScrollView.topAnchor.constraint(equalTo: excludeLabel.bottomAnchor, constant: vSpacing),
            excludeScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin + labelWidth + 4),
            excludeScrollView.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),
            excludeScrollView.heightAnchor.constraint(equalToConstant: 60),

            // Row 6: In Folder (combo + browse)
            folderLabel.topAnchor.constraint(equalTo: excludeScrollView.bottomAnchor, constant: vSpacing + 6),
            folderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            folderLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            folderCombo.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),
            folderCombo.leadingAnchor.constraint(equalTo: folderLabel.trailingAnchor, constant: 4),
            folderCombo.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -4),

            browseButton.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),
            browseButton.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),
            browseButton.widthAnchor.constraint(equalToConstant: 30),

            // Row 7: Options
            optionsRow.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: vSpacing + 2),
            optionsRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            optionsRow.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),
            optionsRow.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -margin),

            // Button column
            buttonStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            buttonStack.widthAnchor.constraint(equalToConstant: 124),
        ])

        // Key event monitor
        setupKeyMonitor()
    }

    private func makeReplaceRowHeightConstraint(visible: Bool) -> NSLayoutConstraint {
        if visible {
            return replaceFieldLabel.heightAnchor.constraint(equalToConstant: 22)
        } else {
            return replaceFieldLabel.heightAnchor.constraint(equalToConstant: 0)
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let panel = self.window,
                  panel.isVisible,
                  event.window === panel else {
                return event
            }

            // Escape -> close
            if event.keyCode == KeyCode.escape {
                self.closeClicked()
                return nil
            }

            return event
        }
    }

    // MARK: - Public API

    func showPanel(relativeTo parentWindow: NSWindow, currentFilePath: String?, selectedText: String?) {
        guard let panel = self.window else { return }

        // Pre-fill folder from current file path
        if let path = currentFilePath {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                folderCombo.stringValue = dir
            }
        }

        // Pre-fill find text from selection
        if let sel = selectedText, !sel.isEmpty, !sel.contains("\n") {
            findField.stringValue = sel
            findField.selectText(nil)
        }

        // Center over parent window
        let parentFrame = parentWindow.frame
        let panelSize = panel.frame.size
        let x = parentFrame.origin.x + (parentFrame.width - panelSize.width) / 2
        let y = parentFrame.origin.y + (parentFrame.height - panelSize.height) / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        showWindow(nil)
        window?.makeFirstResponder(findField)
    }

    func setFolderHistory(_ history: [String]) {
        dirHistory = history
        folderCombo.removeAllItems()
        for h in history {
            folderCombo.addItem(withObjectValue: h)
        }
        if let first = history.first, folderCombo.stringValue.isEmpty {
            folderCombo.stringValue = first
        }
    }

    func setReplaceVisible(_ visible: Bool) {
        replaceVisible = visible
        replaceFieldLabel.isHidden = !visible
        replaceField.isHidden = !visible
        replaceAllButton.isHidden = !visible
        toggleButton.title = visible ? "<< Find" : "Replace >>"
        window?.title = visible ? "Replace in Files" : "Find in Files"

        // Update constraint
        if let existing = replaceRowHeightConstraint {
            existing.isActive = false
        }
        let newConstraint = makeReplaceRowHeightConstraint(visible: visible)
        newConstraint.isActive = true
        replaceRowHeightConstraint = newConstraint

        // Resize panel
        guard let panel = window else { return }
        var frame = panel.frame
        let targetHeight = visible
            ? FindInFilesController.panelHeightReplace
            : FindInFilesController.panelHeightFind
        let delta = targetHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = targetHeight
        panel.setFrame(frame, display: true, animate: true)
    }

    var currentOptions: FindInFilesOptions {
        FindInFilesOptions(
            matchCase: matchCaseButton.state == .on,
            wholeWord: wholeWordButton.state == .on,
            useRegex: regexButton.state == .on,
            lookInSubfolders: subfoldersButton.state == .on
        )
    }

    // MARK: - Actions

    private func addToFolderHistory(_ folder: String) {
        if !dirHistory.contains(folder) {
            dirHistory.insert(folder, at: 0)
            if dirHistory.count > 7 { dirHistory.removeLast() }
            folderCombo.insertItem(withObjectValue: folder, at: 0)
        }
    }

    @objc private func findAllClicked() {
        let needle = findField.stringValue.trimmingCharacters(in: .whitespaces)
        let folder = folderCombo.stringValue.trimmingCharacters(in: .whitespaces)
        let types = fileTypesField.stringValue.trimmingCharacters(in: .whitespaces)
        let excludeStr = excludeField.string.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\n", with: ";")
            .replacingOccurrences(of: "\r", with: ";")
        guard !needle.isEmpty, !folder.isEmpty else { return }

        addToFolderHistory(folder)

        delegate?.findInFiles(self, searchFor: needle, replaceWith: nil,
                              inFolder: folder, fileTypes: types, exclude: excludeStr,
                              options: currentOptions)
    }

    @objc private func replaceAllClicked() {
        let needle = findField.stringValue.trimmingCharacters(in: .whitespaces)
        let replacement = replaceField.stringValue
        let folder = folderCombo.stringValue.trimmingCharacters(in: .whitespaces)
        let types = fileTypesField.stringValue.trimmingCharacters(in: .whitespaces)
        let excludeStr = excludeField.string.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\n", with: ";")
            .replacingOccurrences(of: "\r", with: ";")
        guard !needle.isEmpty, !folder.isEmpty else { return }

        addToFolderHistory(folder)

        delegate?.findInFiles(self, searchFor: needle, replaceWith: replacement,
                              inFolder: folder, fileTypes: types, exclude: excludeStr,
                              options: currentOptions)
    }

    @objc private func toggleClicked() {
        setReplaceVisible(!replaceVisible)
    }

    // MARK: - NSTextFieldDelegate

    // Enter in the Find field runs the search; Enter anywhere else does nothing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), control === findField {
            findAllClicked()
            return true
        }
        return false
    }

    @objc private func closeClicked() {
        window?.orderOut(nil)
    }

    @objc private func browseClicked() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false

        let currentPath = folderCombo.stringValue
        if !currentPath.isEmpty {
            openPanel.directoryURL = URL(fileURLWithPath: currentPath)
        }

        guard let parentWindow = window else { return }
        openPanel.beginSheetModal(for: parentWindow) { [weak self] response in
            if response == .OK, let url = openPanel.url {
                self?.folderCombo.stringValue = url.path
            }
        }
    }

    @objc private func presetChanged() {
        let idx = excludePresetCombo.indexOfSelectedItem
        if idx >= 0 && idx < presets.count {
            excludeField.string = presets[idx].patterns.joined(separator: "\n")
        }
    }
}
