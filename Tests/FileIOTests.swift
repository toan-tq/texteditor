import AppKit

/// Checks that a file survives a round trip through the editor unchanged
/// apart from the edit itself: same encoding, same BOM, same line endings,
/// same permissions and extended attributes, same inode where it matters.
///
/// These are the failures nobody notices until a diff is enormous or a build
/// system stops rebuilding, so they are worth pinning down.
///
/// Shares the harness in `EditIndexTests`; run with `Tests/run.sh`.
enum FileIOTests {

    // MARK: - Scratch files

    static let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("texteditor-fileio-tests-\(getpid())")

    static func makeScratch() {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    static func cleanUpScratch() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes raw bytes to a fresh scratch file and hands back its URL.
    static func file(_ name: String, _ bytes: [UInt8]) -> URL {
        let url = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url
    }

    static func bytes(of url: URL) -> [UInt8] {
        [UInt8]((try? Data(contentsOf: url)) ?? Data())
    }

    /// Encodes `text` the way another editor would have written the file.
    static func encoded(_ text: String, _ encoding: FileService.TextEncoding, bom: Bool) -> [UInt8] {
        (bom ? encoding.bom : []) + [UInt8](text.data(using: encoding.stringEncoding)!)
    }

    // MARK: - Encoding round trips

    /// Every encoding a file may arrive in has to come back out the same way.
    /// The UTF-16 cases are the ones that used to fail outright: the NUL bytes
    /// in the low half of each ASCII code unit tripped the binary sniff, so a
    /// file exported from a Windows editor could not be opened at all.
    static func testEncodingRoundTrip() {
        let sample = "line one\nsecond \u{00E9}\u{4E5D} line\nthird\n"
        let cases: [(String, FileService.TextEncoding, Bool)] = [
            ("utf8-plain",    .utf8,    false),
            ("utf8-bom",      .utf8,    true),
            ("utf16le-bom",   .utf16LE, true),
            ("utf16be-bom",   .utf16BE, true),
            ("utf16le-nobom", .utf16LE, false),
            ("utf16be-nobom", .utf16BE, false),
            ("utf32le-bom",   .utf32LE, true),
            ("utf32be-bom",   .utf32BE, true),
        ]

        for (name, encoding, bom) in cases {
            let original = encoded(sample, encoding, bom: bom)
            let url = file(name, original)

            guard let read = try? FileService.shared.readFile(at: url) else {
                EditIndexTests.expect(false, "\(name): could not be opened at all")
                continue
            }

            EditIndexTests.expectEqual(read.content, sample, "\(name): decoded content")
            EditIndexTests.expectEqual(read.encoding, encoding, "\(name): detected encoding")
            EditIndexTests.expectEqual(read.hasBOM, bom, "\(name): detected BOM")

            // Saving it back untouched must reproduce the file byte for byte.
            _ = try? FileService.shared.saveFile(content: read.content, to: url,
                                                 lineEnding: read.lineEnding,
                                                 encoding: read.encoding, hasBOM: read.hasBOM)
            EditIndexTests.expectEqual(bytes(of: url), original, "\(name): bytes after save")
        }
    }

    /// A byte that ISO-8859-1 has no room for must fail the save loudly rather
    /// than be dropped or quietly promoted to UTF-8.
    static func testUndecodableSaveIsRefused() {
        let url = file("latin1", encoded("caf\u{00E9}\n", .isoLatin1, bom: false))
        guard let read = try? FileService.shared.readFile(at: url) else {
            EditIndexTests.expect(false, "latin1: could not be opened")
            return
        }
        EditIndexTests.expectEqual(read.encoding, .isoLatin1, "latin1: detected encoding")

        var refused = false
        do {
            try FileService.shared.saveFile(content: "caf\u{00E9} \u{4E5D}\n", to: url,
                                            encoding: .isoLatin1, hasBOM: false)
        } catch {
            refused = true
        }
        EditIndexTests.expect(refused, "latin1: save of unrepresentable text should throw")
        EditIndexTests.expectEqual(bytes(of: url), encoded("caf\u{00E9}\n", .isoLatin1, bom: false),
                                   "latin1: file untouched after refused save")
    }

    /// Line endings are counted in the decoded text, so CRLF has to be spotted
    /// in a UTF-16 file too — where it is `0D 00 0A 00` rather than `0D 0A`.
    static func testLineEndingDetectionAcrossEncodings() {
        let url = file("crlf-utf16", encoded("a\r\nb\r\nc", .utf16LE, bom: true))
        let read = try? FileService.shared.readFile(at: url)
        EditIndexTests.expectEqual(read?.lineEnding, .crlf, "utf16 CRLF: detected line ending")
        EditIndexTests.expectEqual(read?.content, "a\nb\nc", "utf16 CRLF: normalized to LF")

        let lf = file("lf-utf8", encoded("a\nb\n", .utf8, bom: false))
        EditIndexTests.expectEqual((try? FileService.shared.readFile(at: lf))?.lineEnding, .lf,
                                   "utf8 LF: detected line ending")
    }

    /// The UTF-16 sniff must not turn the binary check into a rubber stamp.
    static func testBinaryStillRejected() {
        // Random-looking bytes with NULs on both sides of the pair boundary.
        var junk: [UInt8] = []
        for i in 0..<512 { junk.append(UInt8((i &* 37) % 251)) }
        junk.insert(contentsOf: [0x00, 0x00, 0x01, 0x00], at: 4)

        let url = file("junk.bin", junk)
        var rejected = false
        do { _ = try FileService.shared.readFile(at: url) } catch { rejected = true }
        EditIndexTests.expect(rejected, "binary: NUL-laden junk should still be rejected")
    }

    // MARK: - File identity

    static func mode(of url: URL) -> mode_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return info.st_mode & 0o7777
    }

    static func inode(of url: URL) -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return UInt64(info.st_ino)
    }

    static func markXattr(_ url: URL, _ value: String) {
        _ = value.withCString { setxattr(url.path, "com.texteditor.test", $0, strlen($0), 0, 0) }
    }

    static func xattrValue(_ url: URL) -> String? {
        let size = getxattr(url.path, "com.texteditor.test", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, "com.texteditor.test", &buffer, size, 0, 0) == size else { return nil }
        return String(bytes: buffer, encoding: .utf8)
    }

    /// A save must not reset the things that describe the file rather than its
    /// contents. `write(atomically:)` dropped all of these.
    static func testSavePreservesPermissionsAndXattrs() {
        let url = file("metadata.txt", Array("original\n".utf8))
        chmod(url.path, 0o640)
        markXattr(url, "keepme")

        _ = try? FileService.shared.saveFile(content: "rewritten\n", to: url)

        EditIndexTests.expectEqual(mode(of: url), mode_t(0o640), "metadata: permissions preserved")
        EditIndexTests.expectEqual(xattrValue(url), "keepme", "metadata: xattr preserved")
        EditIndexTests.expectEqual(String(bytes: bytes(of: url), encoding: .utf8), "rewritten\n",
                                   "metadata: content written")
    }

    /// A hard-linked file is written in place, so its other names see the new
    /// text. Replacing it would have quietly detached the link.
    static func testSaveKeepsHardLinks() {
        let url = file("linked.txt", Array("original\n".utf8))
        let link = scratch.appendingPathComponent("linked-alias.txt")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.linkItem(at: url, to: link)

        let before = inode(of: url)
        _ = try? FileService.shared.saveFile(content: "rewritten\n", to: url)

        EditIndexTests.expectEqual(inode(of: url), before, "hard link: inode preserved")
        EditIndexTests.expectEqual(String(bytes: bytes(of: link), encoding: .utf8), "rewritten\n",
                                   "hard link: other name sees new content")
    }

    /// Saving through a symlink edits the file it points at instead of
    /// replacing the link with a regular file.
    static func testSaveFollowsSymlinks() {
        let target = file("symlink-target.txt", Array("original\n".utf8))
        let link = scratch.appendingPathComponent("symlink-alias.txt")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        _ = try? FileService.shared.saveFile(content: "rewritten\n", to: link)

        let stillALink = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        EditIndexTests.expect(stillALink, "symlink: link not replaced by a regular file")
        EditIndexTests.expectEqual(String(bytes: bytes(of: target), encoding: .utf8), "rewritten\n",
                                   "symlink: target rewritten")
    }

    /// Saving new content has to leave a fresh modification time — copying the
    /// old one across would make the file look untouched to build tools.
    static func testSaveUpdatesModificationTime() {
        let url = file("mtime.txt", Array("original\n".utf8))
        var old = [timeval(tv_sec: 946_684_800, tv_usec: 0), timeval(tv_sec: 946_684_800, tv_usec: 0)]
        utimes(url.path, &old)

        _ = try? FileService.shared.saveFile(content: "rewritten\n", to: url)

        let now = FileService.diskState(of: url)?.modificationDate ?? .distantPast
        EditIndexTests.expect(now.timeIntervalSince1970 > 1_000_000_000,
                              "mtime: save should stamp a current time, got \(now)")
    }

    // MARK: - External change detection

    /// The state recorded at open must stop matching once another program
    /// writes the file — that comparison is the whole overwrite guard.
    static func testDiskStateSpotsExternalWrites() {
        let url = file("watched.txt", Array("original\n".utf8))
        guard let read = try? FileService.shared.readFile(at: url) else {
            EditIndexTests.expect(false, "diskState: file could not be opened")
            return
        }
        EditIndexTests.expect(read.diskState != nil, "diskState: recorded at open")
        EditIndexTests.expectEqual(FileService.diskState(of: url), read.diskState,
                                   "diskState: unchanged file still matches")

        // Someone else edits it. Same length, so this leans on mtime.
        try? Data("modified\n".utf8).write(to: url)
        var future = [timeval(tv_sec: 2_000_000_000, tv_usec: 0),
                      timeval(tv_sec: 2_000_000_000, tv_usec: 0)]
        utimes(url.path, &future)

        EditIndexTests.expect(FileService.diskState(of: url) != read.diskState,
                              "diskState: external write should be detected")

        // And our own save re-baselines it, so the next save doesn't false-alarm.
        let afterSave = try? FileService.shared.saveFile(content: "ours\n", to: url)
        EditIndexTests.expectEqual(FileService.diskState(of: url), afterSave ?? nil,
                                   "diskState: refreshed by save")
    }

    static func testMissingFileHasNoDiskState() {
        let url = scratch.appendingPathComponent("never-existed.txt")
        EditIndexTests.expect(FileService.diskState(of: url) == nil,
                              "diskState: nil for a file that isn't there")
    }

    /// Saving to a path that doesn't exist yet still has to produce the file.
    static func testSaveCreatesNewFile() {
        let url = scratch.appendingPathComponent("brand-new.txt")
        try? FileManager.default.removeItem(at: url)

        _ = try? FileService.shared.saveFile(content: "hello\n", to: url, lineEnding: .crlf)

        EditIndexTests.expectEqual(String(bytes: bytes(of: url), encoding: .utf8), "hello\r\n",
                                   "new file: created with requested line ending")
    }

    // MARK: - Entry point

    static func all() {
        makeScratch()
        defer { cleanUpScratch() }

        EditIndexTests.run("encodings round-trip byte for byte", testEncodingRoundTrip)
        EditIndexTests.run("unrepresentable text fails the save", testUndecodableSaveIsRefused)
        EditIndexTests.run("line endings detected in any encoding", testLineEndingDetectionAcrossEncodings)
        EditIndexTests.run("binary files are still rejected", testBinaryStillRejected)
        EditIndexTests.run("save preserves permissions and xattrs", testSavePreservesPermissionsAndXattrs)
        EditIndexTests.run("save keeps hard links intact", testSaveKeepsHardLinks)
        EditIndexTests.run("save follows symlinks", testSaveFollowsSymlinks)
        EditIndexTests.run("save updates the modification time", testSaveUpdatesModificationTime)
        EditIndexTests.run("disk state spots external writes", testDiskStateSpotsExternalWrites)
        EditIndexTests.run("missing file has no disk state", testMissingFileHasNoDiskState)
        EditIndexTests.run("save creates a new file", testSaveCreatesNewFile)
    }
}
