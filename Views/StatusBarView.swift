import AppKit

class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")
    /// Transient notices ("Reloaded from disk"). Kept apart from `label` so a
    /// message doesn't have to fight the cursor readout, which repaints on
    /// every keystroke.
    private let messageLabel = NSTextField(labelWithString: "")
    private var messageClearWorkItem: DispatchWorkItem?

    private static let messageDuration: TimeInterval = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = AppTheme.statusBg.cgColor

        label.font = AppTheme.monoFont(size: AppTheme.fontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        messageLabel.font = AppTheme.monoFont(size: AppTheme.fontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .right
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    /// Shows `text` on the right for a few seconds. The cursor readout on the
    /// left keeps updating underneath it.
    func flash(_ text: String) {
        messageClearWorkItem?.cancel()
        messageLabel.stringValue = text

        let clear = DispatchWorkItem { [weak self] in
            self?.messageLabel.stringValue = ""
        }
        messageClearWorkItem = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.messageDuration, execute: clear)
    }

    func updateFromTextView(_ textView: NSTextView) {
        let text = textView.string as NSString
        let cursorPos = min(textView.selectedRange().location, text.length)

        // Use cached line offsets for O(log n) lookup
        if let doc = (textView as? EditorView)?.tabDocument, !doc.lineStartOffsets.isEmpty {
            let lineIdx = doc.lineIndex(forCharOffset: cursorPos)
            guard lineIdx >= 0, lineIdx < doc.lineStartOffsets.count else {
                label.stringValue = ""
                return
            }
            let line = lineIdx + 1
            let col = cursorPos - doc.lineStartOffsets[lineIdx] + 1
            let totalLines = doc.lineStartOffsets.count
            let totalChars = text.length
            label.stringValue = "Ln \(line), Col \(col)    |    \(totalLines) lines, \(totalChars) chars"
        } else {
            label.stringValue = ""
        }
    }

    func clear() {
        label.stringValue = ""
    }
}
