/// Identifies the producer of bytes retained from the canonical serial stream.
/// Raw values form part of the structured log ABI.
enum KernelConsoleLogSource: UInt8, Equatable {
    case earlyConsole = 1
    case monitor = 2
}

/// A decoded, allocation-free view of one canonical-console log event.
struct KernelConsoleLogChunk: Equatable {
    static let eventCode: UInt32 = 0x434f_4e53 // "CONS"
    static let maximumByteCount = 16

    private static let byteCountMask: UInt32 = 0x1f
    private static let firstFlag: UInt32 = 1 << 8
    private static let lastFlag: UInt32 = 1 << 9
    private static let sourceShift: UInt32 = 16

    let source: KernelConsoleLogSource
    let isFirst: Bool
    let isLast: Bool
    let byteCount: Int
    private let lowerBytes: UInt64
    private let upperBytes: UInt64

    init?(event: KernelLogEvent) {
        let count = Int(event.flags & Self.byteCountMask)
        let sourceValue = UInt8(
            truncatingIfNeeded: event.flags >> Self.sourceShift
        )
        guard event.eventCode == Self.eventCode,
              event.subsystem == .kernel,
              count > 0,
              count <= Self.maximumByteCount,
              let source = KernelConsoleLogSource(rawValue: sourceValue)
        else { return nil }

        self.source = source
        isFirst = event.flags & Self.firstFlag != 0
        isLast = event.flags & Self.lastFlag != 0
        byteCount = count
        lowerBytes = event.argument0
        upperBytes = event.argument1
    }

    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < byteCount else { return nil }
        if index < 8 {
            return UInt8(truncatingIfNeeded: lowerBytes >> UInt64(index * 8))
        }
        return UInt8(
            truncatingIfNeeded: upperBytes >> UInt64((index - 8) * 8)
        )
    }

    fileprivate static func event(
        timestampTicks: UInt64,
        processorID: UInt32,
        source: KernelConsoleLogSource,
        isFirst: Bool,
        isLast: Bool,
        byteCount: Int,
        lowerBytes: UInt64,
        upperBytes: UInt64
    ) -> KernelLogEvent {
        var flags = UInt32(byteCount)
            | UInt32(source.rawValue) << sourceShift
        if isFirst { flags |= firstFlag }
        if isLast { flags |= lastFlag }
        return KernelLogEvent(
            timestampTicks: timestampTicks,
            level: .info,
            subsystem: .kernel,
            eventCode: eventCode,
            processorID: processorID,
            flags: flags,
            argument0: lowerBytes,
            argument1: upperBytes
        )
    }
}

/// Pure fixed-storage encoder used by the runtime and by host tests. Newline
/// expansion happens here so retained bytes exactly match the CRLF stream sent
/// to PL011. A caller serializes mutation when this value is shared.
struct KernelDebugLogBuffer {
    private var ring: KernelLogRing

    init?(storage: UnsafeMutableRawBufferPointer) {
        guard let ring = KernelLogRing(storage: storage) else { return nil }
        self.ring = ring
    }

    var statistics: KernelLogStatistics { ring.statistics }

    func entry(sequence: UInt64) -> KernelLogLookupResult {
        ring.entry(sequence: sequence)
    }

    mutating func appendCanonical(
        _ bytes: UnsafeBufferPointer<UInt8>,
        timestampTicks: UInt64,
        processorID: UInt32,
        source: KernelConsoleLogSource
    ) {
        var accumulator = KernelConsoleChunkAccumulator()
        var isFirst = true
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 10 {
                append(
                    byte: 13,
                    to: &accumulator,
                    timestampTicks: timestampTicks,
                    processorID: processorID,
                    source: source,
                    isFirst: &isFirst
                )
            }
            append(
                byte: byte,
                to: &accumulator,
                timestampTicks: timestampTicks,
                processorID: processorID,
                source: source,
                isFirst: &isFirst
            )
            index += 1
        }
        flush(
            &accumulator,
            timestampTicks: timestampTicks,
            processorID: processorID,
            source: source,
            isFirst: isFirst,
            isLast: true
        )
    }

    mutating func appendCanonicalByte(
        _ byte: UInt8,
        timestampTicks: UInt64,
        processorID: UInt32,
        source: KernelConsoleLogSource
    ) {
        var accumulator = KernelConsoleChunkAccumulator()
        accumulator.append(byte)
        flush(
            &accumulator,
            timestampTicks: timestampTicks,
            processorID: processorID,
            source: source,
            isFirst: true,
            isLast: true
        )
    }

    private mutating func append(
        byte: UInt8,
        to accumulator: inout KernelConsoleChunkAccumulator,
        timestampTicks: UInt64,
        processorID: UInt32,
        source: KernelConsoleLogSource,
        isFirst: inout Bool
    ) {
        if accumulator.isFull {
            flush(
                &accumulator,
                timestampTicks: timestampTicks,
                processorID: processorID,
                source: source,
                isFirst: isFirst,
                isLast: false
            )
            isFirst = false
        }
        accumulator.append(byte)
    }

    private mutating func flush(
        _ accumulator: inout KernelConsoleChunkAccumulator,
        timestampTicks: UInt64,
        processorID: UInt32,
        source: KernelConsoleLogSource,
        isFirst: Bool,
        isLast: Bool
    ) {
        guard accumulator.byteCount != 0 else { return }
        _ = ring.append(
            KernelConsoleLogChunk.event(
                timestampTicks: timestampTicks,
                processorID: processorID,
                source: source,
                isFirst: isFirst,
                isLast: isLast,
                byteCount: accumulator.byteCount,
                lowerBytes: accumulator.lowerBytes,
                upperBytes: accumulator.upperBytes
            )
        )
        accumulator = KernelConsoleChunkAccumulator()
    }
}

private struct KernelConsoleChunkAccumulator {
    private(set) var byteCount = 0
    private(set) var lowerBytes: UInt64 = 0
    private(set) var upperBytes: UInt64 = 0

    var isFull: Bool {
        byteCount == KernelConsoleLogChunk.maximumByteCount
    }

    mutating func append(_ byte: UInt8) {
        guard !isFull else { return }
        if byteCount < 8 {
            lowerBytes |= UInt64(byte) << UInt64(byteCount * 8)
        } else {
            upperBytes |= UInt64(byte) << UInt64((byteCount - 8) * 8)
        }
        byteCount += 1
    }
}

#if os(none)
/// Global allocation-free retained log. The linker owns its record storage;
/// the only mutable runtime state is a ring cursor and an IRQ-safe SMP lock.
enum KernelDebugLogRuntime {
    private nonisolated(unsafe) static var buffer: KernelDebugLogBuffer?
    private nonisolated(unsafe) static var lockWord: UInt32 = 0

    static func initialize() {
        let interruptState = lock()
        defer { unlock(restoring: interruptState) }
        guard buffer == nil else { return }
        let region = KernelLinkerLayout.debugLogStorage
        guard region.start <= UInt64(UInt.max),
              region.length <= UInt64(Int.max),
              let storage = UnsafeMutableRawPointer(
                  bitPattern: UInt(region.start)
              )
        else { return }
        buffer = KernelDebugLogBuffer(
            storage: UnsafeMutableRawBufferPointer(
                start: storage,
                count: Int(region.length)
            )
        )
    }

    /// Retains and emits one StaticString under the same lock, making the log
    /// sequence an exact reconstruction of UART ordering under IRQ and SMP
    /// producers without changing the UART byte contract.
    static func write(
        _ text: StaticString,
        to serial: PL011,
        source: KernelConsoleLogSource
    ) {
        let interruptState = lock()
        defer { unlock(restoring: interruptState) }
        text.withUTF8Buffer { bytes in
            appendLocked(bytes, source: source)
            for byte in bytes {
                if byte == 10 {
                    serial.write(byte: 13)
                }
                serial.write(byte: byte)
            }
        }
    }

    static func write(
        byte: UInt8,
        to serial: PL011,
        source: KernelConsoleLogSource
    ) {
        let interruptState = lock()
        defer { unlock(restoring: interruptState) }
        if var active = buffer {
            active.appendCanonicalByte(
                byte,
                timestampTicks: AArch64.counterValue,
                processorID: AArch64.redistributorAffinity,
                source: source
            )
            buffer = active
        }
        serial.write(byte: byte)
    }

    static var statistics: KernelLogStatistics? {
        let interruptState = lock()
        defer { unlock(restoring: interruptState) }
        return buffer?.statistics
    }

    static func entry(sequence: UInt64) -> KernelLogLookupResult? {
        let interruptState = lock()
        defer { unlock(restoring: interruptState) }
        return buffer?.entry(sequence: sequence)
    }

    private static func appendLocked(
        _ bytes: UnsafeBufferPointer<UInt8>,
        source: KernelConsoleLogSource
    ) {
        guard var active = buffer else { return }
        active.appendCanonical(
            bytes,
            timestampTicks: AArch64.counterValue,
            processorID: AArch64.redistributorAffinity,
            source: source
        )
        buffer = active
    }

    private static func lock() -> UInt64 {
        withUnsafeMutablePointer(to: &lockWord) { word in
            AArch64.acquireInterruptSafeLock(word)
        }
    }

    private static func unlock(restoring interruptState: UInt64) {
        withUnsafeMutablePointer(to: &lockWord) { word in
            AArch64.releaseInterruptSafeLock(
                word,
                restoring: interruptState
            )
        }
    }
}
#endif
