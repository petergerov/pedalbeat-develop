import Foundation
import Synchronization

final class AtomicFloat: @unchecked Sendable {
    private let storage: Atomic<UInt32>
    init(_ v: Float) { storage = Atomic(v.bitPattern) }
    var value: Float {
        get { Float(bitPattern: storage.load(ordering: .relaxed)) }
        set { storage.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

final class AtomicInt: @unchecked Sendable {
    private let storage: Atomic<Int>
    init(_ v: Int) { storage = Atomic(v) }
    var value: Int {
        get { storage.load(ordering: .relaxed) }
        set { storage.store(newValue, ordering: .relaxed) }
    }
}

extension UnsafeMutablePointer where Pointee == Float {
    func update(repeating value: Float, count: Int) {
        for i in 0..<count { self[i] = value }
    }
}
