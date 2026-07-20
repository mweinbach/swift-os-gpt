@main
struct SwiftOSCanonicalConsoleTests {
    static func main() {
        reconstructsCanonicalBytesAndSkipsStructuredEvents()
        reportsSequenceGapsAndPartialMessages()
        reportsMalformedConsoleRecordsAndTrailingFragments()
        print("SwiftOS canonical console host tests: 3 groups passed")
    }

    private static func reconstructsCanonicalBytesAndSkipsStructuredEvents() {
        withLog(capacity: 8) { log in
            _ = log.append(
                KernelBootEpochLogEvent.event(
                    startedAtTicks: 1,
                    processorID: 0,
                    deviceTreeAddress: 0x300_0000,
                    counterFrequency: 54_000_000
                )
            )
            let message = Array("SWIFTOS:BOOT\n0123456789abcdefghi".utf8)
            message.withUnsafeBufferPointer {
                log.appendCanonical(
                    $0,
                    timestampTicks: 2,
                    processorID: 0,
                    source: .earlyConsole
                )
            }

            let result = SwiftOSCanonicalConsoleDecoder.decode(entries(log))
            expect(
                result.bytes
                    == Array("SWIFTOS:BOOT\r\n0123456789abcdefghi".utf8),
                "canonical bytes"
            )
            expect(result.consoleChunkCount == 3, "chunk count")
            expect(result.nonConsoleEntryCount == 1, "structured count")
            expect(result.malformedConsoleEntryCount == 0, "malformed count")
            expect(result.sequenceDiscontinuityCount == 0, "sequence gaps")
            expect(result.incompleteMessageCount == 0, "complete message")
            expect(!result.startsMidMessage, "unexpected leading fragment")
            expect(!result.endsMidMessage, "unexpected trailing fragment")
        }
    }

    private static func reportsSequenceGapsAndPartialMessages() {
        let entries = [
            consoleEntry(
                sequence: 5,
                bytes: Array("left".utf8),
                source: .monitor,
                isFirst: false,
                isLast: false
            ),
            consoleEntry(
                sequence: 7,
                bytes: Array("right".utf8),
                source: .earlyConsole,
                isFirst: true,
                isLast: true
            ),
        ]
        let result = SwiftOSCanonicalConsoleDecoder.decode(entries)
        expect(result.bytes == Array("leftright".utf8), "partial bytes lost")
        expect(result.consoleChunkCount == 2, "partial chunk count")
        expect(result.sequenceDiscontinuityCount == 1, "missing gap")
        expect(result.incompleteMessageCount == 1, "partial message count")
        expect(result.startsMidMessage, "leading fragment not reported")
        expect(!result.endsMidMessage, "complete suffix marked partial")
    }

    private static func reportsMalformedConsoleRecordsAndTrailingFragments() {
        let malformed = KernelLogEntry(
            sequence: 1,
            event: KernelLogEvent(
                timestampTicks: 1,
                level: .info,
                subsystem: .kernel,
                eventCode: KernelConsoleLogChunk.eventCode,
                flags: UInt32(KernelConsoleLogSource.monitor.rawValue) << 16
            )
        )
        let trailing = consoleEntry(
            sequence: 2,
            bytes: Array("tail".utf8),
            source: .monitor,
            isFirst: true,
            isLast: false
        )
        let result = SwiftOSCanonicalConsoleDecoder.decode([malformed, trailing])
        expect(result.bytes == Array("tail".utf8), "trailing bytes")
        expect(result.malformedConsoleEntryCount == 1, "malformed record")
        expect(result.nonConsoleEntryCount == 0, "malformed misclassified")
        expect(result.incompleteMessageCount == 1, "trailing partial count")
        expect(!result.startsMidMessage, "valid first flag ignored")
        expect(result.endsMidMessage, "trailing fragment not reported")
    }

    private static func consoleEntry(
        sequence: UInt64,
        bytes: [UInt8],
        source: KernelConsoleLogSource,
        isFirst: Bool,
        isLast: Bool
    ) -> KernelLogEntry {
        guard !bytes.isEmpty,
              bytes.count <= KernelConsoleLogChunk.maximumByteCount
        else { fail("invalid console fixture") }
        var lower: UInt64 = 0
        var upper: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            if index < 8 {
                lower |= UInt64(byte) << UInt64(index * 8)
            } else {
                upper |= UInt64(byte) << UInt64((index - 8) * 8)
            }
        }
        var flags = UInt32(bytes.count)
            | UInt32(source.rawValue) << 16
        if isFirst { flags |= 1 << 8 }
        if isLast { flags |= 1 << 9 }
        return KernelLogEntry(
            sequence: sequence,
            event: KernelLogEvent(
                timestampTicks: sequence,
                level: .info,
                subsystem: .kernel,
                eventCode: KernelConsoleLogChunk.eventCode,
                flags: flags,
                argument0: lower,
                argument1: upper
            )
        )
    }

    private static func entries(_ log: KernelDebugLogBuffer)
        -> [KernelLogEntry] {
        var result: [KernelLogEntry] = []
        var index = 0
        while index < log.statistics.retainedCount {
            guard let sequence = log.statistics.oldestSequence,
                  case .entry(let entry) = log.entry(
                      sequence: sequence + UInt64(index)
                  )
            else { fail("missing chronological entry") }
            result.append(entry)
            index += 1
        }
        return result
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
        guard var log = KernelDebugLogBuffer(
                  storage: UnsafeMutableRawBufferPointer(
                      start: pointer,
                      count: capacity * KernelLogRing.recordByteCount
                  )
              )
        else { fail("log fixture rejected") }
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
