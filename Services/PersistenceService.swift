import Foundation

/// Singleton managing recent-files list and directory search history.
/// Persisted as plain text files under `~/.visualgit/`.
/// Ported from the persistence methods in Java TextEditor.java.
class PersistenceService {

    static let shared = PersistenceService()

    // MARK: - Paths

    private let configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".visualgit")
    }()

    private var recentFilesPath: URL {
        configDir.appendingPathComponent("recent_files.txt")
    }

    private var dirHistoryPath: URL {
        configDir.appendingPathComponent("dir_search_history.txt")
    }

    // MARK: - Limits

    private let maxRecentFiles = 10
    private let maxDirHistory = 7

    // MARK: - Recent Files

    /// Load recent file paths from disk. Returns an empty array on any failure.
    func loadRecentFiles() -> [String] {
        return readLines(from: recentFilesPath)
    }

    /// Save the recent-files list to disk, truncating to `maxRecentFiles`.
    func saveRecentFiles(_ files: [String]) {
        let capped = Array(files.prefix(maxRecentFiles))
        writeLines(capped, to: recentFilesPath)
    }

    /// Add `path` to the front of the recent-files list (removing any existing
    /// duplicate) and persist immediately. Load-modify-save against disk so a
    /// "Clear Menu" from elsewhere is respected — a long-lived in-memory copy
    /// would resurrect the cleared history on the next save.
    func addRecentFile(_ path: String) {
        var files = loadRecentFiles()
        files.removeAll { $0 == path }
        files.insert(path, at: 0)
        saveRecentFiles(files)
    }

    // MARK: - Directory Search History

    /// Load directory search history from disk.
    func loadDirHistory() -> [String] {
        return readLines(from: dirHistoryPath)
    }

    /// Save the directory history list to disk, truncating to `maxDirHistory`.
    func saveDirHistory(_ dirs: [String]) {
        let capped = Array(dirs.prefix(maxDirHistory))
        writeLines(capped, to: dirHistoryPath)
    }

    /// Add `path` to the front of the directory history (removing any existing duplicate)
    /// and persist immediately.
    func addDirHistory(_ path: String, to dirs: inout [String]) {
        dirs.removeAll { $0 == path }
        dirs.insert(path, at: 0)
        saveDirHistory(dirs)
    }

    // MARK: - Helpers

    /// Ensure the configuration directory exists.
    private func ensureConfigDir() {
        try? FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Read non-empty trimmed lines from a text file.
    private func readLines(from url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Write lines to a text file, creating the config directory if needed.
    private func writeLines(_ lines: [String], to url: URL) {
        ensureConfigDir()
        let text = lines.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
