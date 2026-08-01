import AppKit

/// Singleton providing file I/O and open/save panels.
/// Ported from the file-handling portions of Java TextEditor.java.
class FileService {

    static let shared = FileService()

    // MARK: - Line endings

    /// Source line-ending style. The editor stores text internally with LF
    /// only; on save we restore the original style so we don't mix endings
    /// in a file that came from Windows.
    enum LineEnding {
        case lf      // \n   — Unix, macOS
        case crlf    // \r\n — Windows
        case cr      // \r   — classic Mac (rare)
    }

    /// Detect the dominant line ending in decoded text. Probes the leading
    /// 64K code units.
    ///
    /// This runs on the decoded string rather than the raw bytes because a
    /// UTF-16 file spells CRLF `0D 00 0A 00` — a byte-level scan sees the
    /// interleaved NULs as ordinary characters and mistakes every ending.
    static func detectLineEnding(in text: String) -> LineEnding {
        let ns = text as NSString
        let end = min(ns.length, 65536)
        var crlf = 0, lf = 0, cr = 0
        var i = 0
        while i < end {
            let c = ns.character(at: i)
            if c == 0x0D /* \r */ {
                if i + 1 < end && ns.character(at: i + 1) == 0x0A {
                    crlf += 1
                    i += 2
                    continue
                }
                cr += 1
            } else if c == 0x0A /* \n */ {
                lf += 1
            }
            i += 1
        }
        if crlf >= lf && crlf >= cr && crlf > 0 { return .crlf }
        if cr > lf { return .cr }
        return .lf
    }

    /// Convert a string from any line ending to LF for in-memory storage.
    static func normalizeToLF(_ s: String, from ending: LineEnding) -> String {
        switch ending {
        case .lf: return s
        case .crlf: return s.replacingOccurrences(of: "\r\n", with: "\n")
        case .cr: return s.replacingOccurrences(of: "\r", with: "\n")
        }
    }

    /// Convert a string from LF back to the requested line ending for save.
    static func denormalize(_ s: String, to ending: LineEnding) -> String {
        switch ending {
        case .lf: return s
        case .crlf: return s.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return s.replacingOccurrences(of: "\n", with: "\r")
        }
    }

    // MARK: - Encodings

    /// On-disk text encoding. Recorded at open and replayed at save so a file
    /// keeps the encoding it arrived in — rewriting a Windows UTF-16 file as
    /// UTF-8 is a silent, whole-file change to something we were only asked
    /// to edit a line of.
    enum TextEncoding {
        case utf8
        case utf16LE, utf16BE
        case utf32LE, utf32BE
        case isoLatin1

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8:      return .utf8
            case .utf16LE:   return .utf16LittleEndian
            case .utf16BE:   return .utf16BigEndian
            case .utf32LE:   return .utf32LittleEndian
            case .utf32BE:   return .utf32BigEndian
            case .isoLatin1: return .isoLatin1
            }
        }

        /// Byte-order mark for this encoding, written only if the file we read
        /// had one. The explicit-endian `String.Encoding` values never emit a
        /// BOM themselves, so we prepend these by hand.
        var bom: [UInt8] {
            switch self {
            case .utf8:      return [0xEF, 0xBB, 0xBF]
            case .utf16LE:   return [0xFF, 0xFE]
            case .utf16BE:   return [0xFE, 0xFF]
            case .utf32LE:   return [0xFF, 0xFE, 0x00, 0x00]
            case .utf32BE:   return [0x00, 0x00, 0xFE, 0xFF]
            case .isoLatin1: return []
            }
        }

        var displayName: String {
            switch self {
            case .utf8:      return "UTF-8"
            case .utf16LE:   return "UTF-16 LE"
            case .utf16BE:   return "UTF-16 BE"
            case .utf32LE:   return "UTF-32 LE"
            case .utf32BE:   return "UTF-32 BE"
            case .isoLatin1: return "ISO-8859-1"
            }
        }
    }

    /// Identifies the encoding from a leading byte-order mark, if there is one.
    /// UTF-32LE has to be tested before UTF-16LE: its BOM starts with the
    /// UTF-16LE one.
    static func detectBOM(_ data: Data) -> TextEncoding? {
        func hasPrefix(_ bytes: [UInt8]) -> Bool {
            guard data.count >= bytes.count else { return false }
            for (offset, byte) in bytes.enumerated() where data[data.startIndex + offset] != byte {
                return false
            }
            return true
        }
        for encoding in [TextEncoding.utf32LE, .utf32BE, .utf16LE, .utf16BE, .utf8]
        where hasPrefix(encoding.bom) {
            return encoding
        }
        return nil
    }

    /// Detects BOM-less UTF-16 from the NUL pattern that ASCII-range text
    /// produces: one byte of every pair is zero, and which side it falls on
    /// gives the endianness.
    ///
    /// Only consulted for files with no BOM, and only ahead of the binary
    /// sniff — a wrong guess here can at worst open a file that would
    /// otherwise have been rejected outright, never mangle one that decodes
    /// cleanly as UTF-8.
    static func sniffBOMlessUTF16(_ data: Data) -> TextEncoding? {
        let probe = data.prefix(8192)
        guard probe.count >= 16 else { return nil }

        var evenNULs = 0, oddNULs = 0
        for (offset, byte) in probe.enumerated() where byte == 0x00 {
            if offset % 2 == 0 { evenNULs += 1 } else { oddNULs += 1 }
        }

        // Text, not stray NULs: most pairs must carry one, all on one side.
        let threshold = (probe.count / 2) / 2
        if oddNULs > threshold && evenNULs == 0 { return .utf16LE }
        if evenNULs > threshold && oddNULs == 0 { return .utf16BE }
        return nil
    }

    // MARK: - Binary Extension Detection

    /// Extensions that should never be opened as text (ported from Java BINARY_EXTENSIONS).
    static let binaryExtensions: Set<String> = [
        // Images
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".tiff", ".tif",
        ".webp", ".svg", ".psd", ".raw", ".cr2", ".nef", ".heic", ".avif",
        // Audio
        ".mp3", ".wav", ".flac", ".aac", ".ogg", ".wma", ".m4a", ".opus", ".aiff",
        // Video
        ".mp4", ".avi", ".mkv", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".mpg", ".mpeg", ".3gp",
        // Executables & libraries
        ".exe", ".dll", ".so", ".dylib", ".o", ".obj", ".a", ".lib",
        ".bin", ".app", ".msi", ".deb", ".rpm", ".dmg", ".iso",
        // Archives
        ".zip", ".gz", ".tar", ".bz2", ".xz", ".7z", ".rar", ".zst", ".lz4", ".tgz",
        ".jar", ".war", ".ear",
        // Documents (binary formats)
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp",
        // Compiled / bytecode
        ".class", ".pyc", ".pyo", ".beam", ".wasm",
        // Databases
        ".db", ".sqlite", ".sqlite3", ".mdb",
        // Fonts
        ".ttf", ".otf", ".woff", ".woff2", ".eot",
        // Other binary
        ".dat", ".pak", ".res", ".dex", ".apk", ".ipa"
    ]

    /// Returns `true` if the file extension indicates a binary format.
    static func isBinaryFile(_ url: URL) -> Bool {
        let ext = "." + url.pathExtension.lowercased()
        return binaryExtensions.contains(ext)
    }

    /// Returns `true` if the data appears to be binary based on a NUL-byte
    /// sniff of the leading 8KB. Many text-extension files (.txt, .log) can
    /// hold binary garbage; this catches them before we render gibberish.
    static func looksBinary(_ data: Data) -> Bool {
        let probe = data.prefix(8192)
        return probe.contains(0x00)
    }

    // MARK: - External Change Detection

    /// What a file looked like on disk the last time we read or wrote it.
    /// Compared again just before an overwrite so another program's edits
    /// aren't discarded without the user hearing about it.
    struct DiskState: Equatable {
        let modificationDate: Date
        let size: Int64
        let inode: UInt64
    }

    /// Current disk state of `url`, or `nil` if it doesn't exist (or can't be
    /// stat'd) — callers treat that as "nothing to conflict with".
    static func diskState(of url: URL) -> DiskState? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return DiskState(
            modificationDate: date,
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
    }

    // MARK: - File Reading

    /// Result of reading a text file: the LF-normalized content, the detected
    /// source line ending and encoding (so save can restore both), and the
    /// disk state the content came from.
    struct ReadResult {
        let content: String
        let lineEnding: LineEnding
        let encoding: TextEncoding
        let hasBOM: Bool
        let diskState: DiskState?
    }

    /// Read file content, resolving the encoding from a BOM when there is one
    /// and from the byte pattern otherwise. Throws if the file looks binary.
    /// Returns the content normalized to LF for in-memory use.
    func readFile(at url: URL) throws -> ReadResult {
        // Stat before reading: if the file changes while we read it, we'd
        // rather record the older state and warn on the next save than record
        // the newer one and overwrite silently.
        let diskState = FileService.diskState(of: url)
        let data = try Data(contentsOf: url)
        let decoded = try FileService.decode(data)
        let lineEnding = FileService.detectLineEnding(in: decoded.text)

        return ReadResult(
            content: FileService.normalizeToLF(decoded.text, from: lineEnding),
            lineEnding: lineEnding,
            encoding: decoded.encoding,
            hasBOM: decoded.hasBOM,
            diskState: diskState
        )
    }

    /// Decodes raw file bytes to text, reporting the encoding it settled on
    /// and whether a BOM was consumed. A BOM is stripped from the returned
    /// text so it can't show up as an invisible leading character.
    static func decode(_ data: Data) throws -> (text: String, encoding: TextEncoding, hasBOM: Bool) {
        if let encoding = detectBOM(data) {
            guard let text = String(data: data.dropFirst(encoding.bom.count),
                                    encoding: encoding.stringEncoding) else {
                throw decodeError
            }
            return (text, encoding, true)
        }

        // BOM-less UTF-16 is mostly NUL bytes, so it has to be settled before
        // the binary sniff — otherwise every UTF-16 file exported by a Windows
        // editor is rejected as binary.
        if let encoding = sniffBOMlessUTF16(data),
           let text = String(data: data, encoding: encoding.stringEncoding) {
            return (text, encoding, false)
        }

        if looksBinary(data) {
            throw NSError(
                domain: "FileService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "File appears to be binary"]
            )
        }

        if let text = String(data: data, encoding: .utf8) { return (text, .utf8, false) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .isoLatin1, false) }
        throw decodeError
    }

    private static let decodeError = NSError(
        domain: "FileService",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Cannot decode file"]
    )

    // MARK: - File Writing

    /// Save a string to the given URL, converting LF back to the requested
    /// line ending and re-encoding to the file's original encoding so it
    /// round-trips unchanged apart from the edit. Returns the new disk state.
    @discardableResult
    func saveFile(content: String, to url: URL,
                  lineEnding: LineEnding = .lf,
                  encoding: TextEncoding = .utf8,
                  hasBOM: Bool = false) throws -> DiskState? {
        let output = FileService.denormalize(content, to: lineEnding)

        // ISO-8859-1 (and the fixed-width UTF forms, for unpaired surrogates)
        // can't represent everything the user may have typed. Refuse rather
        // than write a lossy file or silently promote it to UTF-8.
        guard var data = output.data(using: encoding.stringEncoding) else {
            throw NSError(domain: "FileService", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "This text can't be written as \(encoding.displayName). "
                    + "Use Save As to write a new file in UTF-8."
            ])
        }
        if hasBOM { data = Data(encoding.bom) + data }

        try FileService.writePreservingMetadata(data, to: url)
        return FileService.diskState(of: url)
    }

    /// Writes `data` to `url`, keeping the parts of the file's identity that
    /// an editor has no business resetting.
    ///
    /// `write(atomically:)` builds a brand-new file and renames it over the
    /// old one, which drops the original's permissions, ACL and extended
    /// attributes and breaks any hard link to it. Here the replacement is
    /// still atomic, but the metadata is carried across first; and a file with
    /// more than one link is written in place so its other names keep seeing
    /// the same content.
    private static func writePreservingMetadata(_ data: Data, to url: URL) throws {
        // A symlink names a file to edit, not a file to replace.
        let target = url.resolvingSymlinksInPath()
        let path = target.path

        var info = stat()
        guard stat(path, &info) == 0 else {
            // Nothing there yet, so there's no metadata to preserve.
            try data.write(to: target, options: .atomic)
            return
        }

        // Replacing a hard-linked file would silently detach it from its other
        // names, so trade atomicity for identity in that (rare) case.
        guard info.st_nlink <= 1 else {
            try writeInPlace(data, toPath: path)
            return
        }

        // Leave room for the dot, the suffix and the 255-byte name limit, so
        // saving a file with a very long name doesn't fail on the temp copy.
        let stem = target.lastPathComponent.prefix(200)
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).save-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: temp)

            // ACL and xattrs via copyfile; mode and owner by hand. Deliberately
            // not COPYFILE_SECURITY/COPYFILE_STAT — those also copy the old
            // timestamps onto the new content, leaving a file we just wrote
            // looking untouched to make, rsync and friends. All best-effort:
            // losing an xattr is not a reason to fail a save.
            copyfile(path, temp.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
            chmod(temp.path, info.st_mode & 0o7777)
            chown(temp.path, info.st_uid, info.st_gid)

            guard rename(temp.path, path) == 0 else {
                throw posixError(errno, "replace", target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Truncates and rewrites the file itself, keeping its inode. Used only
    /// for hard-linked files, where swapping in a replacement would be worse
    /// than the crash window this opens.
    private static func writeInPlace(_ data: Data, toPath path: String) throws {
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { throw posixError(errno, "open", URL(fileURLWithPath: path)) }
        defer { close(fd) }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, base + written, buffer.count - written)
                guard n > 0 else { throw posixError(errno, "write", URL(fileURLWithPath: path)) }
                written += n
            }
        }
        fsync(fd)
    }

    private static func posixError(_ code: Int32, _ verb: String, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey:
                "Could not \(verb) \(url.lastPathComponent): \(String(cString: strerror(code)))"
        ])
    }
}
