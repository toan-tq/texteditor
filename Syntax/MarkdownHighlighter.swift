import AppKit

/// Markdown-specific syntax highlighting.
///
/// Ported from Java SyntaxHighlighter.highlightMarkdownLine() and
/// highlightMarkdownInline(). Handles headings, bold, italic, code spans,
/// fenced code blocks, links, images, blockquotes, lists, strikethrough,
/// and horizontal rules.
///
/// Called by `SyntaxHighlighter` when the document language is `.markdown`.
enum MarkdownHighlighter {

    // MARK: - Public Entry Point

    /// Highlight markdown syntax in a range of the text storage.
    static func highlightRange(
        _ range: NSRange,
        in textStorage: NSTextStorage,
        document: TabDocument
    ) {
        let text = textStorage.string as NSString

        // The fenced code-block cache is refreshed by
        // `SyntaxHighlighter.refreshMultiLineCache` before this runs, so that
        // the lines whose state flipped are inside `range`.

        // Process line by line with incremental line index tracking.
        var lineIndex = document.lineIndex(forCharOffset: range.location)
        text.enumerateSubstrings(
            in: range,
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let line = text.substring(with: lineRange)
            let inCodeBlock: Bool
            if lineIndex < document.codeBlockLineStarts.count {
                inCodeBlock = document.codeBlockLineStarts[lineIndex]
            } else {
                inCodeBlock = false
            }
            highlightMarkdownLine(line, offset: lineRange.location,
                                  inCodeBlock: inCodeBlock, in: textStorage)
            lineIndex += 1
        }
    }

    // MARK: - Per-Line Dispatch (port of highlightMarkdownLine, lines 251-355)

    /// Classify the line and apply block-level styling, then delegate to
    /// `highlightMarkdownInline` for any inline markup. Uses UTF-16 length
    /// throughout because `offset` is in UTF-16 units and NSRange expects them.
    static func highlightMarkdownLine(
        _ line: String, offset: Int,
        inCodeBlock: Bool, in ts: NSTextStorage
    ) {
        let nsLine = line as NSString
        let len = nsLine.length
        guard len > 0 else { return }

        // Compute leading-whitespace length in UTF-16 units.
        var leading = 0
        while leading < len {
            let c = nsLine.character(at: leading)
            if c == 0x20 || c == 0x09 { leading += 1 } else { break }
        }
        var trailing = len
        while trailing > leading {
            let c = nsLine.character(at: trailing - 1)
            if c == 0x20 || c == 0x09 { trailing -= 1 } else { break }
        }
        let trimmedLen = trailing - leading
        guard trimmedLen > 0 else { return }
        let trimmed = nsLine.substring(with: NSRange(location: leading, length: trimmedLen))
        let trimmedNs = trimmed as NSString

        // --- Fenced code block delimiter: ``` ---
        if trimmedNs.hasPrefix("```") {
            applyColor(AppTheme.mdCodeColor,
                       range: NSRange(location: offset, length: len), in: ts)
            applyFont(AppTheme.monoFontBold,
                      range: NSRange(location: offset, length: len), in: ts)
            return
        }

        // --- Inside fenced code block ---
        if inCodeBlock {
            applyColor(AppTheme.mdCodeColor,
                       range: NSRange(location: offset, length: len), in: ts)
            return
        }

        // --- ATX headings: # through ###### ---
        if trimmedNs.character(at: 0) == 0x23 /* # */ {
            var level = 0
            while level < trimmedLen && level < 6 && trimmedNs.character(at: level) == 0x23 {
                level += 1
            }
            if level == trimmedLen || trimmedNs.character(at: level) == 0x20 {
                applyColor(AppTheme.mdHeadingColor,
                           range: NSRange(location: offset, length: len), in: ts)
                applyFont(AppTheme.monoFontBold,
                          range: NSRange(location: offset, length: len), in: ts)
                return
            }
        }

        // --- Blockquote: > text ---
        if trimmedNs.hasPrefix("> ") || trimmed == ">" {
            applyColor(AppTheme.mdQuoteColor,
                       range: NSRange(location: offset, length: len), in: ts)
            applyFont(AppTheme.monoFontItalic,
                      range: NSRange(location: offset, length: len), in: ts)
            return
        }

        // --- Horizontal rule: ---, ***, ___ (with optional spaces) ---
        if trimmedLen >= 3 {
            var allDash = true, allStar = true, allUnderscore = true, count = 0
            for k in 0..<trimmedLen {
                let c = trimmedNs.character(at: k)
                if c == 0x20 { continue }
                count += 1
                if c != 0x2D { allDash = false }
                if c != 0x2A { allStar = false }
                if c != 0x5F { allUnderscore = false }
                if !allDash && !allStar && !allUnderscore { break }
            }
            if count >= 3 && (allDash || allStar || allUnderscore) {
                applyColor(AppTheme.mdQuoteColor,
                           range: NSRange(location: offset, length: len), in: ts)
                return
            }
        }

        // --- Unordered list marker: -, *, + followed by a space ---
        if trimmedLen >= 2 {
            let first = trimmedNs.character(at: 0)
            if (first == 0x2D /* - */ || first == 0x2A /* * */ || first == 0x2B /* + */)
                && trimmedNs.character(at: 1) == 0x20 {
                let markerPos = leading
                applyColor(AppTheme.mdHeadingColor,
                           range: NSRange(location: offset + markerPos, length: 1), in: ts)
                applyFont(AppTheme.monoFontBold,
                          range: NSRange(location: offset + markerPos, length: 1), in: ts)
                highlightMarkdownInline(line, offset: offset, from: markerPos + 2, in: ts)
                return
            }
        }

        // --- Ordered list marker: 1. text ---
        let firstC = trimmedNs.character(at: 0)
        if firstC >= 0x30 && firstC <= 0x39 {
            // Scan digits then dot then space.
            var k = 0
            while k < trimmedLen {
                let c = trimmedNs.character(at: k)
                if c >= 0x30 && c <= 0x39 { k += 1 } else { break }
            }
            if k > 0 && k + 1 < trimmedLen
                && trimmedNs.character(at: k) == 0x2E /* . */
                && trimmedNs.character(at: k + 1) == 0x20 {
                applyColor(AppTheme.mdHeadingColor,
                           range: NSRange(location: offset + leading, length: k + 1), in: ts)
                applyFont(AppTheme.monoFontBold,
                          range: NSRange(location: offset + leading, length: k + 1), in: ts)
                highlightMarkdownInline(line, offset: offset,
                                        from: leading + k + 2, in: ts)
                return
            }
        }

        // --- Regular line -- scan for inline elements ---
        highlightMarkdownInline(line, offset: offset, from: 0, in: ts)
    }

    // MARK: - Inline Highlighting (port of highlightMarkdownInline, lines 358-451)

    /// Scan a line for inline markdown: `code`, **bold**, *italic*,
    /// [links](url), ![images](url), ~~strikethrough~~. All indices are
    /// UTF-16 code units, matching the `offset` passed in by the caller.
    static func highlightMarkdownInline(
        _ line: String, offset: Int, from startPos: Int,
        in ts: NSTextStorage
    ) {
        let nsLine = line as NSString
        let len = nsLine.length
        // Empty line — nothing to scan, and avoid handing &u of an empty
        // [unichar] buffer to NSString.getCharacters.
        guard len > 0, startPos < len else { return }
        // Snapshot UTF-16 units into a buffer once — repeated character(at:)
        // calls are slower than indexing an array.
        var u = [unichar](repeating: 0, count: len)
        nsLine.getCharacters(&u, range: NSRange(location: 0, length: len))
        var i = startPos

        while i < len {
            let c = u[i]

            // --- Inline code: `...` ---
            if c == 0x60 /* ` */ {
                var end = i + 1
                while end < len && u[end] != 0x60 { end += 1 }
                if end < len {
                    let range = NSRange(location: offset + i, length: end - i + 1)
                    applyColor(AppTheme.mdCodeColor, range: range, in: ts)
                    i = end + 1
                    continue
                }
            }

            // --- Strikethrough: ~~text~~ ---
            if c == 0x7E /* ~ */ && i + 1 < len && u[i + 1] == 0x7E {
                var end = i + 2
                while end + 1 < len {
                    if u[end] == 0x7E && u[end + 1] == 0x7E { break }
                    end += 1
                }
                if end + 1 < len {
                    let range = NSRange(location: offset + i, length: end + 2 - i)
                    applyColor(AppTheme.mdBoldColor, range: range, in: ts)
                    ts.safeAddAttribute(.strikethroughStyle,
                                        value: NSUnderlineStyle.single.rawValue, range: range)
                    i = end + 2
                    continue
                }
            }

            // --- Bold: **text** or __text__ ---
            if (c == 0x2A /* * */ || c == 0x5F /* _ */) && i + 1 < len && u[i + 1] == c {
                let marker = c
                var end = i + 2
                while end + 1 < len {
                    if u[end] == marker && u[end + 1] == marker { break }
                    end += 1
                }
                if end + 1 < len {
                    let range = NSRange(location: offset + i, length: end + 2 - i)
                    applyColor(AppTheme.mdBoldColor, range: range, in: ts)
                    applyFont(AppTheme.monoFontBold, range: range, in: ts)
                    i = end + 2
                    continue
                }
            }

            // --- Italic: *text* or _text_ (single marker, not followed by space) ---
            if (c == 0x2A || c == 0x5F)
                && i + 1 < len
                && u[i + 1] != c
                && u[i + 1] != 0x20 {
                let marker = c
                var end = i + 1
                while end < len && u[end] != marker { end += 1 }
                if end < len && end > i + 1 {
                    let range = NSRange(location: offset + i, length: end - i + 1)
                    applyColor(AppTheme.mdBoldColor, range: range, in: ts)
                    applyFont(AppTheme.monoFontItalic, range: range, in: ts)
                    i = end + 1
                    continue
                }
            }

            // --- Link: [text](url) or Image: ![alt](url) ---
            if c == 0x5B /* [ */ || (c == 0x21 /* ! */ && i + 1 < len && u[i + 1] == 0x5B) {
                let linkStart = i
                let bracketStart = (c == 0x21) ? i + 1 : i

                var bracketEnd = bracketStart + 1
                while bracketEnd < len && u[bracketEnd] != 0x5D /* ] */ { bracketEnd += 1 }

                if bracketEnd < len && bracketEnd + 1 < len && u[bracketEnd + 1] == 0x28 /* ( */ {
                    var parenEnd = bracketEnd + 2
                    while parenEnd < len && u[parenEnd] != 0x29 /* ) */ { parenEnd += 1 }

                    if parenEnd < len {
                        let textRange = NSRange(location: offset + linkStart,
                                                length: bracketEnd - linkStart + 1)
                        applyColor(AppTheme.mdLinkColor, range: textRange, in: ts)

                        let urlRange = NSRange(location: offset + bracketEnd + 1,
                                               length: parenEnd - bracketEnd)
                        applyColor(AppTheme.mdLinkColor, range: urlRange, in: ts)
                        ts.safeAddAttribute(.underlineStyle,
                                            value: NSUnderlineStyle.single.rawValue,
                                            range: urlRange)

                        i = parenEnd + 1
                        continue
                    }
                }
            }

            i += 1
        }
    }

    // MARK: - Helpers

    private static func applyColor(
        _ color: NSColor, range: NSRange, in ts: NSTextStorage
    ) {
        ts.safeAddAttribute(.foregroundColor, value: color, range: range)
    }

    private static func applyFont(
        _ font: NSFont, range: NSRange, in ts: NSTextStorage
    ) {
        ts.safeAddAttribute(.font, value: font, range: range)
    }

    private static func lineNumber(for charIndex: Int, in text: NSString) -> Int {
        text.lineNumber(at: charIndex)
    }
}
