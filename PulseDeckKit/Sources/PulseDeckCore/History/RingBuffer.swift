/// Fixed-capacity FIFO buffer with O(1) append that overwrites the oldest element when full
/// (SPEC §6, §29). Memory is bounded by `capacity`; after warm-up, appends do not allocate.
///
/// Indices are logical: `0` is the oldest element, `count - 1` the newest.
public struct RingBuffer<Element>: RandomAccessCollection {
    public let capacity: Int
    /// Grows once up to `capacity`, then elements are overwritten in place.
    private var storage: ContiguousArray<Element>
    /// Physical index of the oldest element (only non-zero once the buffer is full).
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }
    public var isFull: Bool { storage.count == capacity }

    public subscript(position: Int) -> Element {
        precondition(position >= 0 && position < storage.count, "RingBuffer index out of range")
        return storage[physicalIndex(position)]
    }

    /// Appends `element`, evicting the oldest element when the buffer is full. O(1).
    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Newest element, if any.
    public var newest: Element? { isEmpty ? nil : self[count - 1] }
    /// Oldest element, if any.
    public var oldest: Element? { isEmpty ? nil : self[0] }

    private func physicalIndex(_ logical: Int) -> Int {
        let index = head + logical
        return index < capacity ? index : index - capacity
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

/// An element with a monotonic timestamp. Timestamps in a history buffer are strictly
/// increasing because they are appended in sampling order.
public protocol TimestampedSample {
    var timestamp: MonotonicInstant { get }
}

extension RingBuffer where Element: TimestampedSample {
    /// Logical index of the sample whose timestamp is closest to `instant`, or `nil` if empty.
    /// O(log n) binary search; used by chart hover inspection (SPEC §12, §29). Ties resolve
    /// to the older sample.
    public func nearestIndex(to instant: MonotonicInstant) -> Int? {
        guard !isEmpty else { return nil }
        // First index whose timestamp is >= instant.
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].timestamp < instant {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return 0 }
        if low == count { return count - 1 }
        let before = instant.nanoseconds - self[low - 1].timestamp.nanoseconds
        let after = self[low].timestamp.nanoseconds - instant.nanoseconds
        return after < before ? low : low - 1
    }
}
