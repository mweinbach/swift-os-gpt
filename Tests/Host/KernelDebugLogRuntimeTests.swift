@main
struct KernelDebugLogRuntimeTests {
    static func main() {
        retainsCanonicalConsoleBytesAcrossChunks()
        marksExactBoundaryAsOneCompleteChunk()
        preservesMonotonicSequenceAcrossProducers()
        retainsStructuredBootEpochBeforeConsole()
        retainsWholeMessageWhenSerialEmissionStops()
        print("kernel debug log runtime host tests: 5 groups passed")
    }

    private static func retainsCanonicalConsoleBytesAcrossChunks() {
        withLog(capacity: 8) { log in
            let input = Array("SWIFTOS:PANIC:DISPLAY\n1234567890".utf8)
            input.withUnsafeBufferPointer { bytes in
                log.appendCanonical(
                    bytes,
                    timestampTicks: 900,
                    processorID: 3,
                    source: .earlyConsole
                )
            }

            let expected = Array("SWIFTOS:PANIC:DISPLAY\r\n1234567890".utf8)
            expect(reconstructedBytes(log) == expected, "canonical bytes")
            expect(log.statistics.retainedCount == 3, "chunk count")

            let first = chunk(log, sequence: 1)
            let second = chunk(log, sequence: 2)
            let third = chunk(log, sequence: 3)
            expect(first.isFirst && !first.isLast, "first boundary flags")
            expect(!second.isFirst && !second.isLast, "middle boundary flags")
            expect(!third.isFirst && third.isLast, "last boundary flags")
            expect(first.source == .earlyConsole, "first source")
            expect(third.source == .earlyConsole, "last source")
            expect(event(log, sequence: 1).timestampTicks == 900, "timestamp")
            expect(event(log, sequence: 3).processorID == 3, "processor")
        }
    }

    private static func marksExactBoundaryAsOneCompleteChunk() {
        withLog(capacity: 2) { log in
            let bytes = Array("0123456789abcdef".utf8)
            bytes.withUnsafeBufferPointer {
                log.appendCanonical(
                    $0,
                    timestampTicks: 1,
                    processorID: 0,
                    source: .monitor
                )
            }
            expect(log.statistics.retainedCount == 1, "exact boundary split")
            let only = chunk(log, sequence: 1)
            expect(only.isFirst && only.isLast, "complete boundary flags")
            expect(only.byteCount == 16, "boundary byte count")
            expect(only.source == .monitor, "boundary source")
        }
    }

    private static func preservesMonotonicSequenceAcrossProducers() {
        withLog(capacity: 4) { log in
            log.appendCanonicalByte(
                48,
                timestampTicks: 10,
                processorID: 0,
                source: .earlyConsole
            )
            log.appendCanonicalByte(
                120,
                timestampTicks: 11,
                processorID: 1,
                source: .monitor
            )
            log.appendCanonicalByte(
                102,
                timestampTicks: 12,
                processorID: 2,
                source: .monitor
            )

            expect(log.statistics.oldestSequence == 1, "oldest sequence")
            expect(log.statistics.newestSequence == 3, "newest sequence")
            expect(reconstructedBytes(log) == [48, 120, 102], "numeric bytes")
            expect(chunk(log, sequence: 1).source == .earlyConsole, "early source")
            expect(chunk(log, sequence: 2).source == .monitor, "monitor source")
            expect(event(log, sequence: 3).timestampTicks == 12, "monotonic event")
        }
    }

    private static func retainsStructuredBootEpochBeforeConsole() {
        withLog(capacity: 3) { log in
            let boot = KernelBootEpochLogEvent.event(
                startedAtTicks: 0x1234,
                processorID: 0x300,
                deviceTreeAddress: 0x2_0000_0000,
                counterFrequency: 54_000_000
            )
            expect(
                log.append(boot) == .appended(
                    sequence: 1,
                    overwrittenSequence: nil
                ),
                "boot epoch append"
            )
            let message = Array("SWIFTOS:BOOT\n".utf8)
            message.withUnsafeBufferPointer {
                log.appendCanonical(
                    $0,
                    timestampTicks: 0x1235,
                    processorID: 0x300,
                    source: .earlyConsole
                )
            }

            guard let decoded = KernelBootEpochLogEvent(
                      event: event(log, sequence: 1)
                  )
            else { fail("boot epoch decode") }
            expect(decoded.startedAtTicks == 0x1234, "boot start ticks")
            expect(decoded.processorID == 0x300, "boot processor")
            expect(
                decoded.deviceTreeAddress == 0x2_0000_0000,
                "boot device tree"
            )
            expect(
                decoded.counterFrequency == 54_000_000,
                "boot counter frequency"
            )
            expect(
                KernelConsoleLogChunk(
                    event: event(log, sequence: 1)
                ) == nil,
                "boot epoch decoded as console"
            )
            expect(
                chunk(log, sequence: 2).isFirst,
                "console did not follow boot epoch"
            )
        }
    }

    private static func retainsWholeMessageWhenSerialEmissionStops() {
        withLog(capacity: 2) { log in
            let message = Array("A\nB".utf8)
            var sink = FailingConsoleSerialSink(failingByte: 13)
            message.withUnsafeBufferPointer { bytes in
                // Production performs retention before best-effort emission.
                log.appendCanonical(
                    bytes,
                    timestampTicks: 1,
                    processorID: 0,
                    source: .earlyConsole
                )
                emitKernelConsoleBytesToSerial(bytes, sink: &sink)
            }
            expect(
                reconstructedBytes(log) == Array("A\r\nB".utf8),
                "failed UART truncated retained message"
            )
            expect(
                sink.attemptedBytes == [65, 13],
                "CR failure did not stop before LF and message remainder"
            )

            let nextMessage = Array("C".utf8)
            sink.failingByte = nil
            nextMessage.withUnsafeBufferPointer { bytes in
                emitKernelConsoleBytesToSerial(bytes, sink: &sink)
            }
            expect(
                sink.attemptedBytes == [65, 13, 67],
                "later message did not retry UART output"
            )
        }
    }

    private static func reconstructedBytes(
        _ log: KernelDebugLogBuffer
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        guard let oldest = log.statistics.oldestSequence,
              let newest = log.statistics.newestSequence
        else { return bytes }
        var sequence = oldest
        while sequence <= newest {
            let decoded = chunk(log, sequence: sequence)
            var index = 0
            while index < decoded.byteCount {
                guard let byte = decoded.byte(at: index) else {
                    fail("missing decoded byte")
                }
                bytes.append(byte)
                index += 1
            }
            if sequence == UInt64.max { break }
            sequence += 1
        }
        return bytes
    }

    private static func event(
        _ log: KernelDebugLogBuffer,
        sequence: UInt64
    ) -> KernelLogEvent {
        guard case .entry(let entry) = log.entry(sequence: sequence) else {
            fail("missing log event")
        }
        return entry.event
    }

    private static func chunk(
        _ log: KernelDebugLogBuffer,
        sequence: UInt64
    ) -> KernelConsoleLogChunk {
        guard let chunk = KernelConsoleLogChunk(
                  event: event(log, sequence: sequence)
              )
        else { fail("invalid console chunk") }
        return chunk
    }

    private static func withLog(
        capacity: Int,
        _ body: (inout KernelDebugLogBuffer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: capacity * KernelLogRing.recordByteCount,
            alignment: 1
        )
        defer { pointer.deallocate() }
        let storage = UnsafeMutableRawBufferPointer(
            start: pointer,
            count: capacity * KernelLogRing.recordByteCount
        )
        guard var log = KernelDebugLogBuffer(storage: storage) else {
            fail("log storage rejected")
        }
        body(&log)
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

private struct FailingConsoleSerialSink: KernelConsoleSerialByteSink {
    var failingByte: UInt8?
    private(set) var attemptedBytes: [UInt8] = []

    mutating func writeConsoleByte(_ byte: UInt8) -> Bool {
        attemptedBytes.append(byte)
        return byte != failingByte
    }
}
