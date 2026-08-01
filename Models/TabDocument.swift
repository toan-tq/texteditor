import AppKit

/// Per-tab document state. Replaces the Java `TabData` inner class.
///
/// NSTextView provides its own NSUndoManager, so no custom undo stack is needed.
class TabDocument {

    /// URL of the file on disk, or `nil` for an untitled buffer.
    var fileURL: URL?

    /// Whether the buffer has unsaved modifications.
    var isDirty: Bool = false

    /// Snapshot of the last-saved content, used to detect dirty state after undo/redo.
    var savedContent: String = ""

    /// Set of bookmarked line indices (0-based).
    var bookmarks: Set<Int> = []

    /// Detected (or manually set) syntax language for highlighting.
    var language: SyntaxLanguage = .plain

    /// Whether soft word-wrap is enabled for this tab.
    var wordWrap: Bool = true

    /// Original on-disk line ending — preserved across save so we don't
    /// silently convert a CRLF file to LF (or vice versa). Defaults to LF
    /// for new untitled buffers.
    var lineEnding: FileService.LineEnding = .lf

    /// Original on-disk encoding and byte-order mark, preserved across save
    /// for the same reason as `lineEnding`: a file opened as UTF-16 should
    /// not come back as UTF-8. New untitled buffers get UTF-8 without a BOM.
    var encoding: FileService.TextEncoding = .utf8
    var hasBOM: Bool = false

    /// What the file looked like on disk when we last read or wrote it, used
    /// to spot another program editing it underneath us. `nil` for a buffer
    /// that has never touched disk.
    var diskState: FileService.DiskState?

    /// How the file on disk stopped agreeing with this tab. Only ever set for
    /// a buffer with unsaved edits — a clean tab is reloaded outright instead,
    /// since there is nothing of the user's to lose.
    enum ExternalChange {
        /// Another program wrote the file.
        case modified
        /// The file is no longer there. The buffer is now the only copy, so it
        /// is treated as unsaved rather than emptied.
        case deleted
    }

    /// Pending external change awaiting the user's decision, or `nil`.
    var externalChange: ExternalChange?

    /// What the user has already been shown and dismissed. Without it the
    /// banner comes back on every app switch, because dismissing it doesn't
    /// make the file on disk match the buffer again — and it must not, since
    /// the save-time overwrite warning reads the same state.
    enum AcknowledgedChange: Equatable {
        case missing
        case state(FileService.DiskState)
    }

    var acknowledgedChange: AcknowledgedChange?

    // MARK: - Line Index Cache

    /// Sorted array of character offsets where each line starts.
    /// `lineStartOffsets[i]` is the UTF-16 offset of the start of line `i`.
    /// Line 0 always starts at offset 0.
    var lineStartOffsets: [Int] = [0]

    func rebuildLineIndex(from text: String) {
        rebuildLineIndex(from: text as NSString)
    }

    /// Rebuilds the line index from a whole document, discarding every
    /// line-indexed cache with it — they describe a document that no longer
    /// exists. Called when the buffer is replaced outright (file open, reload).
    func rebuildLineIndex(from ns: NSString) {
        var offsets = [0]
        offsets.reserveCapacity(ns.length / 40) // rough estimate
        for i in 0..<ns.length {
            if ns.character(at: i) == 0x0A {
                offsets.append(i + 1)
            }
        }
        lineStartOffsets = offsets
        blockCommentLineStarts = []
        codeBlockLineStarts = []
        markSyntaxDirtyAll()
    }

    /// Update lineStartOffsets incrementally after an edit.
    /// - Parameters:
    ///   - editedRange: The range in the NEW (post-edit) string that was affected.
    ///   - delta: The change in total length (positive = insertion, negative = deletion).
    ///   - newText: The full post-edit NSString (for scanning newlines in the edited region).
    func updateLineStartOffsets(editedRange: NSRange, delta: Int, newText: NSString) {
        // Defensive clamps — NSTextStorage normally guarantees in-bounds ranges,
        // but mis-routed callers (e.g. tests, storage swap) could pass garbage.
        let editStart = max(0, min(editedRange.location, newText.length))
        let editEnd = max(editStart, min(NSMaxRange(editedRange), newText.length))

        // A whole-document swap (opening a file, reloading one) leaves nothing
        // of the old index to splice against — and splicing anyway is what used
        // to double the line count on every file open. Rebuild instead.
        if editStart == 0 && editEnd >= newText.length {
            rebuildLineIndex(from: newText)
            bookmarks.removeAll()
            return
        }

        // Find which line the edit starts in (binary search).
        let editLineIdx = lineIndex(forCharOffset: editStart)

        // The pre-edit end was at editEnd - delta.
        let preEditEnd = editEnd - delta

        // Find the first line AFTER the pre-edit end to know how many old lines to remove.
        var removeEnd = editLineIdx + 1
        while removeEnd < lineStartOffsets.count && lineStartOffsets[removeEnd] <= preEditEnd {
            removeEnd += 1
        }

        // Collect new line starts within the edited range.
        var newLineStarts: [Int] = []
        for i in editStart..<editEnd {
            if newText.character(at: i) == 0x0A {
                newLineStarts.append(i + 1)
            }
        }

        // Which old lines the edit consumed *whole* — the only ones that stop
        // existing. A line whose head or tail survives keeps its bookmark, even
        // though its start offset may move.
        let firstDestroyed = lineStartOffsets[editLineIdx] == editStart ? editLineIdx : editLineIdx + 1
        let destroyedLines = firstDestroyed..<max(firstDestroyed, removeEnd - 1)

        // Splice: remove old entries, insert new ones.
        let replaceRange = (editLineIdx + 1)..<removeEnd
        let removedLines = replaceRange.count
        let insertedLines = newLineStarts.count
        lineStartOffsets.replaceSubrange(replaceRange, with: newLineStarts)

        // Shift all entries after the edit by delta.
        let shiftStart = editLineIdx + 1 + newLineStarts.count
        if delta != 0 && shiftStart < lineStartOffsets.count {
            for i in shiftStart..<lineStartOffsets.count {
                lineStartOffsets[i] += delta
            }
        }

        // Everything else keyed by line index has to move with it.
        spliceLineIndexedState(afterLine: editLineIdx,
                               removed: removedLines,
                               inserted: insertedLines,
                               destroyedLines: destroyedLines)

        // A window left pending by an earlier edit in this same runloop is keyed
        // to the line numbering from before this edit. Rebase it first, or an
        // edit that inserts lines above it leaves the highlighter rescanning
        // line numbers whose content has since moved further down.
        rebaseSyntaxDirty(afterLine: editLineIdx, shift: insertedLines - removedLines)

        // The edit can only change multi-line state from its own line onward,
        // and only the lines it physically touched hold untrustworthy values.
        markSyntaxDirty(from: editLineIdx, through: editLineIdx + insertedLines)
    }

    /// Keeps the per-line caches and the bookmark set aligned with the line
    /// index after an edit replaced `removed` lines with `inserted` ones
    /// directly below `line`.
    private func spliceLineIndexedState(afterLine line: Int, removed: Int, inserted: Int,
                                        destroyedLines: Range<Int>) {
        guard removed != 0 || inserted != 0 else { return }

        TabDocument.spliceFlags(&blockCommentLineStarts, first: line + 1, removed: removed, inserted: inserted)
        TabDocument.spliceFlags(&codeBlockLineStarts, first: line + 1, removed: removed, inserted: inserted)

        guard !bookmarks.isEmpty else { return }
        let shift = inserted - removed
        var moved = Set<Int>()
        moved.reserveCapacity(bookmarks.count)
        for mark in bookmarks {
            if mark < destroyedLines.lowerBound {
                moved.insert(mark)                  // entirely above the edit
            } else if mark < destroyedLines.upperBound {
                continue                            // the line itself is gone
            } else {
                moved.insert(mark + shift)          // pushed down or pulled up
            }
        }
        bookmarks = moved
    }

    /// Splices a per-line flag array in place. Inserted lines get `false` and
    /// are covered by the pending rescan window, which rewrites them before
    /// anything reads them.
    private static func spliceFlags(_ flags: inout [Bool], first: Int, removed: Int, inserted: Int) {
        guard !flags.isEmpty, first <= flags.count else { return }
        let end = min(first + removed, flags.count)
        flags.replaceSubrange(first..<end, with: repeatElement(false, count: inserted))
    }

    /// Returns the 0-based line index for the given character offset. O(log n).
    /// Always returns a valid index (>= 0) since `lineStartOffsets` is invariant
    /// non-empty starting with `[0]`. Defensive `max(0, ...)` guards against
    /// callers using the result as an array index even if invariants are
    /// momentarily violated (e.g. during construction).
    func lineIndex(forCharOffset offset: Int) -> Int {
        var lo = 0, hi = lineStartOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStartOffsets[mid] <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return max(0, lo - 1)
    }

    // MARK: - Multi-line Syntax Caches

    /// Per-line flag: `true` if the line starts inside a block comment
    /// (`/* ... */`) or a Python triple-quoted string. Refreshed lazily over
    /// `syntaxDirtyLines` only.
    var blockCommentLineStarts: [Bool] = []

    /// Per-line flag: `true` if the line starts inside a fenced code block (markdown).
    var codeBlockLineStarts: [Bool] = []

    /// The window of lines whose cached multi-line state may be wrong.
    ///
    /// `from` is the first line to rescan — its own entry is still valid,
    /// since no text before it moved. Entries through `through` belong to
    /// text the edit replaced and must be rewritten unconditionally; past
    /// that point the scan may stop as soon as the state it computes matches
    /// what the cache already holds. `nil` means the caches match the text.
    ///
    /// This is what keeps highlighting off the O(document) path: a keystroke
    /// inside a function converges on the very next line instead of rescanning
    /// the whole file.
    private(set) var syntaxDirtyLines: (from: Int, through: Int)?

    /// Marks every line for rescan (file load, language change).
    func markSyntaxDirtyAll() {
        syntaxDirtyLines = (from: 0, through: Int.max)
    }

    /// Widens the pending rescan window to cover `from...through`.
    func markSyntaxDirty(from: Int, through: Int) {
        let lo = max(0, from)
        let hi = max(lo, through)
        guard let current = syntaxDirtyLines else {
            syntaxDirtyLines = (from: lo, through: hi)
            return
        }
        syntaxDirtyLines = (from: min(current.from, lo), through: max(current.through, hi))
    }

    /// Moves a pending rescan window that lies below `line` by `shift` lines,
    /// so it keeps pointing at the same text after an edit above it changed the
    /// line count. A "dirty everything" window needs no rebasing.
    private func rebaseSyntaxDirty(afterLine line: Int, shift: Int) {
        guard shift != 0,
              let current = syntaxDirtyLines,
              current.through != Int.max,
              current.through > line else { return }
        // A window straddling the edit keeps its top: the lines above `line`
        // did not move.
        let from = current.from > line ? max(line, current.from + shift) : current.from
        syntaxDirtyLines = (from: from, through: max(from, current.through + shift))
    }

    /// Called by the highlighter once the caches have been brought in sync.
    func clearSyntaxDirty() {
        syntaxDirtyLines = nil
    }

    // MARK: - Display Helpers

    /// Short name shown on the tab (file name or "Untitled").
    var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    /// Tab title with a dirty indicator prefix.
    var title: String {
        (isDirty ? "\u{2022} " : "") + displayName  // bullet = "• "
    }

    /// Full path for tooltip, or "Untitled".
    var tooltipText: String {
        fileURL?.path ?? "Untitled"
    }
}
