enum InputEventDropReason: Equatable {
    case capacityExhausted
    case sequenceExhausted
    case invalidEvent
}

enum InputEventSubmissionResult: Equatable {
    case enqueued(sequence: UInt64)
    /// A capacity drop still receives a sequence, making the loss visible as a
    /// gap after space becomes available. Sequence or validation failures do
    /// not have a representable sequence and therefore return nil.
    case dropped(sequence: UInt64?, reason: InputEventDropReason)
}

protocol InputEventSink {
    mutating func submit(_ event: InputEvent) -> InputEventSubmissionResult
}

enum InputEventDequeueResult: Equatable {
    case event(QueuedInputEvent)
    case empty
    /// The owned slot failed ABI validation. It is discarded so corruption
    /// cannot permanently stall the consumer.
    case corruptRecordDiscarded
}

struct InputEventQueueStatistics: Equatable {
    let capacity: Int
    let retainedCount: Int
    let nextSequence: UInt64?
    let enqueuedEventCount: UInt64
    let dequeuedEventCount: UInt64
    let capacityDropCount: UInt64
    let sequenceExhaustionDropCount: UInt64
    let invalidEventDropCount: UInt64
    let corruptRecordCount: UInt64

    var droppedEventCount: UInt64 {
        Self.saturatingAdd(
            Self.saturatingAdd(
                capacityDropCount,
                sequenceExhaustionDropCount
            ),
            invalidEventDropCount
        )
    }

    var didLoseEvents: Bool {
        droppedEventCount != 0 || corruptRecordCount != 0
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

/// Serialized, policy-neutral input queue. Its records are
/// encoded into caller-owned raw storage with InputEventWireCodec, so there is
/// no heap allocation and no dependency on Swift's in-memory layout.
///
/// Full queues deterministically drop the newest submission. Every such event
/// consumes a sequence number, allowing a consumer to pair sequence gaps with
/// the explicit counters below. External serialization is required if multiple
/// CPUs can call submit or dequeue concurrently.
struct InputEventQueue: InputEventSink {
    private let storage: UnsafeMutableRawBufferPointer
    private(set) var retainedCount = 0
    private(set) var enqueuedEventCount: UInt64 = 0
    private(set) var dequeuedEventCount: UInt64 = 0
    private(set) var capacityDropCount: UInt64 = 0
    private(set) var sequenceExhaustionDropCount: UInt64 = 0
    private(set) var invalidEventDropCount: UInt64 = 0
    private(set) var corruptRecordCount: UInt64 = 0

    private var headSlot = 0
    private var nextSequenceValue: UInt64
    private var sequenceSpaceExhausted = false

    init?(
        storage: UnsafeMutableRawBufferPointer,
        firstSequence: UInt64 = 1
    ) {
        guard storage.baseAddress != nil,
              storage.count >= InputEventWireCodec.recordByteCount,
              firstSequence != 0
        else { return nil }
        self.storage = storage
        nextSequenceValue = firstSequence
    }

    var capacity: Int {
        storage.count / InputEventWireCodec.recordByteCount
    }

    var isEmpty: Bool { retainedCount == 0 }
    var isFull: Bool { retainedCount == capacity }

    var nextSequence: UInt64? {
        sequenceSpaceExhausted ? nil : nextSequenceValue
    }

    var statistics: InputEventQueueStatistics {
        InputEventQueueStatistics(
            capacity: capacity,
            retainedCount: retainedCount,
            nextSequence: nextSequence,
            enqueuedEventCount: enqueuedEventCount,
            dequeuedEventCount: dequeuedEventCount,
            capacityDropCount: capacityDropCount,
            sequenceExhaustionDropCount: sequenceExhaustionDropCount,
            invalidEventDropCount: invalidEventDropCount,
            corruptRecordCount: corruptRecordCount
        )
    }

    mutating func submit(_ event: InputEvent) -> InputEventSubmissionResult {
        guard InputEventWireCodec.isWellFormed(event) else {
            invalidEventDropCount = Self.saturatingIncrement(
                invalidEventDropCount
            )
            return .dropped(sequence: nil, reason: .invalidEvent)
        }
        guard !sequenceSpaceExhausted else {
            sequenceExhaustionDropCount = Self.saturatingIncrement(
                sequenceExhaustionDropCount
            )
            return .dropped(sequence: nil, reason: .sequenceExhausted)
        }

        let sequence = takeNextSequence()
        guard retainedCount < capacity else {
            capacityDropCount = Self.saturatingIncrement(capacityDropCount)
            return .dropped(
                sequence: sequence,
                reason: .capacityExhausted
            )
        }

        let tailSlot = (headSlot + retainedCount) % capacity
        let encoded = InputEventWireCodec.encode(
            QueuedInputEvent(sequence: sequence, event: event),
            to: storage,
            at: tailSlot * InputEventWireCodec.recordByteCount
        )
        // The event and sequence were validated above. Keeping this guard
        // nevertheless makes the queue fail closed if the codec changes.
        guard encoded else {
            invalidEventDropCount = Self.saturatingIncrement(
                invalidEventDropCount
            )
            return .dropped(sequence: sequence, reason: .invalidEvent)
        }

        retainedCount += 1
        enqueuedEventCount = Self.saturatingIncrement(enqueuedEventCount)
        return .enqueued(sequence: sequence)
    }

    mutating func dequeue() -> InputEventDequeueResult {
        guard retainedCount != 0 else { return .empty }
        let offset = headSlot * InputEventWireCodec.recordByteCount
        let decoded = InputEventWireCodec.decode(
            from: UnsafeRawBufferPointer(storage),
            at: offset
        )
        headSlot = (headSlot + 1) % capacity
        retainedCount -= 1

        guard let decoded else {
            corruptRecordCount = Self.saturatingIncrement(corruptRecordCount)
            return .corruptRecordDiscarded
        }
        dequeuedEventCount = Self.saturatingIncrement(dequeuedEventCount)
        return .event(decoded)
    }

    private mutating func takeNextSequence() -> UInt64 {
        let sequence = nextSequenceValue
        if sequence == UInt64.max {
            sequenceSpaceExhausted = true
        } else {
            nextSequenceValue = sequence + 1
        }
        return sequence
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }
}
