import AppKit

extension NSTextStorage {
    /// Range-validated attribute setter. Silently ignores out-of-bounds ranges.
    func safeAddAttribute(_ key: NSAttributedString.Key, value: Any, range: NSRange) {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= length else { return }
        addAttribute(key, value: value, range: range)
    }
}
