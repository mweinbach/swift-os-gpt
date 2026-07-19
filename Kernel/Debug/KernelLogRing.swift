/// Severity carried by a structured kernel log event. Raw values are stable so
/// a future debug transport can forward records without translating them.
enum KernelLogLevel: UInt8, Equatable {
    case trace = 0
    case debug = 1
    case info = 2
    case notice = 3
    case warning = 4
    case error = 5
    case critical = 6
}

/// A stable, extensible subsystem identifier. Keeping this open rather than an
/// enum lets drivers reserve identifiers without coupling the log core to a
/// particular machine or device family.
struct KernelLogSubsystem: RawRepresentable, Equatable {
    let rawValue: UInt16

    static let kernel = Self(rawValue: 1)
    static let boot = Self(rawValue: 2)
    static let memory = Self(rawValue: 3)
    static let scheduler = Self(rawValue: 4)
    static let interrupts = Self(rawValue: 5)
    static let drivers = Self(rawValue: 6)
    static let graphics = Self(rawValue: 7)
    static let update = Self(rawValue: 8)
    static let userland = Self(rawValue: 9)
}

/// Allocation-free event payload supplied by a producer. Event codes and the
/// two machine words are interpreted by the subsystem that owns the code.
struct KernelLogEvent: Equatable {
    let timestampTicks: UInt64
    let level: KernelLogLevel
    let subsystem: KernelLogSubsystem
    let eventCode: UInt32
    let processorID: UInt32
    let flags: UInt32
    let argument0: UInt64
    let argument1: UInt64

    init(
        timestampTicks: UInt64,
        level: KernelLogLevel,
        subsystem: KernelLogSubsystem,
        eventCode: UInt32,
        processorID: UInt32 = 0,
        flags: UInt32 = 0,
        argument0: UInt64 = 0,
        argument1: UInt64 = 0
    ) {
        self.timestampTicks = timestampTicks
        self.level = level
        self.subsystem = subsystem
        self.eventCode = eventCode
        self.processorID = processorID
        self.flags = flags
        self.argument0 = argument0
        self.argument1 = argument1
    }
}

/// A retained event with its globally ordered sequence number.
struct KernelLogEntry: Equatable {
    let sequence: UInt64
    let event: KernelLogEvent
}

enum KernelLogAppendResult: Equatable {
    /// `overwrittenSequence` identifies the exact retained record displaced by
    /// this append. It is nil until the caller-supplied ring becomes full.
    case appended(sequence: UInt64, overwrittenSequence: UInt64?)
    /// UInt64 sequence space was consumed. Records remain readable, but no
    /// later append can preserve the strict monotonic ordering contract.
    case sequenceExhausted
}

enum KernelLogLookupResult: Equatable {
    case entry(KernelLogEntry)
    /// The requested sequence predates the oldest retained record.
    case lost(oldestAvailableSequence: UInt64)
    /// The sequence has not been assigned in this log epoch.
    case notYetWritten
}

struct KernelLogStatistics: Equatable {
    let capacity: Int
    let retainedCount: Int
    let oldestSequence: UInt64?
    let newestSequence: UInt64?
    let nextSequence: UInt64?
    let overwrittenEntryCount: UInt64
    let rejectedEntryCount: UInt64

    var didLoseEntries: Bool {
        overwrittenEntryCount != 0 || rejectedEntryCount != 0
    }
}

/// Caller-owned, fixed-record log storage for early boot and kernel diagnostics.
///
/// Each record is encoded explicitly into the supplied raw bytes. The ring does
/// not allocate, retain strings, or depend on pointer alignment. A lock or
/// single-writer discipline must serialize mutation when used by multiple CPUs.
struct KernelLogRing {
    static let recordByteCount = 48

    private let storage: UnsafeMutableRawBufferPointer
    private let firstSequence: UInt64
    private(set) var retainedCount = 0
    private(set) var overwrittenEntryCount: UInt64 = 0
    private(set) var rejectedEntryCount: UInt64 = 0
    private var nextSequenceValue: UInt64
    private var sequenceSpaceExhausted = false

    init?(
        storage: UnsafeMutableRawBufferPointer,
        firstSequence: UInt64 = 1
    ) {
        guard storage.baseAddress != nil,
              storage.count >= Self.recordByteCount,
              firstSequence != 0
        else { return nil }
        self.storage = storage
        self.firstSequence = firstSequence
        nextSequenceValue = firstSequence
    }

    var capacity: Int { storage.count / Self.recordByteCount }

    var isEmpty: Bool { retainedCount == 0 }

    var nextSequence: UInt64? {
        sequenceSpaceExhausted ? nil : nextSequenceValue
    }

    var newestSequence: UInt64? {
        guard retainedCount != 0 else { return nil }
        return sequenceSpaceExhausted
            ? UInt64.max
            : nextSequenceValue - 1
    }

    var oldestSequence: UInt64? {
        guard let newest = newestSequence else { return nil }
        return newest - UInt64(retainedCount - 1)
    }

    var statistics: KernelLogStatistics {
        KernelLogStatistics(
            capacity: capacity,
            retainedCount: retainedCount,
            oldestSequence: oldestSequence,
            newestSequence: newestSequence,
            nextSequence: nextSequence,
            overwrittenEntryCount: overwrittenEntryCount,
            rejectedEntryCount: rejectedEntryCount
        )
    }

    mutating func append(_ event: KernelLogEvent) -> KernelLogAppendResult {
        guard !sequenceSpaceExhausted else {
            rejectedEntryCount = Self.saturatingIncrement(rejectedEntryCount)
            return .sequenceExhausted
        }

        let sequence = nextSequenceValue
        let displaced = retainedCount == capacity ? oldestSequence : nil
        let slot = Int((sequence - firstSequence) % UInt64(capacity))
        write(KernelLogEntry(sequence: sequence, event: event), toSlot: slot)

        if retainedCount == capacity {
            overwrittenEntryCount = Self.saturatingIncrement(
                overwrittenEntryCount
            )
        } else {
            retainedCount += 1
        }

        if sequence == UInt64.max {
            sequenceSpaceExhausted = true
        } else {
            nextSequenceValue = sequence + 1
        }
        return .appended(
            sequence: sequence,
            overwrittenSequence: displaced
        )
    }

    func entry(sequence: UInt64) -> KernelLogLookupResult {
        guard let oldest = oldestSequence,
              let newest = newestSequence
        else { return .notYetWritten }
        guard sequence >= oldest else {
            return .lost(oldestAvailableSequence: oldest)
        }
        guard sequence <= newest else { return .notYetWritten }
        let slot = Int((sequence - firstSequence) % UInt64(capacity))
        let decoded = read(fromSlot: slot)
        // The bounds above establish ownership of the slot. Keeping the stored
        // sequence in every record also makes accidental corruption detectable.
        guard decoded.sequence == sequence else {
            return .lost(oldestAvailableSequence: oldest)
        }
        return .entry(decoded)
    }

    /// Chronological access avoids exposing storage order to serializers.
    func entry(atChronologicalIndex index: Int) -> KernelLogEntry? {
        guard index >= 0, index < retainedCount,
              let oldest = oldestSequence
        else { return nil }
        guard case .entry(let entry) = entry(
                  sequence: oldest + UInt64(index)
              )
        else { return nil }
        return entry
    }

    private func write(_ entry: KernelLogEntry, toSlot slot: Int) {
        let offset = slot * Self.recordByteCount
        Self.writeUInt64(entry.sequence, to: storage, at: offset)
        Self.writeUInt64(
            entry.event.timestampTicks,
            to: storage,
            at: offset + 8
        )
        storage[offset + 16] = entry.event.level.rawValue
        storage[offset + 17] = 0
        Self.writeUInt16(
            entry.event.subsystem.rawValue,
            to: storage,
            at: offset + 18
        )
        Self.writeUInt32(entry.event.eventCode, to: storage, at: offset + 20)
        Self.writeUInt32(entry.event.processorID, to: storage, at: offset + 24)
        Self.writeUInt32(entry.event.flags, to: storage, at: offset + 28)
        Self.writeUInt64(entry.event.argument0, to: storage, at: offset + 32)
        Self.writeUInt64(entry.event.argument1, to: storage, at: offset + 40)
    }

    private func read(fromSlot slot: Int) -> KernelLogEntry {
        let offset = slot * Self.recordByteCount
        return KernelLogEntry(
            sequence: Self.readUInt64(storage, at: offset),
            event: KernelLogEvent(
                timestampTicks: Self.readUInt64(storage, at: offset + 8),
                level: KernelLogLevel(rawValue: storage[offset + 16]) ?? .critical,
                subsystem: KernelLogSubsystem(
                    rawValue: Self.readUInt16(storage, at: offset + 18)
                ),
                eventCode: Self.readUInt32(storage, at: offset + 20),
                processorID: Self.readUInt32(storage, at: offset + 24),
                flags: Self.readUInt32(storage, at: offset + 28),
                argument0: Self.readUInt64(storage, at: offset + 32),
                argument1: Self.readUInt64(storage, at: offset + 40)
            )
        )
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }

    private static func writeUInt16(
        _ value: UInt16,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeUInt32(
        _ value: UInt32,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        var index = 0
        while index < 4 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt32(index * 8)
            )
            index += 1
        }
    }

    private static func writeUInt64(
        _ value: UInt64,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        var index = 0
        while index < 8 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt64(index * 8)
            )
            index += 1
        }
    }

    private static func readUInt16(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        var value: UInt32 = 0
        var index = 0
        while index < 4 {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
            index += 1
        }
        return value
    }

    private static func readUInt64(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        var index = 0
        while index < 8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
            index += 1
        }
        return value
    }
}
