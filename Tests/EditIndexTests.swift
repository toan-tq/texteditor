import AppKit

/// Checks for the line-index / multi-line-cache invariants that the editing
/// path depends on. Every bug these cover was an offset-math bug that produced
/// wrong line numbers or stale syntax colouring rather than a crash, so they
/// are worth pinning down.
///
/// Run with `Tests/run.sh` — the repo has no Xcode test target, and these need
/// no app bundle.
@main
struct EditIndexTests {

    // MARK: - Harness

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition {
            failures += 1
            print("  FAIL: \(message())")
        }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual != expected {
            failures += 1
            print("  FAIL: \(label)\n        got      \(actual)\n        expected \(expected)")
        }
    }

    static func run(_ name: String, _ body: () -> Void) {
        print("• \(name)")
        body()
    }

    // MARK: - Reference implementations

    /// Line starts computed from scratch — the answer the incremental index
    /// must always agree with.
    static func referenceLineStarts(_ text: NSString) -> [Int] {
        var offsets = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A {
            offsets.append(i + 1)
        }
        return offsets
    }

    /// Multi-line state computed by scanning the whole document, i.e. what the
    /// old full-rebuild-per-keystroke code produced.
    static func referenceCache(_ text: NSString, starts: [Int], language: SyntaxLanguage) -> [Bool] {
        var cache = Array(repeating: false, count: starts.count)
        let through = starts.count - 1
        if language == .markdown {
            _ = SyntaxHighlighter.rescanFences(in: text, starts: starts, cache: &cache,
                                               from: 0, rewriteThrough: through)
        } else if language.hasPythonTripleQuotes {
            _ = SyntaxHighlighter.rescanTripleQuotes(in: text, starts: starts, cache: &cache,
                                                     from: 0, rewriteThrough: through)
        } else {
            _ = SyntaxHighlighter.rescanBlockComments(in: text, starts: starts, cache: &cache,
                                                      from: 0, rewriteThrough: through)
        }
        return cache
    }

    static func escaped(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func liveCache(_ doc: TabDocument, _ language: SyntaxLanguage) -> [Bool] {
        language == .markdown ? doc.codeBlockLineStarts : doc.blockCommentLineStarts
    }

    /// Applies an edit the way NSTextStorage + the highlighter delegate do:
    /// mutate the storage, then hand the post-edit text to the document.
    static func applyEdit(_ ts: NSTextStorage, _ doc: TabDocument, _ highlighter: SyntaxHighlighter,
                          range: NSRange, replacement: String) {
        let delta = (replacement as NSString).length - range.length
        ts.replaceCharacters(in: range, with: replacement)
        let edited = NSRange(location: range.location, length: (replacement as NSString).length)
        doc.updateLineStartOffsets(editedRange: edited, delta: delta, newText: ts.string as NSString)
        highlighter.refreshMultiLineCache(in: ts, document: doc, language: doc.language)
    }

    // MARK: - Tests

    /// Regression: `loadFile` used to build the line index and *then* assign
    /// `editorView.string`, which fires the text-storage delegate and spliced a
    /// second copy of every line start onto the index — a 1,000-line file
    /// reported 1,999 lines.
    static func testFullDocumentSwapRebuildsIndex() {
        let content = "line1\nline2\nline3\nline4\n"
        let ns = content as NSString

        let doc = TabDocument()
        doc.rebuildLineIndex(from: content)          // pre-built, as loadFile used to do
        doc.updateLineStartOffsets(editedRange: NSRange(location: 0, length: ns.length),
                                   delta: ns.length, newText: ns)
        expectEqual(doc.lineStartOffsets, referenceLineStarts(ns), "index after pre-built full swap")

        let fresh = TabDocument()                          // delegate-only path
        fresh.updateLineStartOffsets(editedRange: NSRange(location: 0, length: ns.length),
                                     delta: ns.length, newText: ns)
        expectEqual(fresh.lineStartOffsets, referenceLineStarts(ns), "index after delegate-only full swap")

        // Reloading a tab that already held different content.
        let reloaded = TabDocument()
        reloaded.rebuildLineIndex(from: "a\nb\n")
        reloaded.updateLineStartOffsets(editedRange: NSRange(location: 0, length: ns.length),
                                        delta: ns.length - 4, newText: ns)
        expectEqual(reloaded.lineStartOffsets, referenceLineStarts(ns), "index after tab reload")
    }

    static func testLineIndexLookup() {
        let doc = TabDocument()
        let content = "aa\nbbbb\n\ncc"
        doc.rebuildLineIndex(from: content)
        expectEqual(doc.lineStartOffsets, [0, 3, 8, 9], "line starts for mixed content")
        expectEqual(doc.lineIndex(forCharOffset: 0), 0, "offset 0 -> line 0")
        expectEqual(doc.lineIndex(forCharOffset: 2), 0, "offset at newline -> line 0")
        expectEqual(doc.lineIndex(forCharOffset: 3), 1, "offset at line start -> line 1")
        expectEqual(doc.lineIndex(forCharOffset: 8), 2, "empty line")
        expectEqual(doc.lineIndex(forCharOffset: 11), 3, "end of document -> last line")
    }

    /// Bookmarks are stored by line index, so an edit above them has to move
    /// them or they end up pointing at unrelated text.
    static func testBookmarksFollowEdits() {
        // Insert two lines above the bookmarks.
        var doc = TabDocument()
        var ts = NSTextStorage(string: "l0\nl1\nl2\nl3\nl4\n")
        var hl = SyntaxHighlighter()
        doc.rebuildLineIndex(from: ts.string)
        hl.tabDocument = doc
        doc.bookmarks = [0, 3]
        applyEdit(ts, doc, hl, range: NSRange(location: 0, length: 0), replacement: "new\nnew\n")
        // Both marked lines are pushed down, including the one at the very
        // offset the text was inserted at — the bookmark belongs to the text.
        expectEqual(doc.bookmarks, [2, 5], "bookmarks shift down when lines are inserted above")

        // Delete the bookmarked line itself.
        doc = TabDocument()
        ts = NSTextStorage(string: "l0\nl1\nl2\nl3\n")
        hl = SyntaxHighlighter()
        doc.rebuildLineIndex(from: ts.string)
        hl.tabDocument = doc
        doc.bookmarks = [1, 3]
        applyEdit(ts, doc, hl, range: NSRange(location: 3, length: 3), replacement: "")
        expectEqual(doc.bookmarks, [2], "bookmark on a deleted line is dropped, the one below moves up")

        // Editing within a line must not move anything.
        doc = TabDocument()
        ts = NSTextStorage(string: "l0\nl1\nl2\n")
        hl = SyntaxHighlighter()
        doc.rebuildLineIndex(from: ts.string)
        hl.tabDocument = doc
        doc.bookmarks = [0, 2]
        applyEdit(ts, doc, hl, range: NSRange(location: 4, length: 0), replacement: "XYZ")
        expectEqual(doc.bookmarks, [0, 2], "in-line edit leaves bookmarks alone")
    }

    /// The incremental rescan must land on the same cache the old
    /// full-document rebuild produced, including when a single keystroke opens
    /// or closes a construct that spans the rest of the file.
    static func testMultiLineCacheMatchesFullRescan() {
        let cases: [(SyntaxLanguage, String, [(NSRange, String)])] = [
            (.cCpp,
             "int a;\nint b;\nint c;\nint d;\n",
             [(NSRange(location: 7, length: 0), "/*"),        // opens a comment to EOF
              (NSRange(location: 16, length: 0), "*/"),       // closes it mid-file
              (NSRange(location: 7, length: 2), ""),          // removes the opener again
              (NSRange(location: 0, length: 0), "/* x */\n")]),
            (.python,
             "a = 1\nb = 2\nc = 3\nd = 4\n",
             [(NSRange(location: 6, length: 0), "\"\"\""),
              (NSRange(location: 18, length: 0), "\"\"\""),
              (NSRange(location: 6, length: 3), "'''")]),
            (.markdown,
             "text\nmore\nlast\n",
             [(NSRange(location: 5, length: 0), "```\n"),
              (NSRange(location: 14, length: 0), "```\n"),
              (NSRange(location: 5, length: 4), "")]),
        ]

        for (language, initial, edits) in cases {
            let doc = TabDocument()
            doc.language = language
            let highlighter = SyntaxHighlighter()
            highlighter.tabDocument = doc
            let ts = NSTextStorage(string: initial)

            doc.rebuildLineIndex(from: initial)
            highlighter.refreshMultiLineCache(in: ts, document: doc, language: language)

            for (index, edit) in edits.enumerated() {
                applyEdit(ts, doc, highlighter, range: edit.0, replacement: edit.1)
                let text = ts.string as NSString
                expectEqual(doc.lineStartOffsets, referenceLineStarts(text),
                            "\(language) edit #\(index): line index")
                expectEqual(liveCache(doc, language),
                            referenceCache(text, starts: doc.lineStartOffsets, language: language),
                            "\(language) edit #\(index): multi-line cache")
            }
        }
    }

    /// Several edits land before the highlighter's deferred pass runs (Replace
    /// All, a multi-line paste), so the pending rescan window has to survive
    /// more than one edit. Regression: the window was recorded in the line
    /// numbering of the edit that opened it, so a later edit inserting lines
    /// *above* it left the window pointing at lines that had moved down —
    /// the scan re-converged before reaching them and left stale state behind.
    static func testBatchedEditsRebaseDirtyWindow() {
        // Two edits per case, applied back to back with one refresh at the end.
        // The second is above the first and changes the line count.
        let cases: [(SyntaxLanguage, String, [(NSRange, String)])] = [
            (.cCpp,
             "int a;\nint b;\nint c;\nint d;\nint e;\nint f;\n",
             [(NSRange(location: 28, length: 0), "/*"),        // line 4: opens a comment
              (NSRange(location: 0, length: 0), "x;\ny;\n")]), // pushes it down 2 lines
            (.cCpp,
             "/*\na\nb\nc\nd\ne\nf\n*/\ng\n",
             [(NSRange(location: 16, length: 2), "  "),        // kills the closer
              (NSRange(location: 3, length: 0), "q\nr\ns\n")]),
            (.python,
             "a = 1\nb = 2\nc = 3\nd = 4\n",
             [(NSRange(location: 12, length: 0), "\"\"\""),
              (NSRange(location: 0, length: 0), "z = 0\n")]),
            (.markdown,
             "text\nmore\nlast\nend\n",
             [(NSRange(location: 10, length: 0), "```\n"),
              (NSRange(location: 0, length: 0), "top\nalso\n")]),
        ]

        for (language, initial, edits) in cases {
            let doc = TabDocument()
            doc.language = language
            let highlighter = SyntaxHighlighter()
            highlighter.tabDocument = doc
            let ts = NSTextStorage(string: initial)

            doc.rebuildLineIndex(from: initial)
            highlighter.refreshMultiLineCache(in: ts, document: doc, language: language)

            for edit in edits {
                let delta = (edit.1 as NSString).length - edit.0.length
                ts.replaceCharacters(in: edit.0, with: edit.1)
                doc.updateLineStartOffsets(editedRange: NSRange(location: edit.0.location,
                                                                length: (edit.1 as NSString).length),
                                           delta: delta, newText: ts.string as NSString)
            }
            highlighter.refreshMultiLineCache(in: ts, document: doc, language: language)

            let text = ts.string as NSString
            expectEqual(doc.lineStartOffsets, referenceLineStarts(text),
                        "\(language) batched: line index")
            expectEqual(liveCache(doc, language),
                        referenceCache(text, starts: doc.lineStartOffsets, language: language),
                        "\(language) batched: multi-line cache")
        }
    }

    /// Random edits, compared against a from-scratch rebuild after every one.
    /// This is the check that would have caught the doubled line index.
    static func testFuzzAgainstFullRebuild() {
        let fragments = ["x", "\n", "\n\n", "/*", "*/", "//", "\"", "'''", "\"\"\"", "```",
                         "foo bar\n", "a\nb\nc\n", "", "#", "\t"]
        var seed: UInt64 = 0x5EED
        func random(_ bound: Int) -> Int {
            // xorshift — deterministic across runs so a failure is reproducible.
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return bound > 0 ? Int(seed % UInt64(bound)) : 0
        }

        for language in [SyntaxLanguage.cCpp, .python, .markdown] {
            let doc = TabDocument()
            doc.language = language
            let highlighter = SyntaxHighlighter()
            highlighter.tabDocument = doc
            let ts = NSTextStorage(string: "alpha\nbeta\ngamma\ndelta\n")

            doc.rebuildLineIndex(from: ts.string)
            highlighter.refreshMultiLineCache(in: ts, document: doc, language: language)
            doc.bookmarks = [0, 2]

            for step in 0..<1000 {
                let length = (ts.string as NSString).length
                let location = random(length + 1)
                let span = random(min(6, length - location + 1))
                let replacement = fragments[random(fragments.count)]

                applyEdit(ts, doc, highlighter,
                          range: NSRange(location: location, length: span),
                          replacement: replacement)

                let text = ts.string as NSString
                let expectedStarts = referenceLineStarts(text)
                if doc.lineStartOffsets != expectedStarts {
                    expectEqual(doc.lineStartOffsets, expectedStarts,
                                "\(language) fuzz step \(step): line index")
                    break
                }
                let expectedCache = referenceCache(text, starts: expectedStarts, language: language)
                if liveCache(doc, language) != expectedCache {
                    expectEqual(liveCache(doc, language), expectedCache,
                                "\(language) fuzz step \(step): multi-line cache")
                    print("        edit     \(NSRange(location: location, length: span)) -> \(escaped(replacement))")
                    print("        text     \(escaped(text as String))")
                    break
                }
                if let stray = doc.bookmarks.first(where: { $0 >= expectedStarts.count }) {
                    expect(false, "\(language) fuzz step \(step): bookmark \(stray) past last line \(expectedStarts.count - 1)")
                    break
                }
            }
        }
    }

    // MARK: - Entry point

    static func main() {
        run("full-document swap rebuilds the line index", testFullDocumentSwapRebuildsIndex)
        run("line index lookup", testLineIndexLookup)
        run("bookmarks follow edits", testBookmarksFollowEdits)
        run("incremental multi-line cache matches a full rescan", testMultiLineCacheMatchesFullRescan)
        run("batched edits rebase the pending rescan window", testBatchedEditsRebaseDirtyWindow)
        run("fuzz: random edits vs full rebuild", testFuzzAgainstFullRebuild)
        FileIOTests.all()
        FileWatchTests.all()

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("\(failures) FAILED")
            exit(1)
        }
        print("OK")
    }
}
