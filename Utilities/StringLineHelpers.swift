import Foundation

extension NSString {
    /// Returns the 0-based line number for the given character index.
    func lineNumber(at charIndex: Int) -> Int {
        var line = 0
        let end = min(charIndex, length)
        for i in 0..<end {
            if character(at: i) == 0x0A { line += 1 }
        }
        return line
    }

    /// Returns the total number of lines in the string (1-based).
    var lineCount: Int {
        var count = 1
        for i in 0..<length {
            if character(at: i) == 0x0A { count += 1 }
        }
        return count
    }

    /// Returns `true` if the range represents a whole word (not surrounded by alphanumerics or underscore).
    func isWholeWord(range: NSRange) -> Bool {
        let start = range.location
        let end = range.location + range.length
        if start > 0 {
            let ch = character(at: start - 1)
            if let s = Unicode.Scalar(ch),
               CharacterSet.alphanumerics.contains(s) || ch == 0x5F { return false }
        }
        if end < length {
            let ch = character(at: end)
            if let s = Unicode.Scalar(ch),
               CharacterSet.alphanumerics.contains(s) || ch == 0x5F { return false }
        }
        return true
    }
}
