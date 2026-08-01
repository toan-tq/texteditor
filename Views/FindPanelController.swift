import AppKit

protocol FindPanelDelegate: AnyObject {
    func findPanel(_ panel: FindPanelController, findNext needle: String, options: FindOptions)
    func findPanel(_ panel: FindPanelController, findPrev needle: String, options: FindOptions)
    func findPanel(_ panel: FindPanelController, replace needle: String, with replacement: String, options: FindOptions)
    func findPanel(_ panel: FindPanelController, replaceAll needle: String, with replacement: String, options: FindOptions)
    func findPanelDidClose(_ panel: FindPanelController)
    func findPanel(_ panel: FindPanelController, searchTextChanged needle: String, options: FindOptions)
}

struct FindOptions {
    var matchCase: Bool = false
    var wholeWord: Bool = false
    var useRegex: Bool = false
    var wrapAround: Bool = true
}

class FindPanelController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    weak var delegate: FindPanelDelegate?

    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let findLabel = NSTextField(labelWithString: "Find what:")
    private let replaceLabel = NSTextField(labelWithString: "Replace with:")
    private let matchCountLabel = NSTextField(labelWithString: "")

    private let matchCaseButton = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeWordButton = NSButton(checkboxWithTitle: "Match Whole Word", target: nil, action: nil)
    private let regexButton = NSButton(checkboxWithTitle: "Use Regular Expressions", target: nil, action: nil)
    private let wrapButton = NSButton(checkboxWithTitle: "Wrap Around", target: nil, action: nil)

    private let findNextButton = NSButton(title: "Find Next", target: nil, action: nil)
    private let findPrevButton = NSButton(title: "Find Previous", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let toggleButton = NSButton(title: "Replace >>", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private var replaceVisible = false
    private var eventMonitor: Any?

    /// Debounce work item for incremental search; prevents a full-document
    /// scan on every keystroke when typing into the find field.
    private var searchDebounce: DispatchWorkItem?

    // Constraints that change when toggling replace row visibility
    private var replaceRowHeightConstraint: NSLayoutConstraint?
    private var panelHeightConstraint: NSLayoutConstraint?

    private static let panelWidthFind: CGFloat = 520
    private static let panelHeightFind: CGFloat = 180
    private static let panelHeightReplace: CGFloat = 215

    convenience init(withReplace: Bool = false) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: FindPanelController.panelWidthFind,
                                height: withReplace
                                    ? FindPanelController.panelHeightReplace
                                    : FindPanelController.panelHeightFind),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = withReplace ? "Replace" : "Find"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        self.init(window: panel)
        // Delegate hooks windowWillClose so closing via the title-bar ✕
        // runs the same cleanup as the Close button.
        panel.delegate = self
        self.replaceVisible = withReplace
        setupUI()
        setReplaceVisible(withReplace)
    }

    // MARK: - UI Construction

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Configure find field
        findField.font = AppTheme.monoFont(size: AppTheme.fontSize)
        findField.placeholderString = "Search text"
        findField.delegate = self
        findField.translatesAutoresizingMaskIntoConstraints = false

        // Configure replace field
        replaceField.font = AppTheme.monoFont(size: AppTheme.fontSize)
        replaceField.placeholderString = "Replacement text"
        replaceField.translatesAutoresizingMaskIntoConstraints = false

        // Labels
        findLabel.translatesAutoresizingMaskIntoConstraints = false
        replaceLabel.translatesAutoresizingMaskIntoConstraints = false

        // Match count label
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.font = NSFont.systemFont(ofSize: 11)
        matchCountLabel.translatesAutoresizingMaskIntoConstraints = false

        // Options
        matchCaseButton.translatesAutoresizingMaskIntoConstraints = false
        wholeWordButton.translatesAutoresizingMaskIntoConstraints = false
        regexButton.translatesAutoresizingMaskIntoConstraints = false
        wrapButton.translatesAutoresizingMaskIntoConstraints = false

        wrapButton.state = .on  // Wrap Around on by default

        matchCaseButton.target = self
        matchCaseButton.action = #selector(optionChanged)
        wholeWordButton.target = self
        wholeWordButton.action = #selector(optionChanged)
        regexButton.target = self
        regexButton.action = #selector(optionChanged)
        wrapButton.target = self
        wrapButton.action = #selector(optionChanged)

        // Buttons
        findNextButton.target = self
        findNextButton.action = #selector(findNextClicked)
        findNextButton.keyEquivalent = "\r"
        findNextButton.translatesAutoresizingMaskIntoConstraints = false

        findPrevButton.target = self
        findPrevButton.action = #selector(findPrevClicked)
        findPrevButton.translatesAutoresizingMaskIntoConstraints = false

        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        replaceButton.translatesAutoresizingMaskIntoConstraints = false

        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
        replaceAllButton.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // -- Layout --
        // Left area: labels + fields stacked vertically
        // Right area: button column

        // Button column — all buttons identical size, text centered
        let allButtons = [findNextButton, findPrevButton, replaceButton, replaceAllButton, toggleButton, closeButton]
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

        let optRightCol = NSStackView(views: [wholeWordButton, wrapButton])
        optRightCol.orientation = .vertical
        optRightCol.alignment = .leading
        optRightCol.spacing = 4
        optRightCol.translatesAutoresizingMaskIntoConstraints = false

        let optionsRow = NSStackView(views: [optLeftCol, optRightCol])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 16
        optionsRow.translatesAutoresizingMaskIntoConstraints = false

        // Add all subviews
        contentView.addSubview(findLabel)
        contentView.addSubview(findField)
        contentView.addSubview(replaceLabel)
        contentView.addSubview(replaceField)
        contentView.addSubview(optionsRow)
        contentView.addSubview(matchCountLabel)
        contentView.addSubview(buttonStack)

        let margin: CGFloat = 14
        let vSpacing: CGFloat = 6
        let labelWidth: CGFloat = 90

        let replaceRowHeight = replaceRowHeightConstraint(visible: replaceVisible)
        self.replaceRowHeightConstraint = replaceRowHeight

        NSLayoutConstraint.activate([
            // Find label + field - Row 1
            findLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            findLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            findLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            findField.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            findField.leadingAnchor.constraint(equalTo: findLabel.trailingAnchor, constant: 4),
            findField.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),

            // Replace label + field - Row 2
            replaceLabel.topAnchor.constraint(equalTo: findLabel.bottomAnchor, constant: vSpacing),
            replaceLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            replaceLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            replaceRowHeight,

            replaceField.centerYAnchor.constraint(equalTo: replaceLabel.centerYAnchor),
            replaceField.leadingAnchor.constraint(equalTo: replaceLabel.trailingAnchor, constant: 4),
            replaceField.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -12),

            // Options - Row 3
            optionsRow.topAnchor.constraint(equalTo: replaceLabel.bottomAnchor, constant: vSpacing),
            optionsRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            optionsRow.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),

            // Match count - Row 4
            matchCountLabel.topAnchor.constraint(equalTo: optionsRow.bottomAnchor, constant: vSpacing),
            matchCountLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            matchCountLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),

            // Button column - right side, top-aligned
            buttonStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            buttonStack.widthAnchor.constraint(equalToConstant: 124),
        ])

        // Key event monitor for Escape and Shift+Enter in find/replace fields
        setupKeyMonitor()
    }

    private func replaceRowHeightConstraint(visible: Bool) -> NSLayoutConstraint {
        if visible {
            return replaceLabel.heightAnchor.constraint(equalToConstant: 22)
        } else {
            return replaceLabel.heightAnchor.constraint(equalToConstant: 0)
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupKeyMonitor() {
        // Local event monitor for key events while the panel is key
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

            // Shift+Enter -> find previous
            if event.keyCode == KeyCode.returnKey && event.modifierFlags.contains(.shift) {
                self.findPrevClicked()
                return nil
            }

            return event
        }
    }

    // MARK: - Public API

    func setReplaceVisible(_ visible: Bool) {
        replaceVisible = visible
        replaceLabel.isHidden = !visible
        replaceField.isHidden = !visible
        replaceButton.isHidden = !visible
        replaceAllButton.isHidden = !visible
        toggleButton.title = visible ? "<< Find" : "Replace >>"
        window?.title = visible ? "Replace" : "Find"

        // Update layout constraint
        if let existing = replaceRowHeightConstraint {
            existing.isActive = false
        }
        let newConstraint = replaceRowHeightConstraint(visible: visible)
        newConstraint.isActive = true
        replaceRowHeightConstraint = newConstraint

        // Resize panel
        guard let panel = window else { return }
        var frame = panel.frame
        let targetHeight = visible
            ? FindPanelController.panelHeightReplace
            : FindPanelController.panelHeightFind
        let delta = targetHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = targetHeight
        panel.setFrame(frame, display: true, animate: true)
    }

    func updateMatchCount(_ text: String) {
        matchCountLabel.stringValue = text
    }

    func prefillWithSelection(_ text: String) {
        if !text.isEmpty && !text.contains("\n") {
            findField.stringValue = text
            findField.selectText(nil)
        }
    }

    var currentOptions: FindOptions {
        FindOptions(
            matchCase: matchCaseButton.state == .on,
            wholeWord: wholeWordButton.state == .on,
            useRegex: regexButton.state == .on,
            wrapAround: wrapButton.state == .on
        )
    }

    var findText: String {
        findField.stringValue
    }

    var replaceText: String {
        replaceField.stringValue
    }

    // MARK: - NSTextFieldDelegate (incremental search)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === findField else { return }
        // Debounce 200ms so each keystroke (especially during IME composition)
        // doesn't trigger a full-document scan.
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.delegate?.findPanel(self, searchTextChanged: self.findField.stringValue,
                                      options: self.currentOptions)
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // Also handle Enter in the replace field (not the default button)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === replaceField {
                // Enter in replace field -> find next
                findNextClicked()
                return true
            }
        }
        return false
    }

    // MARK: - Panel Display

    func showPanel(relativeTo parentWindow: NSWindow) {
        guard let panel = self.window else { return }
        let parentFrame = parentWindow.frame
        let panelSize = panel.frame.size
        let x = parentFrame.origin.x + (parentFrame.width - panelSize.width) / 2
        let y = parentFrame.origin.y + (parentFrame.height - panelSize.height) / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        showWindow(nil)
        window?.makeFirstResponder(findField)
    }

    // MARK: - Actions

    @objc private func findNextClicked() {
        let needle = findField.stringValue
        guard !needle.isEmpty else { return }
        delegate?.findPanel(self, findNext: needle, options: currentOptions)
    }

    @objc private func findPrevClicked() {
        let needle = findField.stringValue
        guard !needle.isEmpty else { return }
        delegate?.findPanel(self, findPrev: needle, options: currentOptions)
    }

    @objc private func replaceClicked() {
        let needle = findField.stringValue
        guard !needle.isEmpty else { return }
        delegate?.findPanel(self, replace: needle, with: replaceField.stringValue, options: currentOptions)
    }

    @objc private func replaceAllClicked() {
        let needle = findField.stringValue
        guard !needle.isEmpty else { return }
        delegate?.findPanel(self, replaceAll: needle, with: replaceField.stringValue, options: currentOptions)
    }

    @objc private func toggleClicked() {
        setReplaceVisible(!replaceVisible)
    }

    @objc private func closeClicked() {
        cleanupOnClose()
        window?.orderOut(nil)
    }

    /// Shared teardown for every close path (Close button, Escape, title-bar ✕).
    /// Cancels the pending debounced search so it can't re-apply highlights
    /// after the delegate has already cleared them.
    private func cleanupOnClose() {
        searchDebounce?.cancel()
        searchDebounce = nil
        delegate?.findPanelDidClose(self)
    }

    // MARK: - NSWindowDelegate

    // Title-bar ✕ closes the window without going through closeClicked.
    func windowWillClose(_ notification: Notification) {
        cleanupOnClose()
    }

    @objc private func optionChanged() {
        // Re-trigger incremental search when any option checkbox changes
        let needle = findField.stringValue
        if !needle.isEmpty {
            delegate?.findPanel(self, searchTextChanged: needle, options: currentOptions)
        }
    }
}
