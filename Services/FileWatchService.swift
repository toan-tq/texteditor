import Foundation

/// Watches the files behind open tabs so an edit made by another program is
/// noticed without the user asking for it.
///
/// An event here is only a hint — kqueue says "something happened to this
/// file", never what. Callers re-`stat` and compare against the
/// `FileService.DiskState` they last read or wrote. That comparison is also
/// what keeps the editor's own saves silent: saving updates the recorded
/// state, so the event it raises compares equal and nothing happens.
///
/// Not a complete answer on its own. kqueue is unreliable on network volumes,
/// and an atomic replace leaves a window with no watch on the path at all, so
/// callers should also re-check when the app comes forward.
final class FileWatchService {

    static let shared = FileWatchService()

    /// One save can raise several events (truncate, write, extend). Waiting
    /// for the file to go quiet collapses them into one reload, and gives an
    /// atomic replace time to land before anyone looks at the path.
    private static let quietPeriod: DispatchTimeInterval = .milliseconds(250)

    /// `FileService.writePreservingMetadata` — and git, and most other
    /// editors — replace a file by renaming a temp file over it, which leaves
    /// the watched descriptor pointing at an unlinked inode. Re-opening the
    /// path restores the watch, but the path is briefly absent mid-rename, so
    /// it takes more than one try.
    private static let rearmDelay: DispatchTimeInterval = .milliseconds(120)
    private static let rearmAttempts = 8

    private final class Entry {
        var source: DispatchSourceFileSystemObject?
        /// Two tabs can hold the same file; closing one must not blind the other.
        var refCount = 1
        var debounce: DispatchWorkItem?
    }

    /// Every access to `entries` and `handler` happens on this queue, event
    /// handlers included, so none of it needs locking.
    private let queue = DispatchQueue(label: "com.texteditor.filewatch", qos: .utility)
    private var entries: [String: Entry] = [:]
    private var handler: ((String) -> Void)?

    // MARK: - API

    /// Installs the callback that fires on the main queue with the canonical
    /// path of a file that may have changed. Coalesced: a burst of writes
    /// produces one call.
    func setOnChange(_ handler: @escaping (String) -> Void) {
        queue.async { self.handler = handler }
    }

    /// Starts watching `url`, or bumps its reference count if it is already
    /// watched.
    func watch(_ url: URL) {
        let path = FileSearchService.canonicalPath(url)
        queue.async {
            if let entry = self.entries[path] {
                entry.refCount += 1
                return
            }
            let entry = Entry()
            self.entries[path] = entry
            self.arm(path: path, entry: entry, attemptsLeft: 0)
        }
    }

    func unwatch(_ url: URL) {
        let path = FileSearchService.canonicalPath(url)
        queue.async {
            guard let entry = self.entries[path] else { return }
            entry.refCount -= 1
            guard entry.refCount <= 0 else { return }
            entry.debounce?.cancel()
            entry.source?.cancel()
            self.entries.removeValue(forKey: path)
        }
    }

    /// Re-opens any watch that was lost — a file deleted for longer than the
    /// re-arm attempts lasted, then put back. Cheap enough to call whenever
    /// the app comes forward, and nothing without a live source is touched.
    func rearmLostWatches() {
        queue.async {
            for (path, entry) in self.entries where entry.source == nil {
                self.arm(path: path, entry: entry, attemptsLeft: 0)
            }
        }
    }

    /// Test hook: number of paths currently watched.
    var watchedPathCount: Int {
        queue.sync { entries.count }
    }

    // MARK: - Watching

    /// Opens `path` and starts a source on it, retrying `attemptsLeft` more
    /// times if it can't be opened yet.
    private func arm(path: String, entry: Entry, attemptsLeft: Int) {
        // Unwatched — or replaced by a later watch — while this was queued.
        guard entries[path] === entry else { return }

        let descriptor = open(path, O_EVTONLY)
        if descriptor < 0 {
            guard attemptsLeft > 0 else { return }
            queue.asyncAfter(deadline: .now() + Self.rearmDelay) {
                self.arm(path: path, entry: entry, attemptsLeft: attemptsLeft - 1)
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            // The descriptor no longer names the file at `path`: it was
            // unlinked or renamed out from under us. Follow the path, not the
            // inode — the replacement is the file the tab is looking at now.
            if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                source.cancel()
                if self.entries[path] === entry { entry.source = nil }
                self.arm(path: path, entry: entry, attemptsLeft: Self.rearmAttempts)
            }
            self.notify(path: path)
        }
        source.setCancelHandler { close(descriptor) }

        entry.source = source
        source.resume()
    }

    /// Collapses a burst of events into a single main-queue callback.
    private func notify(path: String) {
        guard let entry = entries[path] else { return }
        entry.debounce?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.entries[path] != nil,
                  let handler = self.handler else { return }
            DispatchQueue.main.async { handler(path) }
        }
        entry.debounce = work
        queue.asyncAfter(deadline: .now() + Self.quietPeriod, execute: work)
    }
}
