import Foundation

/// Thread-safe boolean flag for cancellation signaling across threads.
class AtomicFlag {
    private var _value = false
    private let lock = NSLock()
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ newValue: Bool) { lock.lock(); _value = newValue; lock.unlock() }
}

/// Virtual key code constants used across the app.
enum KeyCode {
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
}
