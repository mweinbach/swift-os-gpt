/// Allocation-free messages sent from the scene owner to the graphics worker.
///
/// Every field is a value. In particular, the payload cannot smuggle a user or
/// kernel virtual address to the worker: resources are named by stable integer
/// identifiers and backend-owned tables resolve those identifiers separately.
enum GraphicsSceneTransactionOpcode: UInt8, Equatable {
    case upsertLayer = 1
    case removeLayer = 2
    case setAnimation = 3
    case bindGlyphAtlas = 4
    case updateGlyphRun = 5
    case commitScene = 6
}

/// Fixed-size scalar payload interpreted according to the transaction opcode.
/// Keeping the transport ignorant of scene policy lets later layer, text, and
/// animation schemas evolve without changing the shared-ring algorithm.
struct GraphicsSceneTransactionPayload: Equatable {
    let word0: UInt64
    let word1: UInt64
    let word2: UInt64
    let word3: UInt64
    let word4: UInt64
    let word5: UInt64

    init(
        word0: UInt64 = 0,
        word1: UInt64 = 0,
        word2: UInt64 = 0,
        word3: UInt64 = 0,
        word4: UInt64 = 0,
        word5: UInt64 = 0
    ) {
        self.word0 = word0
        self.word1 = word1
        self.word2 = word2
        self.word3 = word3
        self.word4 = word4
        self.word5 = word5
    }
}

/// One immutable scene mutation. Transaction identifiers and scene revisions
/// are nonzero so an all-zero backing slot can never be mistaken for a message.
struct GraphicsSceneTransaction: Equatable {
    let transactionID: UInt64
    let sceneRevision: UInt64
    let opcode: GraphicsSceneTransactionOpcode
    let flags: UInt32
    let objectID: UInt64
    let payload: GraphicsSceneTransactionPayload

    init?(
        transactionID: UInt64,
        sceneRevision: UInt64,
        opcode: GraphicsSceneTransactionOpcode,
        flags: UInt32 = 0,
        objectID: UInt64 = 0,
        payload: GraphicsSceneTransactionPayload =
            GraphicsSceneTransactionPayload()
    ) {
        guard transactionID != 0, sceneRevision != 0 else { return nil }
        self.transactionID = transactionID
        self.sceneRevision = sceneRevision
        self.opcode = opcode
        self.flags = flags
        self.objectID = objectID
        self.payload = payload
    }
}

/// The only architecture-dependent operations required by the mailbox.
/// Production code injects LDAR/STLR veneers; host tests inject ordinary
/// functions. Ring slots themselves are published by the release-store of the
/// producer cursor and reclaimed by the release-store of the consumer cursor.
typealias GraphicsMailboxLoadAcquire = @convention(c) (
    UnsafePointer<UInt64>
) -> UInt64

typealias GraphicsMailboxStoreRelease = @convention(c) (
    UnsafeMutablePointer<UInt64>,
    UInt64
) -> Void

struct GraphicsMailboxAtomicAccess {
    private let loadAcquireFunction: GraphicsMailboxLoadAcquire
    private let storeReleaseFunction: GraphicsMailboxStoreRelease

    init(
        loadAcquire: @escaping GraphicsMailboxLoadAcquire,
        storeRelease: @escaping GraphicsMailboxStoreRelease
    ) {
        loadAcquireFunction = loadAcquire
        storeReleaseFunction = storeRelease
    }

    @inline(__always)
    func loadAcquire(_ address: UnsafePointer<UInt64>) -> UInt64 {
        loadAcquireFunction(address)
    }

    @inline(__always)
    func storeRelease(
        _ address: UnsafeMutablePointer<UInt64>,
        _ value: UInt64
    ) {
        storeReleaseFunction(address, value)
    }
}

enum GraphicsWorkerPhase: UInt64, Equatable {
    case unconfigured = 0
    case configured = 1
    case ready = 2
    case failed = 3
}

enum GraphicsWorkerStatus: Equatable {
    case unconfigured
    case configured(configurationSequence: UInt64)
    case ready(configurationSequence: UInt64)
    case failed(configurationSequence: UInt64, code: UInt64)
    case corrupt(rawPhase: UInt64)
}

enum GraphicsWorkerConfigurationResult: Equatable {
    case configured
    case invalidSequence
    case rejected(currentStatus: GraphicsWorkerStatus)
}

enum GraphicsWorkerTransitionResult: Equatable {
    case transitioned
    case invalidConfigurationSequence
    case invalidFailureCode
    case rejected(currentStatus: GraphicsWorkerStatus)
}

enum GraphicsSceneEnqueueResult: Equatable {
    /// `publishedCursor` is the cursor visible to the consumer after enqueue.
    case enqueued(publishedCursor: UInt64)
    case full(pendingCount: Int)
    case workerFailed(code: UInt64)
    case corrupt(pendingDistance: UInt64)
}

enum GraphicsSceneDequeueResult: Equatable {
    /// `reclaimedCursor` is visible to the producer after this slot is read.
    case dequeued(
        transaction: GraphicsSceneTransaction,
        reclaimedCursor: UInt64
    )
    case empty
    case corrupt(pendingDistance: UInt64)
}

struct GraphicsFrameRequestPublication: Equatable {
    let sequence: UInt64
    /// True when an older, incomplete request was replaced by this request.
    let coalescedPendingRequest: Bool
}

enum GraphicsFrameCompletionResult: Equatable {
    case completed
    case duplicate
    case notRequested
    case outOfOrder
}

struct GraphicsFrameSequenceSnapshot: Equatable {
    let requested: UInt64
    let completed: UInt64

    var hasPendingRequest: Bool { requested != completed }
}

/// Producer-only view of the shared mailbox. Exactly one CPU may invoke the
/// mutating publication methods, although copies of this value are harmless:
/// all durable state lives in the caller-owned shared buffers.
struct GraphicsWorkerMailboxProducer {
    private let shared: GraphicsWorkerMailboxSharedState

    fileprivate init(shared: GraphicsWorkerMailboxSharedState) {
        self.shared = shared
    }

    var workerStatus: GraphicsWorkerStatus { shared.workerStatus }

    var frameSequences: GraphicsFrameSequenceSnapshot {
        shared.frameSequences
    }

    var pendingTransactionCount: Int? {
        shared.pendingTransactionCount
    }

    func configureWorker(
        configurationSequence: UInt64
    ) -> GraphicsWorkerConfigurationResult {
        guard configurationSequence != 0 else { return .invalidSequence }
        let current = shared.workerStatus
        guard current == .unconfigured else {
            return .rejected(currentStatus: current)
        }

        shared.storeRelease(
            .configurationSequence,
            configurationSequence
        )
        shared.storeRelease(.failureCode, 0)
        shared.storeRelease(.workerPhase, GraphicsWorkerPhase.configured.rawValue)
        return .configured
    }

    /// Attempts one bounded enqueue. This method never waits for the worker,
    /// performs rendering, or touches a device register.
    func enqueue(
        _ transaction: GraphicsSceneTransaction
    ) -> GraphicsSceneEnqueueResult {
        if case .failed(_, let code) = shared.workerStatus {
            return .workerFailed(code: code)
        }

        let producer = shared.loadAcquire(.producerCursor)
        let consumer = shared.loadAcquire(.consumerCursor)
        let distance = producer &- consumer
        guard distance <= shared.capacity else {
            return .corrupt(pendingDistance: distance)
        }
        guard distance < shared.capacity else {
            return .full(pendingCount: Int(distance))
        }

        let slotIndex = Int(producer & shared.indexMask)
        shared.transactions[slotIndex] = transaction
        let published = producer &+ 1
        shared.storeRelease(.producerCursor, published)
        return .enqueued(publishedCursor: published)
    }

    /// Publishes a newest-only frame request. Repeated calls while a previous
    /// request is incomplete coalesce into one observable sequence value.
    func requestFrame() -> GraphicsFrameRequestPublication {
        let previous = shared.loadAcquire(.requestedFrameSequence)
        let completed = shared.loadAcquire(.completedFrameSequence)
        var next = previous &+ 1

        // Equality means "no pending request". Avoid that sentinel collision
        // even after a complete UInt64 wrap with a stalled consumer.
        if next == completed { next &+= 1 }
        shared.storeRelease(.requestedFrameSequence, next)
        return GraphicsFrameRequestPublication(
            sequence: next,
            coalescedPendingRequest: previous != completed
        )
    }
}

/// Worker-only view. The consumer can be polled; an event sent after producer
/// publication merely reduces latency and is never part of correctness.
struct GraphicsWorkerMailboxConsumer {
    private let shared: GraphicsWorkerMailboxSharedState

    fileprivate init(shared: GraphicsWorkerMailboxSharedState) {
        self.shared = shared
    }

    var workerStatus: GraphicsWorkerStatus { shared.workerStatus }

    var frameSequences: GraphicsFrameSequenceSnapshot {
        shared.frameSequences
    }

    var pendingTransactionCount: Int? {
        shared.pendingTransactionCount
    }

    func markReady(
        configurationSequence: UInt64
    ) -> GraphicsWorkerTransitionResult {
        let current = shared.workerStatus
        guard configurationSequence != 0 else {
            return .invalidConfigurationSequence
        }
        guard current == .configured(
                  configurationSequence: configurationSequence
              )
        else {
            return .rejected(currentStatus: current)
        }
        shared.storeRelease(.workerPhase, GraphicsWorkerPhase.ready.rawValue)
        return .transitioned
    }

    func markFailed(
        configurationSequence: UInt64,
        code: UInt64
    ) -> GraphicsWorkerTransitionResult {
        guard configurationSequence != 0 else {
            return .invalidConfigurationSequence
        }
        guard code != 0 else { return .invalidFailureCode }

        let current = shared.workerStatus
        let matchesConfiguration: Bool
        switch current {
        case .configured(let currentSequence), .ready(let currentSequence):
            matchesConfiguration = currentSequence == configurationSequence
        default:
            matchesConfiguration = false
        }
        guard matchesConfiguration else {
            return .rejected(currentStatus: current)
        }

        // Failure details precede the phase release-store. Observing FAILED
        // with an acquire-load therefore makes the code visible as well.
        shared.storeRelease(.failureCode, code)
        shared.storeRelease(.workerPhase, GraphicsWorkerPhase.failed.rawValue)
        return .transitioned
    }

    /// Attempts one bounded dequeue. An empty result is not a failure and the
    /// caller may poll again regardless of whether it received a wake event.
    func dequeue() -> GraphicsSceneDequeueResult {
        let consumer = shared.loadAcquire(.consumerCursor)
        let producer = shared.loadAcquire(.producerCursor)
        let distance = producer &- consumer
        guard distance <= shared.capacity else {
            return .corrupt(pendingDistance: distance)
        }
        guard distance != 0 else { return .empty }

        let slotIndex = Int(consumer & shared.indexMask)
        let transaction = shared.transactions[slotIndex]
        let reclaimed = consumer &+ 1
        shared.storeRelease(.consumerCursor, reclaimed)
        return .dequeued(
            transaction: transaction,
            reclaimedCursor: reclaimed
        )
    }

    /// Returns the most recently published request when it differs from the
    /// worker's last observation. Intermediate requests are intentionally
    /// coalesced rather than queued.
    func latestFrameRequest(after observedSequence: UInt64) -> UInt64? {
        let requested = shared.loadAcquire(.requestedFrameSequence)
        return requested == observedSequence ? nil : requested
    }

    /// Publishes GPU completion for a request previously observed by this
    /// worker. Serial-number arithmetic supports normal UInt64 wrap provided
    /// producer/consumer separation remains below half the sequence domain.
    func completeFrame(
        sequence: UInt64
    ) -> GraphicsFrameCompletionResult {
        let completed = shared.loadAcquire(.completedFrameSequence)
        if sequence == completed { return .duplicate }
        guard GraphicsMailboxSerialNumber.isAfter(sequence, completed) else {
            return .outOfOrder
        }

        let requested = shared.loadAcquire(.requestedFrameSequence)
        guard sequence == requested
                || GraphicsMailboxSerialNumber.isAfter(requested, sequence)
        else {
            return .notRequested
        }
        shared.storeRelease(.completedFrameSequence, sequence)
        return .completed
    }
}

/// Owns no memory. Initialization prepares caller-owned shared storage, then
/// role-specific endpoint values may be copied to their respective CPUs.
struct GraphicsWorkerMailbox {
    /// producer cursor, consumer cursor, requested frame, completed frame,
    /// phase, configuration sequence, and failure code.
    static let requiredControlWordCount = 7
    static let minimumTransactionCapacity = 2

    let producer: GraphicsWorkerMailboxProducer
    let worker: GraphicsWorkerMailboxConsumer

    init?(
        transactionStorage: UnsafeMutableBufferPointer<GraphicsSceneTransaction>,
        controlStorage: UnsafeMutableBufferPointer<UInt64>,
        atomicAccess: GraphicsMailboxAtomicAccess,
        initialRingCursor: UInt64 = 0,
        initialFrameSequence: UInt64 = 0
    ) {
        let capacity = transactionStorage.count
        guard capacity >= Self.minimumTransactionCapacity,
              capacity & (capacity - 1) == 0,
              controlStorage.count >= Self.requiredControlWordCount,
              let transactionBase = transactionStorage.baseAddress,
              let controlBase = controlStorage.baseAddress,
              UInt(bitPattern: transactionBase)
                  % UInt(MemoryLayout<GraphicsSceneTransaction>.alignment) == 0,
              UInt(bitPattern: controlBase)
                  % UInt(MemoryLayout<UInt64>.alignment) == 0,
              let capacity64 = UInt64(exactly: capacity)
        else {
            return nil
        }

        var index = 0
        while index < Self.requiredControlWordCount {
            controlStorage[index] = 0
            index += 1
        }
        controlStorage[GraphicsMailboxControlWord.producerCursor.rawValue] =
            initialRingCursor
        controlStorage[GraphicsMailboxControlWord.consumerCursor.rawValue] =
            initialRingCursor
        controlStorage[
            GraphicsMailboxControlWord.requestedFrameSequence.rawValue
        ] = initialFrameSequence
        controlStorage[
            GraphicsMailboxControlWord.completedFrameSequence.rawValue
        ] = initialFrameSequence

        let shared = GraphicsWorkerMailboxSharedState(
            transactions: transactionStorage,
            control: controlStorage,
            atomics: atomicAccess,
            capacity: capacity64
        )
        producer = GraphicsWorkerMailboxProducer(shared: shared)
        worker = GraphicsWorkerMailboxConsumer(shared: shared)
    }
}

private enum GraphicsMailboxControlWord: Int {
    case producerCursor = 0
    case consumerCursor = 1
    case requestedFrameSequence = 2
    case completedFrameSequence = 3
    case workerPhase = 4
    case configurationSequence = 5
    case failureCode = 6
}

private struct GraphicsWorkerMailboxSharedState {
    let transactions: UnsafeMutableBufferPointer<GraphicsSceneTransaction>
    private let control: UnsafeMutableBufferPointer<UInt64>
    private let atomics: GraphicsMailboxAtomicAccess
    let capacity: UInt64
    let indexMask: UInt64

    init(
        transactions: UnsafeMutableBufferPointer<GraphicsSceneTransaction>,
        control: UnsafeMutableBufferPointer<UInt64>,
        atomics: GraphicsMailboxAtomicAccess,
        capacity: UInt64
    ) {
        self.transactions = transactions
        self.control = control
        self.atomics = atomics
        self.capacity = capacity
        indexMask = capacity - 1
    }

    var workerStatus: GraphicsWorkerStatus {
        let rawPhase = loadAcquire(.workerPhase)
        guard let phase = GraphicsWorkerPhase(rawValue: rawPhase) else {
            return .corrupt(rawPhase: rawPhase)
        }
        switch phase {
        case .unconfigured:
            return .unconfigured
        case .configured:
            return .configured(
                configurationSequence: loadAcquire(.configurationSequence)
            )
        case .ready:
            return .ready(
                configurationSequence: loadAcquire(.configurationSequence)
            )
        case .failed:
            return .failed(
                configurationSequence: loadAcquire(.configurationSequence),
                code: loadAcquire(.failureCode)
            )
        }
    }

    var frameSequences: GraphicsFrameSequenceSnapshot {
        GraphicsFrameSequenceSnapshot(
            requested: loadAcquire(.requestedFrameSequence),
            completed: loadAcquire(.completedFrameSequence)
        )
    }

    var pendingTransactionCount: Int? {
        let producer = loadAcquire(.producerCursor)
        let consumer = loadAcquire(.consumerCursor)
        let distance = producer &- consumer
        guard distance <= capacity else { return nil }
        return Int(distance)
    }

    @inline(__always)
    func loadAcquire(_ word: GraphicsMailboxControlWord) -> UInt64 {
        atomics.loadAcquire(control.baseAddress!.advanced(by: word.rawValue))
    }

    @inline(__always)
    func storeRelease(_ word: GraphicsMailboxControlWord, _ value: UInt64) {
        atomics.storeRelease(
            control.baseAddress!.advanced(by: word.rawValue),
            value
        )
    }
}

private enum GraphicsMailboxSerialNumber {
    /// RFC-1982-style comparison. Exactly half a UInt64 domain apart is
    /// intentionally unordered, preventing an ambiguous completion advance.
    static func isAfter(_ candidate: UInt64, _ reference: UInt64) -> Bool {
        let distance = candidate &- reference
        return distance != 0 && distance < (UInt64(1) << 63)
    }
}
