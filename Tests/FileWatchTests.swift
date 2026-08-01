import Foundation

/// Checks that a change made by another program actually reaches the editor.
///
/// The case worth pinning down is the atomic replace: a kqueue watch follows
/// the *descriptor*, and git, `sed -i` and this editor's own save all replace
/// a file by renaming a new one over it. Once that happens the descriptor
/// names an unlinked inode and every later write is invisible unless the watch
/// is re-armed on the path.
///
/// Shares the harness in `EditIndexTests`; run with `Tests/run.sh`.
enum FileWatchTests {

    // MARK: - Harness

    nonisolated(unsafe) static var events: [String: Int] = [:]

    static let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("texteditor-filewatch-tests-\(getpid())")

    static func file(_ name: String, _ contents: String) -> URL {
        let url = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    static func write(_ contents: String, to url: URL) {
        try? contents.write(to: url, atomically: false, encoding: .utf8)
    }

    static func eventCount(_ url: URL) -> Int {
        events[FileSearchService.canonicalPath(url), default: 0]
    }

    /// Runs the main runloop — where the service delivers its callbacks — for
    /// `seconds`, so a watch can arm or a debounce can expire.
    static func settle(_ seconds: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            usleep(5_000)
        }
    }

    /// Pumps the runloop until `url` has raised at least `target` events.
    static func waitForEvents(_ url: URL, atLeast target: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if eventCount(url) >= target { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            usleep(5_000)
        }
        return eventCount(url) >= target
    }

    // MARK: - Tests

    /// The plain case: someone writes to the file in place.
    static func testDirectWriteIsSeen() {
        let url = file("direct.txt", "one\n")
        FileWatchService.shared.watch(url)
        settle()

        write("two\n", to: url)
        EditIndexTests.expect(waitForEvents(url, atLeast: 1),
                              "a direct write raises an event")

        FileWatchService.shared.unwatch(url)
        settle()
    }

    /// The case the whole re-arm mechanism exists for. Everything after the
    /// rename is invisible to a watch that stayed on the old descriptor.
    static func testAtomicReplaceRearmsTheWatch() {
        let url = file("atomic.txt", "one\n")
        FileWatchService.shared.watch(url)
        settle()

        let temp = scratch.appendingPathComponent("atomic.tmp")
        write("two\n", to: temp)
        EditIndexTests.expectEqual(rename(temp.path, url.path), 0, "rename over the watched file")

        EditIndexTests.expect(waitForEvents(url, atLeast: 1),
                              "an atomic replace raises an event")

        // Give the re-arm its retries before testing whether it worked.
        settle(0.6)
        let before = eventCount(url)
        write("three\n", to: url)
        EditIndexTests.expect(waitForEvents(url, atLeast: before + 1),
                              "the watch survives an atomic replace")

        FileWatchService.shared.unwatch(url)
        settle()
    }

    /// A file that goes away and comes back — a branch switch, in practice.
    /// The watch has to pick up the replacement.
    static func testDeleteThenRecreateIsSeen() {
        let url = file("gone.txt", "one\n")
        FileWatchService.shared.watch(url)
        settle()

        try? FileManager.default.removeItem(at: url)
        EditIndexTests.expect(waitForEvents(url, atLeast: 1), "a delete raises an event")

        _ = file("gone.txt", "back\n")
        settle(0.6)
        let before = eventCount(url)
        write("back again\n", to: url)
        EditIndexTests.expect(waitForEvents(url, atLeast: before + 1),
                              "writes to the recreated file are seen")

        FileWatchService.shared.unwatch(url)
        settle()
    }

    /// Two tabs can hold the same file. Closing one must not blind the other,
    /// and the last release has to actually let go.
    static func testRefCounting() {
        let baseline = FileWatchService.shared.watchedPathCount
        let url = file("shared.txt", "one\n")

        FileWatchService.shared.watch(url)
        FileWatchService.shared.watch(url)
        settle()
        EditIndexTests.expectEqual(FileWatchService.shared.watchedPathCount, baseline + 1,
                                   "the same path is watched once, not twice")

        FileWatchService.shared.unwatch(url)
        settle()
        let before = eventCount(url)
        write("two\n", to: url)
        EditIndexTests.expect(waitForEvents(url, atLeast: before + 1),
                              "the remaining holder still gets events")

        FileWatchService.shared.unwatch(url)
        settle()
        EditIndexTests.expectEqual(FileWatchService.shared.watchedPathCount, baseline,
                                   "the last release drops the watch")
    }

    /// Watches are keyed the same way the controller compares tab paths, so a
    /// file reached through a symlink is not watched twice — and an event on
    /// it still matches the tab that opened it by its other name.
    static func testSymlinkResolvesToOneWatch() {
        let baseline = FileWatchService.shared.watchedPathCount
        let real = file("real.txt", "one\n")
        let link = scratch.appendingPathComponent("link.txt")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        FileWatchService.shared.watch(real)
        FileWatchService.shared.watch(link)
        settle()
        EditIndexTests.expectEqual(FileWatchService.shared.watchedPathCount, baseline + 1,
                                   "a symlink and its target share one watch")

        FileWatchService.shared.unwatch(link)
        FileWatchService.shared.unwatch(real)
        settle()
    }

    /// The invariant that keeps the editor's own saves from looking like
    /// somebody else's: a save records exactly the state it left on disk, so
    /// the re-stat the change check does compares equal and nothing reloads.
    static func testOwnSaveRecordsTheStateItWrote() {
        let url = file("save.txt", "one\n")
        let recorded = try? FileService.shared.saveFile(content: "two\n", to: url)
        EditIndexTests.expectEqual(recorded ?? nil, FileService.diskState(of: url),
                                   "the disk state a save records matches the file it wrote")
    }

    // MARK: - Entry point

    static func all() {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        FileWatchService.shared.setOnChange { path in
            events[path, default: 0] += 1
        }

        EditIndexTests.run("a direct write reaches the editor", testDirectWriteIsSeen)
        EditIndexTests.run("an atomic replace re-arms the watch", testAtomicReplaceRearmsTheWatch)
        EditIndexTests.run("a deleted and recreated file is picked back up", testDeleteThenRecreateIsSeen)
        EditIndexTests.run("watches are reference counted", testRefCounting)
        EditIndexTests.run("a symlink and its target share one watch", testSymlinkResolvesToOneWatch)
        EditIndexTests.run("a save records the state it wrote", testOwnSaveRecordsTheStateItWrote)

        try? FileManager.default.removeItem(at: scratch)
    }
}
