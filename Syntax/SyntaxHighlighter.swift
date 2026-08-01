import AppKit

/// NSTextStorageDelegate that re-highlights syntax after every edit.
///
/// Ported from Java SyntaxHighlighter.highlightLine() and
/// TextEditor.applySyntaxHighlighting() including the block-comment cache.
class SyntaxHighlighter: NSObject, NSTextStorageDelegate {

    weak var tabDocument: TabDocument?

    /// Guard against re-entrant highlighting. When we add attributes inside
    /// `didProcessEditing`, NSTextStorage fires the delegate again with
    /// `.editedAttributes`; we must ignore that second call.
    private var isHighlighting = false

    /// Pending union of all line ranges that need re-highlighting on the next
    /// runloop tick. Multiple rapid edits (e.g. Replace All) accumulate here
    /// so all of them get highlighted, instead of the cancel-and-replace
    /// pattern which only kept the most recent edit.
    private var pendingDirtyRange: NSRange?
    private var highlightScheduled = false

    /// Upper bound, in characters, on how far past the edit a single pass will
    /// repaint lines whose multi-line state flipped. ~200 ms of restyling.
    private static let flippedRepaintBudget = 1_000_000

    // MARK: - NSTextStorageDelegate

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Only act when the user changed actual characters, not when we set attributes.
        guard editedMask.contains(.editedCharacters), !isHighlighting else { return }

        let text = textStorage.string as NSString

        // Update the line-start offsets cache immediately — it's read by line
        // navigation/cursor logic and only touches local state, not storage.
        // This also records exactly which lines need a multi-line rescan, so
        // the highlight pass below never has to invalidate the whole document.
        tabDocument?.updateLineStartOffsets(editedRange: editedRange, delta: delta, newText: text)

        // Defer the actual attribute rewrite to the next runloop tick. Doing it
        // synchronously inside didProcessEditing wipes the marked-text styling
        // NSTextView uses to track an in-progress IME composition (Vietnamese
        // Telex, Chinese Pinyin, Japanese Romaji, etc.), causing the IME to
        // drop the pending character. By the time the deferred block runs,
        // NSTextView has fully settled its IME state, so hasMarkedText() is
        // reliable — we re-check it there and skip if still composing.
        //
        // Multiple edits in the same tick (Replace All, paste with multiple
        // lines, batch insertions) accumulate into a union range so every
        // edited line gets re-highlighted, not just the last one.
        let lineRange = text.lineRange(for: editedRange)
        pendingDirtyRange = pendingDirtyRange.map { NSUnionRange($0, lineRange) } ?? lineRange

        if !highlightScheduled {
            highlightScheduled = true
            DispatchQueue.main.async { [weak self, weak textStorage] in
                guard let self = self, let ts = textStorage else { return }
                self.highlightScheduled = false
                guard let dirty = self.pendingDirtyRange else { return }
                self.pendingDirtyRange = nil
                if self.isComposingMarkedText(in: ts) {
                    // Re-queue: rerun once IME settles. Re-set the dirty range so
                    // the next didProcessEditing's union still includes this work.
                    self.pendingDirtyRange = dirty
                    return
                }
                let clamped = NSRange(
                    location: min(dirty.location, ts.length),
                    length: min(dirty.length, max(0, ts.length - dirty.location))
                )
                self.highlightRange(clamped, in: ts)
            }
        }
    }

    // MARK: - Public API

    /// Re-highlight the entire document (e.g. after opening a file or changing language).
    func highlightAll(in textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        highlightRange(fullRange, in: textStorage)
    }

    // MARK: - Core Dispatch

    private func highlightRange(_ range: NSRange, in textStorage: NSTextStorage) {
        guard range.length > 0 else { return }
        guard let doc = tabDocument else { return }
        let lang = doc.language

        // Bring the multi-line state cache in sync *before* anything reads it,
        // and repaint any line whose state flipped as well: typing "/*" changes
        // how every line below it reads, and those lines are outside the range
        // the edit itself touched.
        var effective = range
        if lang != .plain,
           let flipped = refreshMultiLineCache(in: textStorage, document: doc, language: lang) {
            // Capped: one keystroke can flip every line below it, and repainting
            // 5 MB of them costs ~0.9 s. The cache past the cap is already
            // correct, so those lines come out right the next time anything
            // re-highlights them — the same deal as before this repaint existed,
            // just bounded to the region around the caret instead of never.
            let capped = NSRange(location: flipped.location,
                                 length: min(flipped.length, SyntaxHighlighter.flippedRepaintBudget))
            effective = NSUnionRange(range, capped)
        }

        isHighlighting = true
        textStorage.beginEditing()

        // Reset the range to the default mono font + default foreground.
        textStorage.removeAttribute(.foregroundColor, range: effective)
        textStorage.removeAttribute(.font, range: effective)
        textStorage.addAttribute(.font, value: AppTheme.monoFont(size: AppTheme.fontSize), range: effective)

        if lang == .markdown {
            MarkdownHighlighter.highlightRange(effective, in: textStorage, document: doc)
            textStorage.endEditing()
            isHighlighting = false
            return
        }

        if lang == .plain {
            textStorage.endEditing()
            isHighlighting = false
            return
        }

        // Process line by line with incremental line index tracking.
        let text = textStorage.string as NSString
        var lineIndex = doc.lineIndex(forCharOffset: effective.location)
        text.enumerateSubstrings(
            in: effective,
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            self.highlightCodeLine(lineRange, lineIndex: lineIndex, in: textStorage, language: lang, document: doc)
            lineIndex += 1
        }

        textStorage.endEditing()
        isHighlighting = false
    }

    // MARK: - Per-Line Code Highlighting

    /// Port of Java SyntaxHighlighter.highlightLine() (lines 559-752).
    private func highlightCodeLine(
        _ lineRange: NSRange,
        lineIndex: Int,
        in ts: NSTextStorage,
        language lang: SyntaxLanguage,
        document doc: TabDocument
    ) {
        let text = ts.string as NSString
        let line = text.substring(with: lineRange)
        let offset = lineRange.location
        let to = (line as NSString).length

        let kw = lang.keywords
        let tp = lang.types
        let hashComment = lang.usesHashComments
        let cComment = lang.usesCStyleComments

        // Determine whether this line begins inside a multi-line construct.
        let inBlock: Bool
        if lineIndex < doc.blockCommentLineStarts.count {
            inBlock = doc.blockCommentLineStarts[lineIndex]
        } else {
            inBlock = false
        }

        // --- Handle continuation from a previous multi-line construct ---
        if inBlock {
            if lang.hasPythonTripleQuotes {
                highlightTripleQuoteContinuation(line, offset: offset, to: to, lang: lang,
                                                  kw: kw, tp: tp, hashComment: hashComment,
                                                  cComment: cComment, in: ts)
            } else {
                highlightBlockCommentContinuation(line, offset: offset, to: to, lang: lang,
                                                   kw: kw, tp: tp, hashComment: hashComment,
                                                   cComment: cComment, in: ts)
            }
            return
        }

        // Normal line -- tokenize from position 0.
        highlightCodeTokens(line, from: 0, to: to, offset: offset, lang: lang,
                            kw: kw, tp: tp, hashComment: hashComment, cComment: cComment, in: ts)
    }

    // MARK: - Multi-line Continuations

    /// The line starts inside a Python triple-quoted string.
    private func highlightTripleQuoteContinuation(
        _ line: String, offset: Int, to: Int,
        lang: SyntaxLanguage, kw: Set<String>, tp: Set<String>,
        hashComment: Bool, cComment: Bool,
        in ts: NSTextStorage
    ) {
        let nsLine = line as NSString
        let r1 = nsLine.range(of: "\"\"\"")
        let r2 = nsLine.range(of: "'''")
        let pos1 = r1.location != NSNotFound ? NSMaxRange(r1) : -1
        let pos2 = r2.location != NSNotFound ? NSMaxRange(r2) : -1

        var bestEnd = -1
        if pos1 > 0 { bestEnd = pos1 }
        if pos2 > 0 && (bestEnd < 0 || pos2 < bestEnd) { bestEnd = pos2 }

        if bestEnd > 0 {
            applyStyle(.foregroundColor, value: AppTheme.stringColor,
                       range: NSRange(location: offset, length: bestEnd), in: ts)
            highlightCodeTokens(line, from: bestEnd, to: to, offset: offset, lang: lang,
                                kw: kw, tp: tp, hashComment: hashComment, cComment: cComment, in: ts)
        } else {
            // Entire line is still inside the triple-quoted string.
            applyStyle(.foregroundColor, value: AppTheme.stringColor,
                       range: NSRange(location: offset, length: to), in: ts)
        }
    }

    /// The line starts inside a C-family block comment (`/* ... */`).
    private func highlightBlockCommentContinuation(
        _ line: String, offset: Int, to: Int,
        lang: SyntaxLanguage, kw: Set<String>, tp: Set<String>,
        hashComment: Bool, cComment: Bool,
        in ts: NSTextStorage
    ) {
        let closeRange = (line as NSString).range(of: "*/")
        if closeRange.location != NSNotFound {
            let endPos = NSMaxRange(closeRange)
            applyStyle(.foregroundColor, value: AppTheme.commentColor,
                       range: NSRange(location: offset, length: endPos), in: ts)
            applyStyle(.font, value: AppTheme.monoFontItalic,
                       range: NSRange(location: offset, length: endPos), in: ts)
            highlightCodeTokens(line, from: endPos, to: to, offset: offset, lang: lang,
                                kw: kw, tp: tp, hashComment: hashComment, cComment: cComment, in: ts)
        } else {
            // Entire line is still inside the block comment.
            applyStyle(.foregroundColor, value: AppTheme.commentColor,
                       range: NSRange(location: offset, length: to), in: ts)
            applyStyle(.font, value: AppTheme.monoFontItalic,
                       range: NSRange(location: offset, length: to), in: ts)
        }
    }

    // MARK: - Token Scanner

    /// Tokenize and highlight a line segment.
    /// Port of Java highlightLine() token loop (lines 567-751).
    private func highlightCodeTokens(
        _ line: String, from: Int, to: Int, offset: Int,
        lang: SyntaxLanguage, kw: Set<String>, tp: Set<String>,
        hashComment: Bool, cComment: Bool,
        in ts: NSTextStorage
    ) {
        guard to > from else { return }
        let nsLine = line as NSString
        let u = Array(line.utf16)
        var i = from

        while i < to {
            let c = u[i]

            // --- Hash comment: # to end of line (Python, Bash) ---
            if hashComment && c == 0x23 /* # */ {
                let len = to - i
                applyStyle(.foregroundColor, value: AppTheme.commentColor,
                           range: NSRange(location: offset + i, length: len), in: ts)
                applyStyle(.font, value: AppTheme.monoFontItalic,
                           range: NSRange(location: offset + i, length: len), in: ts)
                return
            }

            // --- C-style block comment: /* ... */ ---
            if cComment && c == 0x2F /* / */ && i + 1 < to && u[i + 1] == 0x2A /* * */ {
                let start = i
                i += 2
                while i + 1 < to {
                    if u[i] == 0x2A && u[i + 1] == 0x2F { break }
                    i += 1
                }
                if i + 1 < to { i += 2 } else { i = to }
                let len = i - start
                applyStyle(.foregroundColor, value: AppTheme.commentColor,
                           range: NSRange(location: offset + start, length: len), in: ts)
                applyStyle(.font, value: AppTheme.monoFontItalic,
                           range: NSRange(location: offset + start, length: len), in: ts)
                continue
            }

            // --- C-style line comment: // to end ---
            if cComment && c == 0x2F && i + 1 < to && u[i + 1] == 0x2F {
                let len = to - i
                applyStyle(.foregroundColor, value: AppTheme.commentColor,
                           range: NSRange(location: offset + i, length: len), in: ts)
                applyStyle(.font, value: AppTheme.monoFontItalic,
                           range: NSRange(location: offset + i, length: len), in: ts)
                return
            }

            // --- Python triple-quoted string: """ or ''' ---
            if lang == .python && (c == 0x22 || c == 0x27) /* " or ' */
                && i + 2 < to && u[i + 1] == c && u[i + 2] == c {
                let start = i
                let quoteChar = c
                i += 3
                var found = false
                while i + 2 < to {
                    if u[i] == quoteChar && u[i + 1] == quoteChar && u[i + 2] == quoteChar {
                        i += 3
                        found = true
                        break
                    }
                    if u[i] == 0x5C /* \ */ { i += 1 }
                    i += 1
                }
                if !found { i = to }
                applyStyle(.foregroundColor, value: AppTheme.stringColor,
                           range: NSRange(location: offset + start, length: i - start), in: ts)
                continue
            }

            // --- Go raw string literal: `...` ---
            if lang == .go && c == 0x60 /* ` */ {
                let start = i
                i += 1
                while i < to && u[i] != 0x60 { i += 1 }
                if i < to { i += 1 }
                applyStyle(.foregroundColor, value: AppTheme.stringColor,
                           range: NSRange(location: offset + start, length: i - start), in: ts)
                continue
            }

            // --- Bash variable: $VAR, ${VAR}, $(...) ---
            if lang == .bash && c == 0x24 /* $ */ && i + 1 < to {
                let start = i
                i += 1
                if u[i] == 0x7B /* { */ {
                    while i < to && u[i] != 0x7D /* } */ { i += 1 }
                    if i < to { i += 1 }
                } else if u[i] == 0x28 /* ( */ {
                    i += 1
                } else if isIdentCharU16(u[i]) {
                    while i < to && isIdentCharU16(u[i]) { i += 1 }
                } else {
                    i += 1
                }
                applyStyle(.foregroundColor, value: AppTheme.preprocColor,
                           range: NSRange(location: offset + start, length: i - start), in: ts)
                continue
            }

            // --- Python decorator: @name ---
            if lang == .python && c == 0x40 /* @ */ {
                if u[0..<i].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    let start = i
                    i += 1
                    while i < to && isIdentCharOrDotU16(u[i]) { i += 1 }
                    applyStyle(.foregroundColor, value: AppTheme.preprocColor,
                               range: NSRange(location: offset + start, length: i - start), in: ts)
                    continue
                }
            }

            // --- C preprocessor: #include, #define, etc. ---
            if (lang == .cCpp) && c == 0x23 /* # */ {
                if u[0..<i].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    let start = i
                    i += 1
                    while i < to && isIdentCharU16(u[i]) { i += 1 }
                    applyStyle(.foregroundColor, value: AppTheme.preprocColor,
                               range: NSRange(location: offset + start, length: i - start), in: ts)
                    continue
                }
            }

            // --- String or char literal ---
            if c == 0x22 || c == 0x27 /* " or ' */ {
                let start = i
                let quote = c
                i += 1
                while i < to && u[i] != quote {
                    if u[i] == 0x5C /* \ */ && !(lang == .bash && quote == 0x27) && i + 1 < to {
                        i += 1
                    }
                    i += 1
                }
                if i < to { i += 1 }
                applyStyle(.foregroundColor, value: AppTheme.stringColor,
                           range: NSRange(location: offset + start, length: i - start), in: ts)
                continue
            }

            // --- Number literal ---
            if isDigitU16(c) || (c == 0x2E /* . */ && i + 1 < to && isDigitU16(u[i + 1])) {
                let start = i
                if c == 0x30 && i + 1 < to && (u[i + 1] == 0x78 || u[i + 1] == 0x58) /* 0x 0X */ {
                    i += 2
                    while i < to && isHexDigitOrSuffixU16(u[i]) { i += 1 }
                } else {
                    while i < to && isNumberContinuationU16(u[i]) { i += 1 }
                }
                applyStyle(.foregroundColor, value: AppTheme.numberColor,
                           range: NSRange(location: offset + start, length: i - start), in: ts)
                continue
            }

            // --- Identifier / keyword / type ---
            if isAlphaOrUnderscoreU16(c) {
                let start = i
                while i < to && isIdentCharU16(u[i]) { i += 1 }
                let word = nsLine.substring(with: NSRange(location: start, length: i - start))

                if kw.contains(word) {
                    applyStyle(.foregroundColor, value: AppTheme.kwColor,
                               range: NSRange(location: offset + start, length: i - start), in: ts)
                    applyStyle(.font, value: AppTheme.monoFontBold,
                               range: NSRange(location: offset + start, length: i - start), in: ts)
                } else if tp.contains(word) {
                    applyStyle(.foregroundColor, value: AppTheme.typeColor,
                               range: NSRange(location: offset + start, length: i - start), in: ts)
                }
                continue
            }

            i += 1
        }
    }

    // MARK: - Multi-line State Cache

    /// Brings the per-line multi-line-construct cache in sync with the text and
    /// returns the character range whose cached state actually *changed*, so the
    /// caller can repaint those lines too. Returns `nil` when nothing moved.
    ///
    /// Only the pending dirty window is rescanned. The scan enters at the first
    /// dirty line — whose own entry is still valid, since no text before it
    /// moved — and stops as soon as the state it computes matches what the cache
    /// already holds for a line past the edit. This is what replaced the
    /// full-document rescan that used to run on every keystroke (~50 ms per 5 MB
    /// of text, on the main thread).
    @discardableResult
    func refreshMultiLineCache(in ts: NSTextStorage,
                               document doc: TabDocument,
                               language lang: SyntaxLanguage) -> NSRange? {
        guard let dirty = doc.syntaxDirtyLines else { return nil }
        doc.clearSyntaxDirty()

        let starts = doc.lineStartOffsets
        let lineCount = starts.count
        guard lineCount > 0 else { return nil }

        let usesFences = (lang == .markdown)
        let usesTriple = lang.hasPythonTripleQuotes
        guard usesFences || usesTriple || lang.hasBlockComments else {
            // No multi-line constructs: a right-sized all-false cache is all the
            // per-line lookup needs.
            if doc.blockCommentLineStarts.count != lineCount {
                doc.blockCommentLineStarts = Array(repeating: false, count: lineCount)
            }
            return nil
        }

        var cache = usesFences ? doc.codeBlockLineStarts : doc.blockCommentLineStarts
        var startLine = min(max(dirty.from, 0), lineCount - 1)
        var rewriteThrough = min(dirty.through, lineCount - 1)

        // A cache that no longer matches the line topology can't be trusted
        // anywhere — start over rather than splice around the mismatch. The
        // rewrite window has to open all the way up with it: an all-false cache
        // "re-converges" on the first line outside a block, and a narrow window
        // would let the scan break there and leave the rest false.
        if cache.count != lineCount {
            cache = Array(repeating: false, count: lineCount)
            startLine = 0
            rewriteThrough = lineCount - 1
        }

        let text = ts.string as NSString
        let changed: ClosedRange<Int>?
        if usesFences {
            changed = SyntaxHighlighter.rescanFences(in: text, starts: starts, cache: &cache,
                                                     from: startLine, rewriteThrough: rewriteThrough)
        } else if usesTriple {
            changed = SyntaxHighlighter.rescanTripleQuotes(in: text, starts: starts, cache: &cache,
                                                           from: startLine, rewriteThrough: rewriteThrough)
        } else {
            changed = SyntaxHighlighter.rescanBlockComments(in: text, starts: starts, cache: &cache,
                                                            from: startLine, rewriteThrough: rewriteThrough)
        }

        if usesFences {
            doc.codeBlockLineStarts = cache
        } else {
            doc.blockCommentLineStarts = cache
        }

        guard let flipped = changed else { return nil }
        // Clamped like the scanners do: a line index that has drifted from the
        // text should degrade to a shorter repaint, not raise from
        // `removeAttribute` on an out-of-bounds range.
        let from = min(starts[flipped.lowerBound], text.length)
        let to = flipped.upperBound + 1 < starts.count
            ? min(starts[flipped.upperBound + 1], text.length)
            : text.length
        guard to > from else { return nil }
        return NSRange(location: from, length: to - from)
    }

    /// C-family `/* ... */` tracking. Iterates UTF-16 units so line indices
    /// align with `lineStartOffsets` (also UTF-16 based).
    static func rescanBlockComments(in text: NSString, starts: [Int], cache: inout [Bool],
                                    from startLine: Int, rewriteThrough: Int) -> ClosedRange<Int>? {
        if startLine == 0 { cache[0] = false }
        let n = text.length
        var inBlock = cache[startLine]
        var lineIdx = startLine
        var i = min(starts[startLine], n)
        var first: Int?, last: Int?

        while i < n {
            let c = text.character(at: i)

            if c == 0x0A /* \n */ {
                i += 1
                lineIdx += 1
                if lineIdx >= cache.count { break }
                if cache[lineIdx] != inBlock {
                    cache[lineIdx] = inBlock
                    if first == nil { first = lineIdx }
                    last = lineIdx
                } else if lineIdx > rewriteThrough {
                    break  // state re-converged — everything below is already right
                }
                continue
            }

            if !inBlock {
                // Skip over string literals so that /* inside a string is ignored.
                if c == 0x22 /* " */ || c == 0x27 /* ' */ {
                    let q = c
                    i += 1
                    while i < n && text.character(at: i) != q {
                        let ch = text.character(at: i)
                        if ch == 0x5C /* \ */ && i + 1 < n { i += 1 }
                        if ch == 0x0A { break }  // unterminated string
                        i += 1
                    }
                    if i < n && text.character(at: i) == q { i += 1 }
                    continue
                }
                if c == 0x2F /* / */ && i + 1 < n {
                    let next = text.character(at: i + 1)
                    if next == 0x2F {
                        // Line comment -- skip to newline.
                        while i < n && text.character(at: i) != 0x0A { i += 1 }
                        continue
                    }
                    if next == 0x2A /* * */ {
                        inBlock = true
                        i += 2
                        continue
                    }
                }
            } else {
                if c == 0x2A && i + 1 < n && text.character(at: i + 1) == 0x2F {
                    inBlock = false
                    i += 2
                    continue
                }
            }
            i += 1
        }

        guard let lo = first, let hi = last else { return nil }
        return lo...hi
    }

    /// Python `"""` / `'''` tracking.
    ///
    /// The cache stores one bool per line and so cannot say *which* quote style
    /// opened an unterminated string. Both ends of the scan account for that:
    /// it backs up to the nearest line known to be outside a string before
    /// starting, and it only accepts convergence outside one. Resuming in the
    /// middle would guess the closing delimiter and run past the real one.
    static func rescanTripleQuotes(in text: NSString, starts: [Int], cache: inout [Bool],
                                   from dirtyLine: Int, rewriteThrough: Int) -> ClosedRange<Int>? {
        if dirtyLine == 0 { cache[0] = false }
        var startLine = dirtyLine
        while startLine > 0 && cache[startLine] { startLine -= 1 }

        let n = text.length
        var inTriple = cache[startLine]
        var tripleChar: unichar = 0x22
        var lineIdx = startLine
        var i = min(starts[startLine], n)
        var first: Int?, last: Int?

        while i < n {
            let c = text.character(at: i)

            if c == 0x0A {
                i += 1
                lineIdx += 1
                if lineIdx >= cache.count { break }
                if cache[lineIdx] != inTriple {
                    cache[lineIdx] = inTriple
                    if first == nil { first = lineIdx }
                    last = lineIdx
                } else if lineIdx > rewriteThrough && !inTriple {
                    break
                }
                continue
            }

            if !inTriple {
                if c == 0x23 /* # */ {
                    while i < n && text.character(at: i) != 0x0A { i += 1 }
                    continue
                }
                if (c == 0x22 || c == 0x27)
                    && i + 2 < n
                    && text.character(at: i + 1) == c
                    && text.character(at: i + 2) == c {
                    inTriple = true
                    tripleChar = c
                    i += 3
                    continue
                }
                if c == 0x22 || c == 0x27 {
                    let q = c
                    i += 1
                    while i < n {
                        let ch = text.character(at: i)
                        if ch == q || ch == 0x0A { break }
                        if ch == 0x5C { i += 1 }
                        i += 1
                    }
                    if i < n && text.character(at: i) == q { i += 1 }
                    continue
                }
            } else {
                if c == tripleChar
                    && i + 2 < n
                    && text.character(at: i + 1) == tripleChar
                    && text.character(at: i + 2) == tripleChar {
                    inTriple = false
                    i += 3
                    continue
                }
            }
            i += 1
        }

        guard let lo = first, let hi = last else { return nil }
        return lo...hi
    }

    /// Markdown fenced code blocks. `cache[i]` is the state *entering* line i,
    /// so an opening fence line itself is not marked as inside the block.
    /// Convergence is only accepted outside a fence, for the same reason as
    /// triple quotes: the fence delimiter is not part of the cached state.
    static func rescanFences(in text: NSString, starts: [Int], cache: inout [Bool],
                             from startLine: Int, rewriteThrough: Int) -> ClosedRange<Int>? {
        if startLine == 0 { cache[0] = false }
        let n = text.length
        var inBlock = cache[startLine]
        var line = startLine
        var first: Int?, last: Int?

        while line < cache.count {
            let lineStart = min(starts[line], n)
            let lineEnd = line + 1 < starts.count ? min(starts[line + 1], n) : n

            var j = lineStart
            while j < lineEnd, text.character(at: j) == 0x20 || text.character(at: j) == 0x09 { j += 1 }
            if j + 3 <= lineEnd,
               text.character(at: j) == 0x60,
               text.character(at: j + 1) == 0x60,
               text.character(at: j + 2) == 0x60 {
                inBlock.toggle()
            }

            let next = line + 1
            if next >= cache.count { break }
            if cache[next] != inBlock {
                cache[next] = inBlock
                if first == nil { first = next }
                last = next
            } else if next > rewriteThrough && !inBlock {
                break
            }
            line = next
        }

        guard let lo = first, let hi = last else { return nil }
        return lo...hi
    }

    // MARK: - Helpers

    private func isComposingMarkedText(in textStorage: NSTextStorage) -> Bool {
        for lm in textStorage.layoutManagers {
            for tc in lm.textContainers {
                if tc.textView?.hasMarkedText() == true { return true }
            }
        }
        return false
    }

    private func applyStyle(
        _ key: NSAttributedString.Key, value: Any,
        range: NSRange, in ts: NSTextStorage
    ) {
        ts.safeAddAttribute(key, value: value, range: range)
    }

    private func lineNumber(for charIndex: Int, in text: NSString) -> Int {
        text.lineNumber(at: charIndex)
    }

    // MARK: - UTF-16 Character Classification Helpers

    private func isDigitU16(_ c: unichar) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private func isHexCharU16(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
    }

    private func isHexDigitOrSuffixU16(_ c: unichar) -> Bool {
        isHexCharU16(c) || c == 0x5F || c == 0x4C || c == 0x6C || c == 0x75 || c == 0x55
    }

    private func isNumberContinuationU16(_ c: unichar) -> Bool {
        isDigitU16(c) || c == 0x2E || c == 0x66 || c == 0x46
            || c == 0x78 || c == 0x58
            || isHexCharU16(c)
            || c == 0x4C || c == 0x6C || c == 0x5F
            || c == 0x65 || c == 0x45
    }

    private func isAlphaOrUnderscoreU16(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }

    private func isIdentCharU16(_ c: unichar) -> Bool {
        isAlphaOrUnderscoreU16(c) || (c >= 0x30 && c <= 0x39)
    }

    private func isIdentCharOrDotU16(_ c: unichar) -> Bool {
        isIdentCharU16(c) || c == 0x2E
    }
}
