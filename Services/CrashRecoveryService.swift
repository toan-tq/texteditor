import AppKit

/// Singleton that periodically backs up dirty editor tabs to `~/.visualgit/backups/`.
/// On next launch, any un-cleaned backups are offered for restoration.
/// Ported from the backup logic in Java TextEditor.java.
class CrashRecoveryService {

    static let shared = CrashRecoveryService()

    /// Immutable snapshot of one tab's backup-relevant state, taken on the
    /// main thread. All fields are value types so the background writer can
    /// safely use them without racing the main-thread mutator.
    struct TabSnapshot {
        let identity: ObjectIdentifier  // stable per TabDocument lifetime
        let filePath: String?           // doc.fileURL?.path captured on main
        let content: String
        let isDirty: Bool
    }

    // MARK: - Configuration

    private let backupDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".visualgit/backups")
    }()

    /// Interval between automatic backup writes (seconds).
    private let backupInterval: TimeInterval = 10

    // MARK: - State

    private var timer: Timer?

    /// Tracks content hash AND backup-slot index per TabDocument identity so
    /// unchanged tabs are not re-written. The index matters: slot files are
    /// named by position in the dirty list (`0.bak`, `1.bak`...), so when a
    /// tab shifts position (another tab was saved/closed) it must be
    /// re-written even with an unchanged hash — otherwise the slot file keeps
    /// stale content while `index.txt` maps it to a different path, and a
    /// crash restore would put the wrong content into the wrong file.
    private var backupStates: [ObjectIdentifier: (hash: Int, index: Int)] = [:]
    private let hashesLock = NSLock()

    // MARK: - Timer Control

    /// Start the periodic backup timer.
    ///
    /// - Parameter snapshotProvider: A closure executed on the main thread
    ///   that returns immutable `TabSnapshot` values for every open tab. All
    ///   field reads of `TabDocument` happen here on the main thread so the
    ///   background writer never touches the mutable model.
    func start(snapshotProvider: @escaping () -> [TabSnapshot]) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: backupInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let snapshots = snapshotProvider()  // captured on main
            DispatchQueue.global(qos: .background).async {
                self.writeBackups(snapshots: snapshots)
            }
        }
    }

    /// Invalidate and release the backup timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Writing Backups

    /// Write dirty tabs to the backup directory with an `index.txt` manifest.
    ///
    /// Each dirty tab is written to `<n>.bak`. Tabs whose content hash has not
    /// changed since the last write are skipped to reduce disk I/O.
    func writeBackups(snapshots: [TabSnapshot]) {
        // Filter to dirty tabs only; remove stale hashes for clean tabs.
        let dirtySnapshots = snapshots.filter { $0.isDirty }
        let cleanIDs = Set(snapshots.filter { !$0.isDirty }.map { $0.identity })
        hashesLock.lock()
        for id in cleanIDs {
            backupStates.removeValue(forKey: id)
        }
        hashesLock.unlock()

        if dirtySnapshots.isEmpty {
            cleanupBackups()
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: backupDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            var indexLines: [String] = []

            for (i, snap) in dirtySnapshots.enumerated() {
                let hash = snap.content.hashValue

                // Only skip the write when BOTH content and slot index are
                // unchanged — an index change means this tab's content must
                // land in a different .bak file than last cycle.
                hashesLock.lock()
                let prev = backupStates[snap.identity]
                let needsWrite = prev?.hash != hash || prev?.index != i
                hashesLock.unlock()
                if needsWrite {
                    let bakURL = backupDir.appendingPathComponent("\(i).bak")
                    try snap.content.write(to: bakURL, atomically: true, encoding: .utf8)
                    hashesLock.lock()
                    backupStates[snap.identity] = (hash: hash, index: i)
                    hashesLock.unlock()
                }

                indexLines.append(snap.filePath ?? "UNTITLED")
            }

            // Write manifest.
            let indexURL = backupDir.appendingPathComponent("index.txt")
            let indexText = indexLines.joined(separator: "\n") + "\n"
            try indexText.write(to: indexURL, atomically: true, encoding: .utf8)

            // Remove orphan .bak files from previous larger sets.
            var orphanIndex = dirtySnapshots.count
            while true {
                let orphanURL = backupDir.appendingPathComponent("\(orphanIndex).bak")
                if FileManager.default.fileExists(atPath: orphanURL.path) {
                    try? FileManager.default.removeItem(at: orphanURL)
                    orphanIndex += 1
                } else {
                    break
                }
            }
        } catch {
            // Backup is best-effort; do not disrupt the user.
        }
    }

    // MARK: - Restoring Backups

    /// Attempt to restore backups from a previous session.
    ///
    /// - Returns: An array of `(filePath_or_nil, content)` tuples if backups
    ///   were found, or `nil` if there was nothing to restore.
    ///
    /// The backup directory is cleaned up after a successful restore.
    func restoreBackups() -> [(String?, String)]? {
        let indexURL = backupDir.appendingPathComponent("index.txt")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return nil
        }

        do {
            let indexText = try String(contentsOf: indexURL, encoding: .utf8)
            let lines = indexText
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }

            var restored: [(String?, String)] = []

            for (i, line) in lines.enumerated() {
                let bakURL = backupDir.appendingPathComponent("\(i).bak")
                guard FileManager.default.fileExists(atPath: bakURL.path) else {
                    continue
                }
                let content = try String(contentsOf: bakURL, encoding: .utf8)
                let filePath: String? = (line == "UNTITLED") ? nil : line
                restored.append((filePath, content))
            }

            cleanupBackups()
            return restored.isEmpty ? nil : restored
        } catch {
            cleanupBackups()
            return nil
        }
    }

    // MARK: - Cleanup

    /// Remove the entire backup directory and its contents.
    func cleanupBackups() {
        guard FileManager.default.fileExists(atPath: backupDir.path) else { return }
        try? FileManager.default.removeItem(at: backupDir)
        hashesLock.lock()
        backupStates.removeAll()
        hashesLock.unlock()
    }
}
