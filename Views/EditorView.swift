import AppKit

class EditorView: NSTextView {
    weak var statusUpdateDelegate: StatusBarView?
    var tabDocument: TabDocument?

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        textColor = .black
        backgroundColor = NSColor(red: 250/255.0, green: 250/255.0, blue: 250/255.0, alpha: 1)
        drawsBackground = true
        insertionPointColor = .black
        isRichText = false
        applyEditorFont(AppTheme.monoFont)
        typingAttributes[.foregroundColor] = NSColor.black

        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false

        NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: self)
    }

    /// Applies `newFont` and rebuilds the tab stops from *its* advance width.
    ///
    /// The two have to move together: the tab interval is a pixel distance
    /// derived from a character width, so setting `font` alone leaves every
    /// tab in the document measured against the previous font — a switch to a
    /// wider face makes a tab render as less than the four columns it was
    /// meant to be, and indentation stops lining up.
    func applyEditorFont(_ newFont: NSFont) {
        font = newFont

        let paragraphStyle = NSMutableParagraphStyle()
        let charWidth = ("m" as NSString).size(withAttributes: [.font: newFont]).width
        paragraphStyle.defaultTabInterval = charWidth * 4
        paragraphStyle.tabStops = []
        defaultParagraphStyle = paragraphStyle

        typingAttributes[.font] = newFont
        typingAttributes[.paragraphStyle] = paragraphStyle

        // `defaultParagraphStyle` only covers text laid down from here on;
        // text already in the storage carries the old style as an attribute.
        // This is an attribute-only edit, so the highlighter's delegate —
        // which acts on `.editedCharacters` — leaves the line index alone.
        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraphStyle,
                                 range: NSRange(location: 0, length: storage.length))
        }
    }

    // MARK: - Current line highlight

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return }

        let cursorPos = selectedRange().location
        let text = string as NSString
        guard text.length > 0, cursorPos <= text.length else { return }
        let lineRange = text.lineRange(for: NSRange(location: cursorPos, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return }
        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y

        AppTheme.currentLineBg.setFill()
        lineRect.fill()
    }

    // MARK: - Auto-indent

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let cursorPos = selectedRange().location
        guard cursorPos <= text.length else {
            super.insertNewline(sender)
            return
        }
        let lineRange = text.lineRange(for: NSRange(location: cursorPos, length: 0))
        let lineText = text.substring(with: lineRange)

        var indent = ""
        for ch in lineText {
            if ch == " " || ch == "\t" {
                indent.append(ch)
            } else {
                break
            }
        }
        insertText("\n" + indent, replacementRange: selectedRange())
    }


    // MARK: - Word wrap

    var wordWrapEnabled: Bool = true {
        didSet {
            guard let scrollView = enclosingScrollView else { return }
            if wordWrapEnabled {
                textContainer?.widthTracksTextView = true
                textContainer?.size = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                isHorizontallyResizable = false
                scrollView.hasHorizontalScroller = false
            } else {
                textContainer?.widthTracksTextView = false
                textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                isHorizontallyResizable = true
                scrollView.hasHorizontalScroller = true
            }
            needsDisplay = true
            needsLayout = true
        }
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        statusUpdateDelegate?.updateFromTextView(self)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: - Dirty tracking

    func markDirty() {
        guard let doc = tabDocument else { return }
        // Syntax caches are invalidated per-line by the text-storage delegate;
        // doing it wholesale here forced a full-document rescan per keystroke.

        // Recompute dirty state by comparing against savedContent so an
        // undo back to the on-disk state clears the dirty marker. Length
        // check is O(1) and short-circuits the O(n) full-string compare
        // when the user is typing forward.
        let cur = string as NSString
        let saved = doc.savedContent as NSString
        let isClean = cur.length == saved.length && string == doc.savedContent
        let shouldBeDirty = !isClean

        if doc.isDirty != shouldBeDirty {
            doc.isDirty = shouldBeDirty
            NotificationCenter.default.post(name: .editorDidChange, object: self)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        markDirty()
    }

    // MARK: - Navigation helpers

    /// Returns the 0-based line number at the current insertion point.
    func currentLineNumber() -> Int {
        let location = selectedRange().location
        if let doc = tabDocument, !doc.lineStartOffsets.isEmpty {
            return doc.lineIndex(forCharOffset: min(location, (string as NSString).length))
        }
        let content = string as NSString
        var line = 0
        var i = 0
        while i < location && i < content.length {
            if content.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }

    /// Scrolls to the given 1-based line number and places the cursor there.
    func scrollToLine(_ lineNumber: Int) {
        let content = string as NSString
        let targetStart: Int

        if let doc = tabDocument, !doc.lineStartOffsets.isEmpty {
            // O(1) via the line index. Past the last line, land on it rather
            // than on the very end of the document.
            let index = min(max(lineNumber - 1, 0), doc.lineStartOffsets.count - 1)
            targetStart = min(doc.lineStartOffsets[index], content.length)
        } else {
            var currentLine = 1
            var scan = 0
            for i in 0..<content.length {
                if currentLine == lineNumber {
                    scan = i
                    break
                }
                if content.character(at: i) == 0x0A {
                    currentLine += 1
                    if currentLine == lineNumber {
                        scan = i + 1
                        break
                    }
                }
            }
            targetStart = currentLine < lineNumber ? content.length : scan
        }

        setSelectedRange(NSRange(location: targetStart, length: 0))
        scrollRangeToVisible(NSRange(location: targetStart, length: 0))
    }
}

extension Notification.Name {
    static let editorDidChange = Notification.Name("editorDidChange")
}
