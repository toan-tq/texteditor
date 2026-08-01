import AppKit

protocol DirSearchResultsDelegate: AnyObject {
    func dirSearchResults(_ view: DirSearchResultsView, didSelectResult result: DirSearchResult)
}

/// Bottom pane listing Find in Files hits.
///
/// All chrome lives in one strip above the table: close box on the left (macOS
/// puts window close buttons top-left), status text next to it, spinner and
/// Stop on the right while a run is in flight. There is deliberately no second
/// row along the bottom — the buttons used to float in the bottom-right corner
/// with nothing to anchor them.
class DirSearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: DirSearchResultsDelegate?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerRow = NSView()
    private let titleLabel = NSTextField(labelWithString: "Find Results")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let closeButton = NSButton()

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("DirSearchResultCell")

    private(set) var results: [DirSearchResult] = []
    private(set) var isRunning = false

    var onStopClicked: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // Table with 3 columns: File, Line, Content
        let fileCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        fileCol.title = "File"
        fileCol.width = 300

        let lineCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Line"))
        lineCol.title = "Line"
        lineCol.width = 60

        let contentCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Content"))
        contentCol.title = "Content"
        contentCol.width = 800

        tableView.addTableColumn(fileCol)
        tableView.addTableColumn(lineCol)
        tableView.addTableColumn(contentCol)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.font = AppTheme.monoFont(size: AppTheme.fontSize)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        // Header strip
        headerRow.wantsLayer = true
        headerRow.layer?.backgroundColor = AppTheme.lineNumBg.cgColor

        configureCloseButton()

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.toolTip = "Stop the running search (Esc)"
        stopButton.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator

        for subview in [scrollView, headerRow, titleLabel, statusLabel, spinner,
                        stopButton, closeButton, separator] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }

        addSubview(headerRow)
        addSubview(scrollView)
        headerRow.addSubview(closeButton)
        headerRow.addSubview(titleLabel)
        headerRow.addSubview(statusLabel)
        headerRow.addSubview(spinner)
        headerRow.addSubview(stopButton)
        headerRow.addSubview(separator)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 26),

            closeButton.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),

            spinner.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),

            stopButton.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -6),
            stopButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The status text yields before the title does when space runs short.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureCloseButton() {
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.toolTip = "Close results (Esc)"
        closeButton.setAccessibilityLabel("Close search results")

        if let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close search results") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            closeButton.image = symbol.withSymbolConfiguration(config)
            closeButton.imagePosition = .imageOnly
            closeButton.contentTintColor = .secondaryLabelColor
        } else {
            closeButton.title = "✕"
            closeButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        }
    }

    // MARK: - Content

    func clearResults() {
        results.removeAll()
        tableView.reloadData()
    }

    func addResults(_ newResults: [DirSearchResult]) {
        guard !newResults.isEmpty else { return }
        results.append(contentsOf: newResults)
        // Cheaper than reloadData: rows already on screen keep their views.
        tableView.noteNumberOfRowsChanged()
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Shows the spinner and the Stop button for the duration of a run.
    func setRunning(_ running: Bool) {
        isRunning = running
        stopButton.isHidden = !running
        if running {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    @objc private func stopClicked() {
        onStopClicked?()
    }

    @objc private func closeClicked() {
        onCloseRequested?()
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < results.count else { return }
        delegate?.dirSearchResults(self, didSelectResult: results[row])
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < results.count else { return nil }
        let result = results[row]

        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = Self.cellIdentifier
            cell.font = AppTheme.monoFont(size: AppTheme.fontSize)
            cell.lineBreakMode = .byTruncatingTail
        }

        // Recycled cells arrive with the previous column's settings.
        cell.alignment = .left
        cell.toolTip = nil

        switch tableColumn?.identifier.rawValue {
        case "File":
            cell.stringValue = result.fileURL.lastPathComponent
            cell.toolTip = result.fileURL.path
        case "Line":
            cell.stringValue = "\(result.lineNumber)"
            cell.alignment = .right
        case "Content":
            cell.stringValue = result.lineText
        default:
            cell.stringValue = ""
        }
        return cell
    }

    /// Enter opens the selected hit. Escape stops a running search first, and
    /// only closes the pane once nothing is running.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.returnKey {
            let row = tableView.selectedRow
            guard row >= 0 && row < results.count else { return }
            delegate?.dirSearchResults(self, didSelectResult: results[row])
        } else if event.keyCode == KeyCode.escape {
            if isRunning {
                onStopClicked?()
            } else {
                onCloseRequested?()
            }
        } else {
            super.keyDown(with: event)
        }
    }
}
