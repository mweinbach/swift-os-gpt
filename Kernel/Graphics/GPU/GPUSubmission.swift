/// A point on a backend-neutral timeline fence. Device backends may map the
/// point to a VirtIO fence, a Vulkan timeline semaphore, or a V3D job fence.
struct GPUFencePoint: Equatable {
    let queue: GPUQueueID
    let value: UInt64

    init?(queue: GPUQueueID, value: UInt64) {
        guard value != 0 else { return nil }
        self.queue = queue
        self.value = value
    }
}

enum GPUFenceWaitMutation: Equatable {
    case inserted(index: Int)
    case advanced(index: Int)
    case unchanged(index: Int)
    case capacityExhausted
}

/// At most one wait point per source queue, sorted by queue ID. Adding a later
/// value for an existing queue advances that dependency in place.
struct GPUFenceWaitSet {
    static let maximumFenceCount = 4

    let capacity: Int
    private(set) var count: Int = 0

    private var fence0: GPUFencePoint?
    private var fence1: GPUFencePoint?
    private var fence2: GPUFencePoint?
    private var fence3: GPUFencePoint?

    init?(capacity: Int = maximumFenceCount) {
        guard capacity > 0, capacity <= Self.maximumFenceCount else {
            return nil
        }
        self.capacity = capacity
    }

    func fence(at index: Int) -> GPUFencePoint? {
        guard index >= 0, index < count else { return nil }
        return storedFence(at: index)
    }

    func fence(for queue: GPUQueueID) -> GPUFencePoint? {
        var index = 0
        while index < count {
            let point = storedFence(at: index)
            if point.queue == queue { return point }
            index += 1
        }
        return nil
    }

    mutating func add(_ point: GPUFencePoint) -> GPUFenceWaitMutation {
        var insertionIndex = 0
        while insertionIndex < count {
            let existing = storedFence(at: insertionIndex)
            if existing.queue == point.queue {
                guard point.value > existing.value else {
                    return .unchanged(index: insertionIndex)
                }
                setStoredFence(point, at: insertionIndex)
                return .advanced(index: insertionIndex)
            }
            if point.queue < existing.queue { break }
            insertionIndex += 1
        }

        guard count < capacity else { return .capacityExhausted }
        var shift = count
        while shift > insertionIndex {
            setStoredFence(storedFence(at: shift - 1), at: shift)
            shift -= 1
        }
        setStoredFence(point, at: insertionIndex)
        count += 1
        return .inserted(index: insertionIndex)
    }

    private func storedFence(at index: Int) -> GPUFencePoint {
        switch index {
        case 0: return fence0!
        case 1: return fence1!
        case 2: return fence2!
        default: return fence3!
        }
    }

    private mutating func setStoredFence(
        _ fence: GPUFencePoint,
        at index: Int
    ) {
        switch index {
        case 0: fence0 = fence
        case 1: fence1 = fence
        case 2: fence2 = fence
        default: fence3 = fence
        }
    }
}

/// Ordering and synchronization for one immutable command buffer submission.
struct GPUSubmissionMetadata {
    let queue: GPUQueueID
    let sequenceNumber: UInt64
    let frameID: UInt64
    let waits: GPUFenceWaitSet
    let signal: GPUFencePoint?

    init?(
        queue: GPUQueueID,
        sequenceNumber: UInt64,
        frameID: UInt64,
        waits: GPUFenceWaitSet,
        signal: GPUFencePoint?
    ) {
        guard sequenceNumber != 0 else { return nil }
        if let signal {
            guard signal.queue == queue else { return nil }
            if let selfWait = waits.fence(for: queue),
               selfWait.value >= signal.value {
                return nil
            }
        }
        self.queue = queue
        self.sequenceNumber = sequenceNumber
        self.frameID = frameID
        self.waits = waits
        self.signal = signal
    }
}

/// A submission references command storage by stable ID, keeping the scheduler
/// queue compact and leaving command-buffer ownership to a future resource pool.
struct GPUCommandSubmission {
    let commandBuffer: GPUCommandBufferID
    let metadata: GPUSubmissionMetadata

    init(commandBuffer: GPUCommandBufferID, metadata: GPUSubmissionMetadata) {
        self.commandBuffer = commandBuffer
        self.metadata = metadata
    }
}

enum GPUSubmissionEnqueueRejection: Equatable {
    case wrongQueue
    case sequenceNotIncreasing
    case signalNotIncreasing
    case capacityExhausted
}

enum GPUSubmissionEnqueueResult: Equatable {
    case enqueued(index: Int)
    case rejected(GPUSubmissionEnqueueRejection)
}

/// Fixed-capacity FIFO for one logical GPU queue. It enforces submission and
/// signal ordering before a device backend consumes any work.
struct GPUOrderedSubmissionQueue {
    static let maximumSubmissionCount = 8

    let queue: GPUQueueID
    let capacity: Int
    private(set) var count: Int = 0
    private(set) var lastAcceptedSequenceNumber: UInt64 = 0
    private(set) var lastAcceptedSignalValue: UInt64 = 0

    private var submission0: GPUCommandSubmission?
    private var submission1: GPUCommandSubmission?
    private var submission2: GPUCommandSubmission?
    private var submission3: GPUCommandSubmission?
    private var submission4: GPUCommandSubmission?
    private var submission5: GPUCommandSubmission?
    private var submission6: GPUCommandSubmission?
    private var submission7: GPUCommandSubmission?

    init?(
        queue: GPUQueueID,
        capacity: Int = maximumSubmissionCount
    ) {
        guard capacity > 0, capacity <= Self.maximumSubmissionCount else {
            return nil
        }
        self.queue = queue
        self.capacity = capacity
    }

    func submission(at index: Int) -> GPUCommandSubmission? {
        guard index >= 0, index < count else { return nil }
        return storedSubmission(at: index)
    }

    var next: GPUCommandSubmission? { submission(at: 0) }

    mutating func enqueue(
        _ submission: GPUCommandSubmission
    ) -> GPUSubmissionEnqueueResult {
        let metadata = submission.metadata
        guard metadata.queue == queue else {
            return .rejected(.wrongQueue)
        }
        guard metadata.sequenceNumber > lastAcceptedSequenceNumber else {
            return .rejected(.sequenceNotIncreasing)
        }
        if let signal = metadata.signal,
           signal.value <= lastAcceptedSignalValue {
            return .rejected(.signalNotIncreasing)
        }
        guard count < capacity else {
            return .rejected(.capacityExhausted)
        }

        let index = count
        setStoredSubmission(submission, at: index)
        count += 1
        lastAcceptedSequenceNumber = metadata.sequenceNumber
        if let signal = metadata.signal {
            lastAcceptedSignalValue = signal.value
        }
        return .enqueued(index: index)
    }

    mutating func dequeue() -> GPUCommandSubmission? {
        guard count > 0 else { return nil }
        let first = storedSubmission(at: 0)
        var index = 1
        while index < count {
            setStoredSubmission(storedSubmission(at: index), at: index - 1)
            index += 1
        }
        setStoredSubmission(nil, at: count - 1)
        count -= 1
        return first
    }

    private func storedSubmission(at index: Int) -> GPUCommandSubmission? {
        switch index {
        case 0: return submission0
        case 1: return submission1
        case 2: return submission2
        case 3: return submission3
        case 4: return submission4
        case 5: return submission5
        case 6: return submission6
        default: return submission7
        }
    }

    private mutating func setStoredSubmission(
        _ submission: GPUCommandSubmission?,
        at index: Int
    ) {
        switch index {
        case 0: submission0 = submission
        case 1: submission1 = submission
        case 2: submission2 = submission
        case 3: submission3 = submission
        case 4: submission4 = submission
        case 5: submission5 = submission
        case 6: submission6 = submission
        default: submission7 = submission
        }
    }
}
