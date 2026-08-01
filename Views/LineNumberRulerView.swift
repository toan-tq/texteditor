import AppKit

class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init?(textView: NSTextView) {
        self.textView = textView
        guard let scrollView = textView.enclosingScrollView else { return nil }
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 40

        NotificationCenter.default.addObserver(self, selector: #selector(needsRedraw(_:)),
                                               name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(needsRedraw(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func needsRedraw(_ notification: Notification) {
        needsDisplay = true
        updateThickness()
    }

    private var lastDigitCount: Int = 0

    /// Call after the editor font changes: thickness is memoized on the digit
    /// count, which doesn't move when only the font does, so the cache has to
    /// be dropped or the gutter keeps the old font's width.
    func fontDidChange() {
        lastDigitCount = 0
        updateThickness()
        needsDisplay = true
    }

    private func updateThickness() {
        guard let textView = textView else { return }
        let lineCount = (textView as? EditorView)?.tabDocument?.lineStartOffsets.count
            ?? (textView.string as NSString).lineCount
        let digits = max(String(lineCount).count, 3)
        guard digits != lastDigitCount else { return }
        lastDigitCount = digits
        let digitWidth = ("9" as NSString).size(withAttributes: [.font: AppTheme.monoFont(size: AppTheme.fontSize)]).width
        let newThickness = CGFloat(digits) * digitWidth + 16
        if abs(ruleThickness - newThickness) > 1 {
            ruleThickness = newThickness
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        // Only fill within our own bounds, clipped to the dirty rect
        let fillRect = bounds.intersection(rect)
        AppTheme.lineNumBg.setFill()
        fillRect.fill()

        let text = textView.string as NSString
        guard text.length > 0 else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let editorView = textView as? EditorView
        let doc = editorView?.tabDocument
        let cursorLocation = textView.selectedRange().location
        let currentLine = doc?.lineIndex(forCharOffset: min(cursorLocation, text.length))
            ?? lineNumber(for: min(cursorLocation, text.length), in: text)
        let bookmarks: Set<Int> = doc?.bookmarks ?? []

        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppTheme.monoFont(size: AppTheme.fontSize),
            .foregroundColor: AppTheme.lineNumFg
        ]

        var lineIndex = doc?.lineIndex(forCharOffset: charRange.location)
            ?? lineNumber(for: charRange.location, in: text)
        var charIndex = lineStart(for: charRange.location, in: text)

        while charIndex <= text.length {
            let lineRange: NSRange
            if charIndex < text.length {
                lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            } else {
                lineRange = NSRange(location: charIndex, length: 0)
            }

            // Geometry comes from the line's own fragments, never from
            // `boundingRect` over the whole range: once that range reaches the
            // end of the document it pulls in the layout manager's extra
            // fragment — the empty line after the final newline — and returns a
            // rect a row too tall, which centred the number half a row low and
            // straight on top of the next one.
            //
            // `first` is where the number goes: a wrapped line spans several
            // fragments and the number belongs beside its first visual row, not
            // in the middle of the block. `lineRect` is the whole block, so the
            // current-line and bookmark highlights still cover a wrapped line
            // the same way the editor's own highlight does.
            let first: NSRect
            let lineRect: NSRect
            if lineRange.length == 0 {
                // The empty last line has no glyphs of its own. It exists only
                // when the file ends in a newline; without one there is no
                // further line to number.
                guard layoutManager.extraLineFragmentTextContainer != nil else { break }
                first = layoutManager.extraLineFragmentRect
                lineRect = first
            } else {
                let firstGlyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
                let lastGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(lineRange) - 1)
                first = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
                lineRect = first.union(
                    layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil))
            }

            // Convert from textView coordinates to ruler coordinates
            let offsetY = textView.textContainerOrigin.y - visibleRect.origin.y
            let numberRect = NSRect(x: first.origin.x, y: first.origin.y + offsetY,
                                    width: first.width, height: first.height)
            let highlightRect = NSRect(x: lineRect.origin.x, y: lineRect.origin.y + offsetY,
                                       width: lineRect.width, height: lineRect.height)

            if highlightRect.origin.y > bounds.height { break }

            // Highlight bookmarked or current line
            if bookmarks.contains(lineIndex) {
                AppTheme.bookmarkBg.setFill()
                NSRect(x: 0, y: highlightRect.origin.y, width: bounds.width - 1, height: highlightRect.height).fill()
            } else if lineIndex == currentLine {
                AppTheme.currentLineBg.setFill()
                NSRect(x: 0, y: highlightRect.origin.y, width: bounds.width - 1, height: highlightRect.height).fill()
            }

            let numStr = "\(lineIndex + 1)" as NSString
            let strSize = numStr.size(withAttributes: attributes)
            let x = bounds.width - strSize.width - 8
            let y = numberRect.origin.y + (numberRect.height - strSize.height) / 2
            numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)

            if lineRange.length == 0 { break }
            charIndex = NSMaxRange(lineRange)
            lineIndex += 1
        }

        // Right border
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.width - 0.5, y: fillRect.minY))
        path.line(to: NSPoint(x: bounds.width - 0.5, y: fillRect.maxY))
        path.stroke()
    }

    private func lineNumber(for charIndex: Int, in text: NSString) -> Int {
        text.lineNumber(at: charIndex)
    }

    private func lineStart(for charIndex: Int, in text: NSString) -> Int {
        var i = charIndex
        while i > 0 && text.character(at: i - 1) != 10 { i -= 1 }
        return i
    }
}
