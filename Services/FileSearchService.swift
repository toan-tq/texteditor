import Foundation

/// One row in the Find in Files result table.
struct DirSearchResult {
    let fileURL: URL
    let lineNumber: Int
    let lineText: String
}

/// Directory-wide search and replace, streamed.
///
/// Three properties this engine is built around:
///
/// 1. **Results stream.** Files go straight from the directory enumerator into
///    a bounded worker pool, so hits appear within milliseconds instead of
///    after the whole tree has been walked.
/// 2. **Flat memory when searching.** Files are read in fixed-size chunks and
///    matched on raw bytes; peak memory is one chunk plus one line per worker,
///    whatever the file size. Replacing does not get this — rewriting a file
///    means holding its decoded contents, so it reads the whole thing in.
/// 3. **Per-run cancellation.** Every run owns its own `Handle`, so starting a
///    second search can never disturb the one already in flight.
final class FileSearchService {

    static let shared = FileSearchService()
    private init() {}

    // MARK: - Request / result types

    struct Options {
        var matchCase = false
        var wholeWord = false
        var useRegex = false
        var lookInSubfolders = true
    }

    struct Request {
        var needle: String
        /// `nil` searches. Non-nil rewrites every match on disk.
        var replacement: String?
        var folder: URL
        var fileTypes: String
        var exclude: String
        var options: Options
        /// Caps rows handed to the UI; in search mode it also ends the run.
        /// Replacing is never capped — a half-replaced file is worse than a
        /// long wait — but its result rows still are.
        var maxMatches: Int = 5000
        var maxFileSize: Int = 100_000_000
        /// Paths that must not be rewritten (open tabs with unsaved edits).
        var skipPaths: Set<String> = []
    }

    struct Progress {
        var matches = 0
        var filesSearched = 0
        var filesFound = 0
        /// `true` while the directory walk is still turning up new files.
        var stillScanning = true
    }

    struct Summary {
        var matches = 0
        var filesSearched = 0
        var modifiedPaths: [String] = []
        var skippedPaths: [String] = []
        var cancelled = false
        var limitReached = false
        /// Set when the run never got started (bad folder, bad regex).
        var failure: String?
    }

    /// Cancellation token for a single run. Held by the caller so it can stop
    /// *this* search without touching any other.
    final class Handle {
        private let flag = AtomicFlag()
        var isCancelled: Bool { flag.value }
        func cancel() { flag.set(true) }
    }

    // MARK: - Tuning

    private static let chunkSize = 512 * 1024
    /// A line longer than this (minified JS, embedded blobs) is matched only
    /// up to the cap; the rest of that one line is skipped.
    private static let maxLineBytes = 1024 * 1024
    private static let displayBytes = 8192
    private static let binarySniffBytes = 8192
    private static let drainInterval = 0.15
    /// Cancellation and the shared match total are read once per this many
    /// lines. The old engine read them on *every* line, and the resulting lock
    /// traffic serialized the whole worker pool.
    private static let checkInterval = 512

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .fileSizeKey
    ]

    // MARK: - Entry point

    /// The directory enumerator hands back symlink-resolved URLs, so
    /// `/var/…` on the way in comes back as `/private/var/…`. Paths from both
    /// sides go through here before they are ever compared — otherwise the
    /// replace guard silently fails to recognise an open file and overwrites
    /// unsaved edits.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Starts a run and returns immediately. All three callbacks fire on the
    /// main queue; none of them fire after `onFinish`.
    @discardableResult
    func start(_ request: Request,
               onBatch: @escaping ([DirSearchResult]) -> Void,
               onProgress: @escaping (Progress) -> Void,
               onFinish: @escaping (Summary) -> Void) -> Handle {

        var request = request
        if request.replacement != nil && !request.skipPaths.isEmpty {
            request.skipPaths = Set(request.skipPaths.map {
                Self.canonicalPath(URL(fileURLWithPath: $0))
            })
        }

        let handle = Handle()

        let matcher: Matcher
        do {
            matcher = try Matcher(request: request)
        } catch {
            DispatchQueue.main.async {
                onFinish(Summary(failure: "Invalid regex"))
            }
            return handle
        }

        let filter = FileFilter(fileTypes: request.fileTypes, exclude: request.exclude)
        let shared = SharedState()
        let gate = DrainGate()

        // Batch results to the UI instead of hopping to main per hit.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
        timer.setEventHandler {
            guard !gate.stopped else { return }
            let (batch, progress) = shared.drain()
            if !batch.isEmpty { onBatch(batch) }
            onProgress(progress)
        }
        timer.resume()

        let workerCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let workers = DispatchQueue(label: "com.texteditor.filesearch.workers",
                                    qos: .userInitiated, attributes: .concurrent)
        // Backpressure: the walker runs a couple of files ahead of the pool,
        // never thousands. Bounds both memory and cancellation latency.
        let slots = DispatchSemaphore(value: workerCount + 2)
        let group = DispatchGroup()

        DispatchQueue.global(qos: .userInitiated).async {
            let finish: (Summary) -> Void = { summary in
                DispatchQueue.main.async {
                    gate.stopped = true
                    timer.cancel()
                    let (batch, _) = shared.drain()
                    if !batch.isEmpty { onBatch(batch) }
                    onFinish(summary)
                }
            }

            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !request.options.lookInSubfolders { options.insert(.skipsSubdirectoryDescendants) }

            guard let enumerator = FileManager.default.enumerator(
                at: request.folder,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: options)
            else {
                finish(Summary(failure: "Invalid directory"))
                return
            }

            let capped = request.replacement == nil
            for case let url as URL in enumerator {
                if handle.isCancelled { break }
                if capped && shared.matchTotal >= request.maxMatches { break }

                let name = url.lastPathComponent
                guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else { continue }

                if values.isDirectory == true {
                    if name.hasPrefix(".") || filter.isExcludedDir(name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, !name.hasPrefix(".") else { continue }
                if let size = values.fileSize, size == 0 || size > request.maxFileSize { continue }
                if FileService.isBinaryFile(url) { continue }
                guard filter.accepts(name) else { continue }

                shared.noteFound()
                slots.wait()
                group.enter()
                workers.async {
                    defer {
                        slots.signal()
                        group.leave()
                    }
                    guard !handle.isCancelled else { return }
                    if request.replacement != nil {
                        self.replaceInFile(url, request: request, matcher: matcher,
                                           shared: shared, handle: handle)
                    } else {
                        self.searchFile(url, request: request, matcher: matcher,
                                        shared: shared, handle: handle)
                    }
                }
            }

            shared.finishScanning()

            // notify (not wait) so this thread goes back to the pool instead of
            // parking until the last worker is done.
            group.notify(queue: .global(qos: .userInitiated)) {
                finish(shared.summary(cancelled: handle.isCancelled,
                                      limitReached: capped && shared.matchTotal >= request.maxMatches))
            }
        }

        return handle
    }

    // MARK: - Search

    private func searchFile(_ url: URL, request: Request, matcher: Matcher,
                            shared: SharedState, handle: Handle) {
        var results: [DirSearchResult] = []
        var matches = 0
        var lineCounter = 0
        let cap = request.maxMatches

        Self.enumerateLines(of: url) { line, lineNumber in
            lineCounter += 1
            if lineCounter % Self.checkInterval == 0 {
                if handle.isCancelled { return false }
                if shared.matchTotal + matches >= cap { return false }
            }
            if matches >= cap { return false }

            let count = matcher.countMatches(in: line)
            guard count > 0 else { return true }
            matches += count
            results.append(DirSearchResult(fileURL: url, lineNumber: lineNumber,
                                           lineText: Self.displayText(line, matchCount: count)))
            return true
        }

        shared.commitFile(results: results, matches: matches, rowCap: cap)
    }

    // MARK: - Replace

    private func replaceInFile(_ url: URL, request: Request, matcher: Matcher,
                               shared: SharedState, handle: Handle) {
        guard let replacement = request.replacement else { return }

        let path = Self.canonicalPath(url)
        if request.skipPaths.contains(path) {
            shared.noteSkipped(path)
            shared.commitFile(results: [], matches: 0, rowCap: request.maxMatches)
            return
        }

        // Search skips anything the byte reader calls binary, and replace has to
        // draw the line in the same place. Otherwise a regex replace — which has
        // no prefilter to stop it — would rewrite files the search reported no
        // matches in at all. UTF-16 text is the case that actually shows up:
        // ASCII content interleaved with NUL reads as binary here, even though
        // the editor itself opens it fine.
        if Self.looksBinary(url) {
            shared.commitFile(results: [], matches: 0, rowCap: request.maxMatches)
            return
        }

        // Cheap byte-level pre-check: only files that really contain the needle
        // get read and rewritten. Not possible for regex patterns.
        if matcher.canPrefilter, !containsMatch(url, matcher: matcher, handle: handle) {
            shared.commitFile(results: [], matches: 0, rowCap: request.maxMatches)
            return
        }

        // readFile normalizes to LF and reports the original ending and
        // encoding, so a CRLF file is written back as CRLF and a UTF-16 file
        // stays UTF-16.
        guard let read = try? FileService.shared.readFile(at: url) else {
            shared.commitFile(results: [], matches: 0, rowCap: request.maxMatches)
            return
        }

        var lines = read.content.components(separatedBy: "\n")
        var results: [DirSearchResult] = []
        var matches = 0
        for index in lines.indices {
            if handle.isCancelled { break }
            let (newLine, count) = matcher.replaceOccurrences(in: lines[index], with: replacement)
            guard count > 0 else { continue }
            lines[index] = newLine
            matches += count
            results.append(DirSearchResult(
                fileURL: url, lineNumber: index + 1,
                lineText: String(newLine.trimmingCharacters(in: .whitespaces).prefix(500))))
        }

        if matches > 0, !handle.isCancelled {
            do {
                try FileService.shared.saveFile(content: lines.joined(separator: "\n"),
                                                to: url, lineEnding: read.lineEnding,
                                                encoding: read.encoding, hasBOM: read.hasBOM)
                shared.noteModified(path)
            } catch {
                // Disk is unchanged, so don't report the matches as replaced.
                matches = 0
                results.removeAll()
            }
        }

        shared.commitFile(results: results, matches: matches, rowCap: request.maxMatches)
    }

    /// Stops at the first hit — used to skip files that replace would only read
    /// and write back unchanged.
    private func containsMatch(_ url: URL, matcher: Matcher, handle: Handle) -> Bool {
        var found = false
        var lineCounter = 0
        Self.enumerateLines(of: url) { line, _ in
            lineCounter += 1
            if lineCounter % Self.checkInterval == 0, handle.isCancelled { return false }
            if matcher.countMatches(in: line) > 0 {
                found = true
                return false
            }
            return true
        }
        return found
    }

    // MARK: - Chunked line reader

    /// A NUL anywhere in the first `binarySniffBytes` means binary — the
    /// extension list alone lets through no-extension blobs, and ISO-8859-1
    /// decoding never fails, so they would otherwise be scanned as if they were
    /// text. Also the rule `replaceInFile` checks before touching a file, so
    /// search and replace agree on what counts as searchable.
    private static func looksBinary(_ url: URL) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: binarySniffBytes)
        var count = 0
        while true {
            count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, binarySniffBytes) }
            if count < 0 && errno == EINTR { continue }
            break
        }
        guard count > 0 else { return false }
        return buffer.withUnsafeBufferPointer { memchr($0.baseAddress, 0, count) != nil }
    }

    /// Feeds `body` one LF-delimited line at a time (any trailing CR stripped),
    /// reading the file in fixed-size chunks. Peak memory is one chunk plus one
    /// line, so a 1 GB file costs no more than a 1 KB one. Return `false` from
    /// `body` to stop early.
    ///
    /// Files whose first bytes contain NUL are skipped as binary — the
    /// extension list alone lets through no-extension blobs, and ISO-8859-1
    /// decoding never fails, so they used to be scanned as if they were text.
    @discardableResult
    private static func enumerateLines(of url: URL,
                                       body: (UnsafeBufferPointer<UInt8>, Int) -> Bool) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // One buffer, reused for every chunk. FileHandle.read hands back a fresh
        // Data per call and those allocations pile up to roughly the size of the
        // file (measured: 86 MB resident for a 76 MB file); read(2) into a fixed
        // buffer stays flat at 6 MB.
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var carry = [UInt8]()
        var lineNumber = 1
        var sniffed = false
        var stopped = false

        // Appends to the pending line, refusing to grow past maxLineBytes.
        func appendCarry(_ pointer: UnsafePointer<UInt8>, _ count: Int) {
            guard count > 0 else { return }
            let room = maxLineBytes - carry.count
            guard room > 0 else { return }
            carry.append(contentsOf: UnsafeBufferPointer(start: pointer, count: min(room, count)))
        }

        func emitCarry() -> Bool {
            let length = carry.last == 0x0D ? carry.count - 1 : carry.count
            return carry.withUnsafeBufferPointer {
                body(UnsafeBufferPointer(start: $0.baseAddress, count: length), lineNumber)
            }
        }

        while !stopped {
            var bytesRead = 0
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, chunkSize) }
                if count < 0 && errno == EINTR { continue }
                bytesRead = max(0, count)
                break
            }
            if bytesRead == 0 { break }

            if !sniffed {
                sniffed = true
                let looksBinary = buffer.withUnsafeBufferPointer {
                    memchr($0.baseAddress, 0, min(bytesRead, binarySniffBytes)) != nil
                }
                if looksBinary { return false }
            }

            buffer.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                var index = 0
                while index < bytesRead {
                    guard let hit = memchr(base + index, 0x0A, bytesRead - index) else {
                        appendCarry(base + index, bytesRead - index)
                        return
                    }
                    let newline = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    let lineLength = newline - index

                    if carry.isEmpty {
                        // Whole line sits inside this chunk — no copy needed.
                        let trimmed = lineLength > 0 && base[newline - 1] == 0x0D ? lineLength - 1 : lineLength
                        if !body(UnsafeBufferPointer(start: base + index, count: trimmed), lineNumber) {
                            stopped = true
                            return
                        }
                    } else {
                        appendCarry(base + index, lineLength)
                        if !emitCarry() {
                            stopped = true
                            return
                        }
                        carry.removeAll(keepingCapacity: true)
                    }

                    lineNumber += 1
                    index = newline + 1
                }
            }
        }

        // Last line of a file that doesn't end in a newline.
        if !stopped && !carry.isEmpty {
            stopped = !emitCarry()
        }
        return !stopped
    }

    // MARK: - Line decoding

    private static func decode(_ buffer: UnsafeBufferPointer<UInt8>) -> String {
        if buffer.isEmpty { return "" }
        if let utf8 = String(bytes: buffer, encoding: .utf8) { return utf8 }
        return String(bytes: buffer, encoding: .isoLatin1) ?? ""
    }

    /// Decodes only as much of a matching line as the table can show, so a 10 MB
    /// minified line costs 8 KB here rather than 10 MB.
    private static func displayText(_ buffer: UnsafeBufferPointer<UInt8>, matchCount: Int) -> String {
        let text = decode(clamped(buffer, to: displayBytes))
        let trimmed = String(text.trimmingCharacters(in: .whitespaces).prefix(500))
        return matchCount > 1 ? "\(trimmed)  [\(matchCount) matches]" : trimmed
    }

    /// Truncates to `limit` bytes without splitting a UTF-8 sequence.
    private static func clamped(_ buffer: UnsafeBufferPointer<UInt8>,
                                to limit: Int) -> UnsafeBufferPointer<UInt8> {
        guard buffer.count > limit else { return buffer }
        var end = limit
        while end > 0 && (buffer[end] & 0xC0) == 0x80 { end -= 1 }
        return UnsafeBufferPointer(start: buffer.baseAddress, count: end)
    }

    // MARK: - Matcher

    /// Compiled once per run, then shared read-only by every worker.
    private struct Matcher {
        private let regex: NSRegularExpression?
        private let needle: String
        private let matchCase: Bool
        private let wholeWord: Bool
        /// Lowercased when the search is case-insensitive.
        private let needleBytes: [UInt8]
        /// Byte matching is only correct for ASCII needles; anything else goes
        /// through NSString so Unicode case folding stays right (Vietnamese,
        /// Turkish dotted I, ...).
        private let byteSearchable: Bool

        var canPrefilter: Bool { regex == nil }

        init(request: Request) throws {
            let options = request.options
            needle = request.needle
            matchCase = options.matchCase
            wholeWord = options.wholeWord

            if options.useRegex {
                var regexOptions: NSRegularExpression.Options = []
                if !options.matchCase { regexOptions.insert(.caseInsensitive) }
                regex = try NSRegularExpression(pattern: request.needle, options: regexOptions)
                needleBytes = []
                byteSearchable = false
            } else {
                regex = nil
                let isASCII = request.needle.utf8.allSatisfy { $0 < 0x80 }
                byteSearchable = isASCII && !request.needle.isEmpty
                let source = options.matchCase ? request.needle : request.needle.lowercased()
                needleBytes = isASCII ? Array(source.utf8) : []
            }
        }

        func countMatches(in line: UnsafeBufferPointer<UInt8>) -> Int {
            if byteSearchable { return countBytes(in: line) }
            return countInString(FileSearchService.decode(line))
        }

        private func countBytes(in line: UnsafeBufferPointer<UInt8>) -> Int {
            let needleLength = needleBytes.count
            let lineLength = line.count
            guard needleLength > 0, lineLength >= needleLength else { return 0 }

            let first = needleBytes[0]
            var count = 0
            var index = 0
            while index <= lineLength - needleLength {
                if fold(line[index]) != first {
                    index += 1
                    continue
                }
                var offset = 1
                while offset < needleLength, fold(line[index + offset]) == needleBytes[offset] {
                    offset += 1
                }
                if offset == needleLength {
                    if !wholeWord || isWholeWord(line, index, index + needleLength) { count += 1 }
                    index += needleLength
                } else {
                    index += 1
                }
            }
            return count
        }

        private func countInString(_ line: String) -> Int {
            let text = line as NSString
            var count = 0

            if let regex = regex {
                regex.enumerateMatches(in: line, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                    guard let range = match?.range, range.length > 0 else { return }
                    if wholeWord && !text.isWholeWord(range: range) { return }
                    count += 1
                }
            } else {
                let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
                var start = 0
                while start < text.length {
                    let range = text.range(of: needle, options: options,
                                           range: NSRange(location: start, length: text.length - start))
                    if range.location == NSNotFound { break }
                    if !wholeWord || text.isWholeWord(range: range) { count += 1 }
                    start = range.location + max(range.length, 1)
                }
            }
            return count
        }

        /// Replaces every match in one line. Matches are collected first and
        /// spliced in reverse so earlier ranges stay valid while editing.
        func replaceOccurrences(in line: String, with replacement: String) -> (String, Int) {
            let text = line as NSString

            if let regex = regex {
                let matches = regex
                    .matches(in: line, range: NSRange(location: 0, length: text.length))
                    .filter { $0.range.length > 0 && (!wholeWord || text.isWholeWord(range: $0.range)) }
                guard !matches.isEmpty else { return (line, 0) }
                let mutable = NSMutableString(string: line)
                for match in matches.reversed() {
                    // Template expansion ($1, $2...) resolved against the original line.
                    let expanded = regex.replacementString(for: match, in: line, offset: 0,
                                                           template: replacement)
                    mutable.replaceCharacters(in: match.range, with: expanded)
                }
                return (mutable as String, matches.count)
            }

            // Literal search runs on the original string, not a lowercased copy,
            // so ranges stay valid for case folds that change length.
            let options: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
            var ranges: [NSRange] = []
            var start = 0
            while start < text.length {
                let range = text.range(of: needle, options: options,
                                       range: NSRange(location: start, length: text.length - start))
                if range.location == NSNotFound { break }
                if !wholeWord || text.isWholeWord(range: range) { ranges.append(range) }
                start = range.location + max(range.length, 1)
            }
            guard !ranges.isEmpty else { return (line, 0) }
            let mutable = NSMutableString(string: line)
            for range in ranges.reversed() {
                mutable.replaceCharacters(in: range, with: replacement)
            }
            return (mutable as String, ranges.count)
        }

        @inline(__always)
        private func fold(_ byte: UInt8) -> UInt8 {
            guard !matchCase, byte >= 65, byte <= 90 else { return byte }
            return byte + 32
        }

        /// Byte-level word-boundary test. Everything above ASCII counts as a
        /// word byte, matching how `NSString.isWholeWord` treats letters.
        @inline(__always)
        private func isWholeWord(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
            if start > 0 && isWordByte(line[start - 1]) { return false }
            if end < line.count && isWordByte(line[end]) { return false }
            return true
        }

        @inline(__always)
        private func isWordByte(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true
            default: return byte >= 0x80
            }
        }
    }

    // MARK: - File filter

    private struct FileFilter {
        private let filterRegexes: [NSRegularExpression]
        private let matchesEveryName: Bool
        private let excludeDirs: Set<String>
        private let excludeRegexes: [NSRegularExpression]

        init(fileTypes: String, exclude: String) {
            let globs = fileTypes.isEmpty
                ? ["*"]
                : fileTypes.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            matchesEveryName = globs.contains("*") || globs.allSatisfy { $0.isEmpty }
            filterRegexes = matchesEveryName ? [] : globs.compactMap { FileFilter.regex(fromGlob: $0) }

            var dirs = Set<String>()
            var globPatterns: [NSRegularExpression] = []
            for pattern in exclude.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !pattern.isEmpty {
                if pattern.contains("*") || pattern.contains("?") {
                    if let regex = FileFilter.regex(fromGlob: pattern) { globPatterns.append(regex) }
                } else {
                    dirs.insert(pattern)
                }
            }
            excludeDirs = dirs
            excludeRegexes = globPatterns
        }

        func isExcludedDir(_ name: String) -> Bool { excludeDirs.contains(name) }

        func accepts(_ name: String) -> Bool {
            let range = NSRange(location: 0, length: (name as NSString).length)
            if !matchesEveryName,
               !filterRegexes.contains(where: { $0.firstMatch(in: name, range: range) != nil }) {
                return false
            }
            return !excludeRegexes.contains { $0.firstMatch(in: name, range: range) != nil }
        }

        /// Converts a shell glob (`*`, `?`) to an anchored regex, escaping every
        /// other metacharacter so patterns like `*.c++` compile instead of
        /// silently matching nothing.
        private static func regex(fromGlob glob: String) -> NSRegularExpression? {
            var pattern = "^"
            var literal = ""
            for character in glob {
                if character == "*" || character == "?" {
                    if !literal.isEmpty {
                        pattern += NSRegularExpression.escapedPattern(for: literal)
                        literal = ""
                    }
                    pattern += character == "*" ? ".*" : "."
                } else {
                    literal.append(character)
                }
            }
            if !literal.isEmpty { pattern += NSRegularExpression.escapedPattern(for: literal) }
            pattern += "$"
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }

    // MARK: - Shared state

    /// Accumulators shared by the workers. Every worker touches this exactly
    /// once per file, so the lock is never hot.
    private final class SharedState {
        private let lock = NSLock()
        private var pending: [DirSearchResult] = []
        private var emittedRows = 0
        private var matches = 0
        private var filesSearched = 0
        private var filesFound = 0
        private var scanning = true
        private var modified: [String] = []
        private var skipped: [String] = []

        var matchTotal: Int {
            lock.lock(); defer { lock.unlock() }
            return matches
        }

        func noteFound() {
            lock.lock(); filesFound += 1; lock.unlock()
        }

        func finishScanning() {
            lock.lock(); scanning = false; lock.unlock()
        }

        func noteModified(_ path: String) {
            lock.lock(); modified.append(path); lock.unlock()
        }

        func noteSkipped(_ path: String) {
            lock.lock(); skipped.append(path); lock.unlock()
        }

        func commitFile(results: [DirSearchResult], matches count: Int, rowCap: Int) {
            lock.lock()
            matches += count
            filesSearched += 1
            let room = rowCap - emittedRows
            if room > 0 && !results.isEmpty {
                let rows = results.count <= room ? results : Array(results.prefix(room))
                pending.append(contentsOf: rows)
                emittedRows += rows.count
            }
            lock.unlock()
        }

        func drain() -> ([DirSearchResult], Progress) {
            lock.lock()
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            let progress = Progress(matches: matches, filesSearched: filesSearched,
                                    filesFound: filesFound, stillScanning: scanning)
            lock.unlock()
            return (batch, progress)
        }

        func summary(cancelled: Bool, limitReached: Bool) -> Summary {
            lock.lock(); defer { lock.unlock() }
            return Summary(matches: matches, filesSearched: filesSearched,
                           modifiedPaths: modified, skippedPaths: skipped,
                           cancelled: cancelled, limitReached: limitReached)
        }
    }

    /// Main-thread-only latch that keeps a timer tick already queued behind the
    /// finish block from firing after `onFinish`.
    private final class DrainGate {
        var stopped = false
    }
}
