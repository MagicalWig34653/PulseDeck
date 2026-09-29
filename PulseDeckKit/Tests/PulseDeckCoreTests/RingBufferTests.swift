import Testing
@testable import PulseDeckCore

@Suite("RingBuffer")
struct RingBufferTests {
    @Test func startsEmpty() {
        let buffer = RingBuffer<Int>(capacity: 3)
        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
        #expect(buffer.newest == nil)
        #expect(buffer.oldest == nil)
        #expect(!buffer.isFull)
    }

    @Test func appendsInOrderUntilFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        #expect(Array(buffer) == [1, 2])
        buffer.append(3)
        #expect(buffer.isFull)
        #expect(Array(buffer) == [1, 2, 3])
    }

    @Test func overwritesOldestWhenFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...7 { buffer.append(value) }
        #expect(buffer.count == 3)
        #expect(Array(buffer) == [5, 6, 7])
        #expect(buffer.oldest == 5)
        #expect(buffer.newest == 7)
        #expect(buffer[0] == 5)
        #expect(buffer[2] == 7)
    }

    @Test func countNeverExceedsCapacity() {
        var buffer = RingBuffer<Int>(capacity: 61)
        for value in 0..<10_000 { buffer.append(value) }
        #expect(buffer.count == 61)
        #expect(buffer.first == 10_000 - 61)
        #expect(buffer.last == 9_999)
    }

    @Test func capacityOne() {
        var buffer = RingBuffer<String>(capacity: 1)
        buffer.append("a")
        buffer.append("b")
        #expect(Array(buffer) == ["b"])
    }

    @Test func removeAllResets() {
        var buffer = RingBuffer<Int>(capacity: 2)
        for value in 1...5 { buffer.append(value) }
        buffer.removeAll()
        #expect(buffer.isEmpty)
        buffer.append(9)
        buffer.append(10)
        buffer.append(11)
        #expect(Array(buffer) == [10, 11])
    }

    @Test func reversedIterationUsesLogicalOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 1...6 { buffer.append(value) }
        #expect(Array(buffer.reversed()) == [6, 5, 4, 3])
    }
}

private struct Point: TimestampedSample, Equatable {
    var timestamp: MonotonicInstant
    var value: Double

    init(_ seconds: UInt64, _ value: Double = 0) {
        timestamp = MonotonicInstant(nanoseconds: seconds * 1_000_000_000)
        self.value = value
    }
}

@Suite("Nearest-sample lookup")
struct NearestSampleTests {
    private func instant(_ seconds: Double) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: UInt64(seconds * 1e9))
    }

    @Test func emptyBufferHasNoNearest() {
        let buffer = RingBuffer<Point>(capacity: 4)
        #expect(buffer.nearestIndex(to: instant(1)) == nil)
    }

    @Test func clampsToEnds() {
        var buffer = RingBuffer<Point>(capacity: 4)
        for second in [10, 11, 12] as [UInt64] { buffer.append(Point(second)) }
        #expect(buffer.nearestIndex(to: instant(0)) == 0)
        #expect(buffer.nearestIndex(to: instant(100)) == 2)
    }

    @Test func picksClosestSample() {
        var buffer = RingBuffer<Point>(capacity: 8)
        for second in [10, 11, 12, 15] as [UInt64] { buffer.append(Point(second)) }
        #expect(buffer.nearestIndex(to: instant(11.2)) == 1)
        #expect(buffer.nearestIndex(to: instant(11.8)) == 2)
        #expect(buffer.nearestIndex(to: instant(13.4)) == 2)
        #expect(buffer.nearestIndex(to: instant(13.6)) == 3)
        #expect(buffer.nearestIndex(to: instant(12)) == 2)
    }

    @Test func tieResolvesToOlderSample() {
        var buffer = RingBuffer<Point>(capacity: 4)
        buffer.append(Point(10))
        buffer.append(Point(12))
        #expect(buffer.nearestIndex(to: instant(11)) == 0)
    }

    @Test func worksAfterWrapAround() {
        var buffer = RingBuffer<Point>(capacity: 3)
        for second in 1...10 as ClosedRange<UInt64> { buffer.append(Point(second, Double(second))) }
        // Buffer holds 8, 9, 10.
        let index = buffer.nearestIndex(to: instant(8.9))
        #expect(index == 1)
        #expect(index.map { buffer[$0].value } == 9)
        #expect(buffer.nearestIndex(to: instant(1)) == 0)
    }

    @Test func drawingStartsWithTheSampleBeforeTheWindow() {
        var buffer = RingBuffer<Point>(capacity: 8)
        for second in [10, 11, 12, 13] as [UInt64] { buffer.append(Point(second)) }
        // The window starts between 11 and 12: 11 is drawn too, clipped at the left edge.
        #expect(buffer.drawingStartIndex(forWindowStart: instant(11.5)) == 1)
        #expect(buffer.drawingStartIndex(forWindowStart: instant(12)) == 1)
        #expect(buffer.drawingStartIndex(forWindowStart: instant(5)) == 0)
        #expect(buffer.drawingStartIndex(forWindowStart: instant(20)) == 3)
        #expect(RingBuffer<Point>(capacity: 2).drawingStartIndex(forWindowStart: instant(1)) == 0)
    }
}
