@main
struct KernelLogRingTests {
    static func main() {
        validatesStorageAndRoundTripsRecords()
        overwritesWithExplicitLossAccounting()
        preservesSequenceAtExhaustion()
        print("kernel log ring host tests: 3 groups passed")
    }

    private static func validatesStorageAndRoundTripsRecords() {
        withStorage(byteCount: KernelLogRing.recordByteCount - 1) { bytes in
            expect(KernelLogRing(storage: bytes) == nil, "short storage accepted")
        }
        withStorage(byteCount: KernelLogRing.recordByteCount * 2 + 7) { bytes in
            guard var ring = KernelLogRing(storage: bytes) else {
                fail("valid storage rejected")
            }
            expect(ring.capacity == 2, "partial record changed capacity")
            let event = KernelLogEvent(
                timestampTicks: 123,
                level: .warning,
                subsystem: .graphics,
                eventCode: 0x1020_3040,
                processorID: 3,
                flags: 0x5566_7788,
                argument0: 0x0102_0304_0506_0708,
                argument1: UInt64.max
            )
            expect(
                ring.append(event) == .appended(
                    sequence: 1,
                    overwrittenSequence: nil
                ),
                "first append result"
            )
            expect(
                ring.entry(sequence: 1)
                    == .entry(KernelLogEntry(sequence: 1, event: event)),
                "record did not round trip"
            )
            expect(ring.entry(sequence: 2) == .notYetWritten, "future lookup")
            expect(ring.entry(atChronologicalIndex: 0)?.event == event, "index")
            expect(ring.entry(atChronologicalIndex: -1) == nil, "negative index")
            expect(ring.entry(atChronologicalIndex: 1) == nil, "large index")
        }
    }

    private static func overwritesWithExplicitLossAccounting() {
        withStorage(byteCount: KernelLogRing.recordByteCount * 2) { bytes in
            var ring = KernelLogRing(storage: bytes)!
            _ = ring.append(event(code: 10))
            _ = ring.append(event(code: 20))
            expect(
                ring.append(event(code: 30))
                    == .appended(sequence: 3, overwrittenSequence: 1),
                "overwrite result"
            )
            expect(
                ring.entry(sequence: 1) == .lost(oldestAvailableSequence: 2),
                "lost lookup"
            )
            expect(ring.entry(atChronologicalIndex: 0)?.event.eventCode == 20, "oldest")
            expect(ring.entry(atChronologicalIndex: 1)?.event.eventCode == 30, "newest")
            expect(
                ring.statistics == KernelLogStatistics(
                    capacity: 2,
                    retainedCount: 2,
                    oldestSequence: 2,
                    newestSequence: 3,
                    nextSequence: 4,
                    overwrittenEntryCount: 1,
                    rejectedEntryCount: 0
                ),
                "overwrite statistics"
            )
            expect(ring.statistics.didLoseEntries, "loss flag")
        }
    }

    private static func preservesSequenceAtExhaustion() {
        withStorage(byteCount: KernelLogRing.recordByteCount * 2) { bytes in
            var ring = KernelLogRing(
                storage: bytes,
                firstSequence: UInt64.max - 1
            )!
            expect(
                ring.append(event(code: 1))
                    == .appended(
                        sequence: UInt64.max - 1,
                        overwrittenSequence: nil
                    ),
                "penultimate sequence"
            )
            expect(
                ring.append(event(code: 2))
                    == .appended(
                        sequence: UInt64.max,
                        overwrittenSequence: nil
                    ),
                "final sequence"
            )
            expect(ring.nextSequence == nil, "exhausted next sequence")
            expect(ring.newestSequence == UInt64.max, "exhausted newest")
            expect(ring.append(event(code: 3)) == .sequenceExhausted, "accepted wrap")
            expect(ring.statistics.rejectedEntryCount == 1, "rejected count")
            expect(ring.statistics.didLoseEntries, "exhaustion loss flag")
        }
    }

    private static func event(code: UInt32) -> KernelLogEvent {
        KernelLogEvent(
            timestampTicks: UInt64(code),
            level: .info,
            subsystem: .kernel,
            eventCode: code
        )
    }

    private static func withStorage(
        byteCount: Int,
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 1
        )
        defer { pointer.deallocate() }
        body(UnsafeMutableRawBufferPointer(start: pointer, count: byteCount))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}
