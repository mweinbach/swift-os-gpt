/// Stable payload codec between the volatile kernel ring and the persistent
/// record store. Storage record sequencing is independent of the original ring
/// sequence, which remains part of this 48-byte payload for loss accounting.
enum PersistentKernelLogCodec {
    static let payloadByteCount = KernelLogRing.recordByteCount

    static func encode(
        _ entry: KernelLogEntry,
        into output: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard output.count >= payloadByteCount else { return false }
        writeLE64(entry.sequence, into: output, at: 0)
        writeLE64(entry.event.timestampTicks, into: output, at: 8)
        output[16] = entry.event.level.rawValue
        output[17] = 0
        writeLE16(entry.event.subsystem.rawValue, into: output, at: 18)
        writeLE32(entry.event.eventCode, into: output, at: 20)
        writeLE32(entry.event.processorID, into: output, at: 24)
        writeLE32(entry.event.flags, into: output, at: 28)
        writeLE64(entry.event.argument0, into: output, at: 32)
        writeLE64(entry.event.argument1, into: output, at: 40)
        return true
    }

    static func decode(_ input: UnsafeRawBufferPointer) -> KernelLogEntry? {
        guard input.count >= payloadByteCount,
              input[17] == 0,
              let level = KernelLogLevel(rawValue: input[16])
        else { return nil }
        return KernelLogEntry(
            sequence: readLE64(input, at: 0),
            event: KernelLogEvent(
                timestampTicks: readLE64(input, at: 8),
                level: level,
                subsystem: KernelLogSubsystem(
                    rawValue: readLE16(input, at: 18)
                ),
                eventCode: readLE32(input, at: 20),
                processorID: readLE32(input, at: 24),
                flags: readLE32(input, at: 28),
                argument0: readLE64(input, at: 32),
                argument1: readLE64(input, at: 40)
            )
        )
    }

    private static func writeLE16(
        _ value: UInt16,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeLE32(
        _ value: UInt32,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeLE16(UInt16(truncatingIfNeeded: value), into: bytes, at: offset)
        writeLE16(
            UInt16(truncatingIfNeeded: value >> 16),
            into: bytes,
            at: offset + 2
        )
    }

    private static func writeLE64(
        _ value: UInt64,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeLE32(UInt32(truncatingIfNeeded: value), into: bytes, at: offset)
        writeLE32(
            UInt32(truncatingIfNeeded: value >> 32),
            into: bytes,
            at: offset + 4
        )
    }

    private static func readLE16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readLE32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(readLE16(bytes, at: offset))
            | UInt32(readLE16(bytes, at: offset + 2)) << 16
    }

    private static func readLE64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        UInt64(readLE32(bytes, at: offset))
            | UInt64(readLE32(bytes, at: offset + 4)) << 32
    }
}

extension PersistentLogStore {
    mutating func appendKernelLogEntry(
        _ entry: KernelLogEntry
    ) -> PersistentLogAppendResult {
        append(
            payloadByteCount: PersistentKernelLogCodec.payloadByteCount,
            timestampTicks: entry.event.timestampTicks
        ) { payload in
            PersistentKernelLogCodec.encode(entry, into: payload)
        }
    }
}
