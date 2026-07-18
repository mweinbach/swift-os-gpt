/// Opaque namespaces let a GPU backend identify handles without exposing its
/// packet format to the compositor. VirtIO resources, V3D buffer objects, and
/// firmware-owned images can therefore coexist in one scheduler.
struct GPUHandleNamespace: Equatable {
    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct GPUResourceHandle: Equatable {
    let namespace: GPUHandleNamespace
    let value: UInt64

    init?(namespace: GPUHandleNamespace, value: UInt64) {
        guard value != 0 else { return nil }
        self.namespace = namespace
        self.value = value
    }
}

struct GPUMemoryObjectHandle: Equatable {
    let namespace: GPUHandleNamespace
    let value: UInt64

    init?(namespace: GPUHandleNamespace, value: UInt64) {
        guard value != 0 else { return nil }
        self.namespace = namespace
        self.value = value
    }
}

/// A byte range within backend-visible memory. Slots may use different memory
/// namespaces, or non-overlapping ranges of one shared allocation.
struct GPUMemoryBinding: Equatable {
    let object: GPUMemoryObjectHandle
    let byteOffset: UInt64
    let byteCount: UInt64

    init?(
        object: GPUMemoryObjectHandle,
        byteOffset: UInt64,
        byteCount: UInt64
    ) {
        guard byteCount != 0,
              !byteOffset.addingReportingOverflow(byteCount).overflow
        else {
            return nil
        }
        self.object = object
        self.byteOffset = byteOffset
        self.byteCount = byteCount
    }

    var endByteOffset: UInt64 { byteOffset + byteCount }

    func overlaps(_ other: GPUMemoryBinding) -> Bool {
        guard object == other.object else { return false }
        return byteOffset < other.endByteOffset
            && other.byteOffset < endByteOffset
    }
}

/// The stable render-target identity used by the command IR, its opaque
/// backend resource, and the memory which owns its pixels.
struct GPUFrameSlotResources: Equatable {
    let renderTarget: GPURenderTargetID
    let image: GPUResourceHandle
    let memory: GPUMemoryBinding
}

struct GPUFrameSlotID: Equatable {
    static let slotCount = 3

    static let first = GPUFrameSlotID(validatedRawValue: 0)
    static let second = GPUFrameSlotID(validatedRawValue: 1)
    static let third = GPUFrameSlotID(validatedRawValue: 2)

    let rawValue: UInt8

    init?(rawValue: UInt8) {
        guard rawValue < UInt8(Self.slotCount) else { return nil }
        self.rawValue = rawValue
    }

    private init(validatedRawValue: UInt8) {
        rawValue = validatedRawValue
    }
}

struct GPUFrameRequest: Equatable {
    let requestID: UInt64
    let sceneRevision: UInt64

    init?(requestID: UInt64, sceneRevision: UInt64) {
        guard requestID != 0 else { return nil }
        self.requestID = requestID
        self.sceneRevision = sceneRevision
    }
}

struct GPUFrameIdentity: Equatable {
    let epoch: UInt64
    let frameID: UInt64
    let request: GPUFrameRequest

    fileprivate init(epoch: UInt64, frameID: UInt64, request: GPUFrameRequest) {
        self.epoch = epoch
        self.frameID = frameID
        self.request = request
    }
}

/// A fence is scoped to the scheduler epoch in which its backend queue exists.
/// This prevents a delayed pre-reset completion from retiring a new image.
struct GPUFrameFence: Equatable {
    let epoch: UInt64
    let point: GPUFencePoint

    init?(epoch: UInt64, point: GPUFencePoint) {
        guard epoch != 0 else { return nil }
        self.epoch = epoch
        self.point = point
    }
}

struct GPUFrameLease: Equatable {
    let slot: GPUFrameSlotID
    let identity: GPUFrameIdentity
    let resources: GPUFrameSlotResources

    fileprivate init(
        slot: GPUFrameSlotID,
        identity: GPUFrameIdentity,
        resources: GPUFrameSlotResources
    ) {
        self.slot = slot
        self.identity = identity
        self.resources = resources
    }
}

enum GPUFrameSlotState: Equatable {
    case available
    case acquired(GPUFrameIdentity)
    case submitted(GPUFrameIdentity, renderFence: GPUFrameFence)
    case presenting(
        GPUFrameIdentity,
        renderFence: GPUFrameFence,
        presentationFence: GPUFrameFence
    )

    var identity: GPUFrameIdentity? {
        switch self {
        case .available:
            return nil
        case .acquired(let identity),
             .submitted(let identity, _),
             .presenting(let identity, _, _):
            return identity
        }
    }
}

struct GPUFrameSlotSnapshot: Equatable {
    let slot: GPUFrameSlotID
    let resources: GPUFrameSlotResources
    let state: GPUFrameSlotState
}

enum GPUFrameSchedulerFailure: Equatable {
    case deviceLost
    case submissionFailed
    case presentationFailed
    case timedOut
    case identifierSpaceExhausted
    case backend(code: UInt32)
}

enum GPUFrameSchedulerStatus: Equatable {
    case operational(epoch: UInt64)
    case failed(epoch: UInt64, reason: GPUFrameSchedulerFailure)

    var epoch: UInt64 {
        switch self {
        case .operational(let epoch), .failed(let epoch, _): return epoch
        }
    }
}

struct GPUFrameSchedulerStatistics: Equatable {
    fileprivate(set) var acceptedRequestCount: UInt64 = 0
    fileprivate(set) var coalescedRequestCount: UInt64 = 0
    fileprivate(set) var droppedRequestCount: UInt64 = 0
    fileprivate(set) var rejectedRequestCount: UInt64 = 0
    fileprivate(set) var busyAcquireCount: UInt64 = 0
    fileprivate(set) var acquiredFrameCount: UInt64 = 0
    fileprivate(set) var abandonedFrameCount: UInt64 = 0
    fileprivate(set) var submittedFrameCount: UInt64 = 0
    fileprivate(set) var queuedPresentationCount: UInt64 = 0
    fileprivate(set) var retiredFrameCount: UInt64 = 0
    fileprivate(set) var failureCount: UInt64 = 0
    fileprivate(set) var resetCount: UInt64 = 0
}

enum GPUFrameRequestRejection: Equatable {
    case schedulerFailed(GPUFrameSchedulerFailure)
    case requestIDNotIncreasing
}

enum GPUFrameRequestResult: Equatable {
    case queued
    case coalesced(replacedRequestID: UInt64)
    case rejected(GPUFrameRequestRejection)
}

enum GPUFrameAcquireResult: Equatable {
    case acquired(GPUFrameLease)
    case noPendingRequest
    case busy
    case failed(GPUFrameSchedulerFailure)
}

enum GPUFrameTransitionRejection: Equatable {
    case schedulerFailed(GPUFrameSchedulerFailure)
    case staleEpoch
    case leaseMismatch
    case invalidSlotState
    case wrongQueue
    case fenceNotIncreasing
    case frameOrderViolation
}

enum GPUFrameTransitionResult: Equatable {
    case transitioned
    case rejected(GPUFrameTransitionRejection)
}

struct GPUFrameRetirement: Equatable {
    let slot: GPUFrameSlotID
    let identity: GPUFrameIdentity
}

/// At most three images can retire from one completion, so retirement storage
/// remains inline rather than allocating an Array in the kernel.
struct GPUFrameRetirementBatch: Equatable {
    private(set) var count: Int = 0
    private var retirement0: GPUFrameRetirement?
    private var retirement1: GPUFrameRetirement?
    private var retirement2: GPUFrameRetirement?

    func retirement(at index: Int) -> GPUFrameRetirement? {
        guard index >= 0, index < count else { return nil }
        return storedRetirement(at: index)
    }

    fileprivate mutating func append(_ retirement: GPUFrameRetirement) {
        guard count < GPUFrameSlotID.slotCount else { return }
        var insertionIndex = count
        while insertionIndex > 0,
              let previous = storedRetirement(at: insertionIndex - 1),
              previous.identity.frameID > retirement.identity.frameID {
            setStoredRetirement(previous, at: insertionIndex)
            insertionIndex -= 1
        }
        setStoredRetirement(retirement, at: insertionIndex)
        count += 1
    }

    private func storedRetirement(at index: Int) -> GPUFrameRetirement? {
        switch index {
        case 0: return retirement0
        case 1: return retirement1
        default: return retirement2
        }
    }

    private mutating func setStoredRetirement(
        _ retirement: GPUFrameRetirement,
        at index: Int
    ) {
        switch index {
        case 0: retirement0 = retirement
        case 1: retirement1 = retirement
        default: retirement2 = retirement
        }
    }
}

enum GPUFenceCompletionRejection: Equatable {
    case schedulerFailed(GPUFrameSchedulerFailure)
    case staleEpoch
    case unknownQueue
    case fenceRegressed
    case fenceBeyondSubmittedWork
}

enum GPUFenceCompletionResult: Equatable {
    case advanced(retired: GPUFrameRetirementBatch)
    case unchanged
    case rejected(GPUFenceCompletionRejection)
}

enum GPUFrameFailureResult: Equatable {
    case enteredFailedState
    case alreadyFailed
}

enum GPUFrameResetRejection: Equatable {
    case schedulerNotFailed
    case epochSpaceExhausted
}

enum GPUFrameResetResult: Equatable {
    case reset(epoch: UInt64)
    case rejected(GPUFrameResetRejection)
}

/// Allocation-free triple-buffer ownership and fence state machine.
///
/// Rendering and presentation may be pipelined, but a submitted image is never
/// returned to the compositor until its presentation fence completes. On a
/// device failure every slot remains quarantined until the backend explicitly
/// confirms quiescence by resetting the scheduler.
struct GPUTripleBufferFrameScheduler {
    let renderQueue: GPUQueueID
    let presentationQueue: GPUQueueID

    private let resources0: GPUFrameSlotResources
    private let resources1: GPUFrameSlotResources
    private let resources2: GPUFrameSlotResources

    private var state0 = GPUFrameSlotState.available
    private var state1 = GPUFrameSlotState.available
    private var state2 = GPUFrameSlotState.available

    private(set) var status = GPUFrameSchedulerStatus.operational(epoch: 1)
    private(set) var statistics = GPUFrameSchedulerStatistics()
    private(set) var pendingRequest: GPUFrameRequest?
    private(set) var lastAcceptedRequestID: UInt64 = 0
    private(set) var lastIssuedFrameID: UInt64 = 0
    private(set) var lastSubmittedFrameID: UInt64 = 0
    private(set) var lastQueuedPresentationFrameID: UInt64 = 0

    private var renderSubmittedFenceValue: UInt64 = 0
    private var presentationSubmittedFenceValue: UInt64 = 0
    private var renderCompletedFenceValue: UInt64 = 0
    private var presentationCompletedFenceValue: UInt64 = 0
    private var nextSearchIndex: UInt8 = 0

    init?(
        renderQueue: GPUQueueID,
        presentationQueue: GPUQueueID,
        slot0: GPUFrameSlotResources,
        slot1: GPUFrameSlotResources,
        slot2: GPUFrameSlotResources
    ) {
        guard Self.resourcesAreIndependent(slot0, slot1),
              Self.resourcesAreIndependent(slot0, slot2),
              Self.resourcesAreIndependent(slot1, slot2)
        else {
            return nil
        }
        self.renderQueue = renderQueue
        self.presentationQueue = presentationQueue
        resources0 = slot0
        resources1 = slot1
        resources2 = slot2
    }

    var currentEpoch: UInt64 { status.epoch }

    var availableSlotCount: Int {
        var count = 0
        if state0 == .available { count += 1 }
        if state1 == .available { count += 1 }
        if state2 == .available { count += 1 }
        return count
    }

    func snapshot(for slot: GPUFrameSlotID) -> GPUFrameSlotSnapshot {
        GPUFrameSlotSnapshot(
            slot: slot,
            resources: resources(at: slot),
            state: state(at: slot)
        )
    }

    mutating func requestFrame(_ request: GPUFrameRequest) -> GPUFrameRequestResult {
        guard case .operational = status else {
            statistics.rejectedRequestCount = Self.incremented(
                statistics.rejectedRequestCount
            )
            if case .failed(_, let reason) = status {
                return .rejected(.schedulerFailed(reason))
            }
            return .rejected(.requestIDNotIncreasing)
        }
        guard request.requestID > lastAcceptedRequestID else {
            statistics.rejectedRequestCount = Self.incremented(
                statistics.rejectedRequestCount
            )
            return .rejected(.requestIDNotIncreasing)
        }

        statistics.acceptedRequestCount = Self.incremented(
            statistics.acceptedRequestCount
        )
        lastAcceptedRequestID = request.requestID
        if let previous = pendingRequest {
            pendingRequest = request
            statistics.coalescedRequestCount = Self.incremented(
                statistics.coalescedRequestCount
            )
            statistics.droppedRequestCount = Self.incremented(
                statistics.droppedRequestCount
            )
            return .coalesced(replacedRequestID: previous.requestID)
        }
        pendingRequest = request
        return .queued
    }

    mutating func acquireNextFrame() -> GPUFrameAcquireResult {
        guard case .operational(let epoch) = status else {
            if case .failed(_, let reason) = status { return .failed(reason) }
            return .failed(.identifierSpaceExhausted)
        }
        guard let request = pendingRequest else { return .noPendingRequest }
        guard let slot = firstAvailableSlot() else {
            statistics.busyAcquireCount = Self.incremented(
                statistics.busyAcquireCount
            )
            return .busy
        }
        let nextFrame = lastIssuedFrameID.addingReportingOverflow(1)
        guard !nextFrame.overflow, nextFrame.partialValue != 0 else {
            _ = fail(.identifierSpaceExhausted)
            return .failed(.identifierSpaceExhausted)
        }

        let identity = GPUFrameIdentity(
            epoch: epoch,
            frameID: nextFrame.partialValue,
            request: request
        )
        setState(.acquired(identity), at: slot)
        pendingRequest = nil
        lastIssuedFrameID = identity.frameID
        nextSearchIndex = (slot.rawValue + 1) % UInt8(GPUFrameSlotID.slotCount)
        statistics.acquiredFrameCount = Self.incremented(
            statistics.acquiredFrameCount
        )
        return .acquired(
            GPUFrameLease(
                slot: slot,
                identity: identity,
                resources: resources(at: slot)
            )
        )
    }

    /// Releases an image which has not reached the device. Submitted and
    /// presenting images deliberately have no cancellation transition.
    mutating func abandon(_ lease: GPUFrameLease) -> GPUFrameTransitionResult {
        if let rejection = validateOperationalLease(lease) {
            return .rejected(rejection)
        }
        guard state(at: lease.slot) == .acquired(lease.identity) else {
            return .rejected(.invalidSlotState)
        }
        setState(.available, at: lease.slot)
        statistics.abandonedFrameCount = Self.incremented(
            statistics.abandonedFrameCount
        )
        return .transitioned
    }

    mutating func submit(
        _ lease: GPUFrameLease,
        signaling point: GPUFencePoint
    ) -> GPUFrameTransitionResult {
        if let rejection = validateOperationalLease(lease) {
            return .rejected(rejection)
        }
        guard state(at: lease.slot) == .acquired(lease.identity) else {
            return .rejected(.invalidSlotState)
        }
        guard point.queue == renderQueue else { return .rejected(.wrongQueue) }
        guard !hasEarlierAcquiredFrame(than: lease.identity.frameID),
              lease.identity.frameID > lastSubmittedFrameID
        else {
            return .rejected(.frameOrderViolation)
        }
        guard point.value > submittedFenceWatermark(for: point.queue) else {
            return .rejected(.fenceNotIncreasing)
        }
        guard let fence = GPUFrameFence(epoch: currentEpoch, point: point) else {
            return .rejected(.staleEpoch)
        }

        recordSubmittedFence(point)
        setState(
            .submitted(lease.identity, renderFence: fence),
            at: lease.slot
        )
        lastSubmittedFrameID = lease.identity.frameID
        statistics.submittedFrameCount = Self.incremented(
            statistics.submittedFrameCount
        )
        return .transitioned
    }

    mutating func beginPresentation(
        _ lease: GPUFrameLease,
        signaling point: GPUFencePoint
    ) -> GPUFrameTransitionResult {
        if let rejection = validateOperationalLease(lease) {
            return .rejected(rejection)
        }
        guard case .submitted(let identity, let renderFence) = state(at: lease.slot),
              identity == lease.identity
        else {
            return .rejected(.invalidSlotState)
        }
        guard point.queue == presentationQueue else {
            return .rejected(.wrongQueue)
        }
        guard !hasEarlierUnpresentedFrame(than: identity.frameID),
              identity.frameID > lastQueuedPresentationFrameID
        else {
            return .rejected(.frameOrderViolation)
        }
        guard point.value > submittedFenceWatermark(for: point.queue) else {
            return .rejected(.fenceNotIncreasing)
        }
        guard let presentationFence = GPUFrameFence(
            epoch: currentEpoch,
            point: point
        ) else {
            return .rejected(.staleEpoch)
        }

        recordSubmittedFence(point)
        setState(
            .presenting(
                identity,
                renderFence: renderFence,
                presentationFence: presentationFence
            ),
            at: lease.slot
        )
        lastQueuedPresentationFrameID = identity.frameID
        statistics.queuedPresentationCount = Self.incremented(
            statistics.queuedPresentationCount
        )
        return .transitioned
    }

    /// Advances a backend queue timeline and retires every presentation covered
    /// by it. Duplicate completions are harmless; regressions and completions
    /// beyond submitted work are rejected as backend contract violations.
    mutating func completeFence(
        _ fence: GPUFrameFence
    ) -> GPUFenceCompletionResult {
        guard case .operational = status else {
            if case .failed(_, let reason) = status {
                return .rejected(.schedulerFailed(reason))
            }
            return .rejected(.staleEpoch)
        }
        guard fence.epoch == currentEpoch else { return .rejected(.staleEpoch) }
        let point = fence.point
        guard point.queue == renderQueue || point.queue == presentationQueue else {
            return .rejected(.unknownQueue)
        }

        let completed = completedFenceWatermark(for: point.queue)
        guard point.value >= completed else { return .rejected(.fenceRegressed) }
        guard point.value <= submittedFenceWatermark(for: point.queue) else {
            return .rejected(.fenceBeyondSubmittedWork)
        }
        guard point.value != completed else { return .unchanged }

        recordCompletedFence(point)
        var retired = GPUFrameRetirementBatch()
        retireCompletedPresentations(into: &retired)
        return .advanced(retired: retired)
    }

    mutating func fail(
        _ reason: GPUFrameSchedulerFailure
    ) -> GPUFrameFailureResult {
        guard case .operational(let epoch) = status else {
            return .alreadyFailed
        }
        status = .failed(epoch: epoch, reason: reason)
        statistics.failureCount = Self.incremented(statistics.failureCount)
        return .enteredFailedState
    }

    /// The caller must only invoke this after the backend has stopped every
    /// queue and can prove no pre-reset DMA or scanout still references a slot.
    mutating func resetAfterDeviceQuiescence() -> GPUFrameResetResult {
        guard case .failed(let oldEpoch, _) = status else {
            return .rejected(.schedulerNotFailed)
        }
        let nextEpoch = oldEpoch.addingReportingOverflow(1)
        guard !nextEpoch.overflow, nextEpoch.partialValue != 0 else {
            return .rejected(.epochSpaceExhausted)
        }

        if pendingRequest != nil {
            statistics.droppedRequestCount = Self.incremented(
                statistics.droppedRequestCount
            )
        }
        pendingRequest = nil
        state0 = .available
        state1 = .available
        state2 = .available
        renderSubmittedFenceValue = 0
        presentationSubmittedFenceValue = 0
        renderCompletedFenceValue = 0
        presentationCompletedFenceValue = 0
        nextSearchIndex = 0
        status = .operational(epoch: nextEpoch.partialValue)
        statistics.resetCount = Self.incremented(statistics.resetCount)
        return .reset(epoch: nextEpoch.partialValue)
    }

    private static func resourcesAreIndependent(
        _ lhs: GPUFrameSlotResources,
        _ rhs: GPUFrameSlotResources
    ) -> Bool {
        lhs.renderTarget != rhs.renderTarget
            && lhs.image != rhs.image
            && !lhs.memory.overlaps(rhs.memory)
    }

    private func resources(at slot: GPUFrameSlotID) -> GPUFrameSlotResources {
        switch slot.rawValue {
        case 0: return resources0
        case 1: return resources1
        default: return resources2
        }
    }

    private func state(at slot: GPUFrameSlotID) -> GPUFrameSlotState {
        switch slot.rawValue {
        case 0: return state0
        case 1: return state1
        default: return state2
        }
    }

    private mutating func setState(
        _ state: GPUFrameSlotState,
        at slot: GPUFrameSlotID
    ) {
        switch slot.rawValue {
        case 0: state0 = state
        case 1: state1 = state
        default: state2 = state
        }
    }

    private func firstAvailableSlot() -> GPUFrameSlotID? {
        var offset: UInt8 = 0
        while offset < UInt8(GPUFrameSlotID.slotCount) {
            let raw = (nextSearchIndex + offset) % UInt8(GPUFrameSlotID.slotCount)
            if let slot = GPUFrameSlotID(rawValue: raw), state(at: slot) == .available {
                return slot
            }
            offset += 1
        }
        return nil
    }

    private func validateOperationalLease(
        _ lease: GPUFrameLease
    ) -> GPUFrameTransitionRejection? {
        guard case .operational(let epoch) = status else {
            if case .failed(_, let reason) = status {
                return .schedulerFailed(reason)
            }
            return .staleEpoch
        }
        guard lease.identity.epoch == epoch else { return .staleEpoch }
        guard state(at: lease.slot).identity == lease.identity,
              resources(at: lease.slot) == lease.resources
        else {
            return .leaseMismatch
        }
        return nil
    }

    private func hasEarlierAcquiredFrame(than frameID: UInt64) -> Bool {
        isAcquiredFrameEarlier(state0, than: frameID)
            || isAcquiredFrameEarlier(state1, than: frameID)
            || isAcquiredFrameEarlier(state2, than: frameID)
    }

    private func isAcquiredFrameEarlier(
        _ state: GPUFrameSlotState,
        than frameID: UInt64
    ) -> Bool {
        guard case .acquired(let identity) = state else { return false }
        return identity.frameID < frameID
    }

    private func hasEarlierUnpresentedFrame(than frameID: UInt64) -> Bool {
        isUnpresentedFrameEarlier(state0, than: frameID)
            || isUnpresentedFrameEarlier(state1, than: frameID)
            || isUnpresentedFrameEarlier(state2, than: frameID)
    }

    private func isUnpresentedFrameEarlier(
        _ state: GPUFrameSlotState,
        than frameID: UInt64
    ) -> Bool {
        switch state {
        case .acquired(let identity), .submitted(let identity, _):
            return identity.frameID < frameID
        case .available, .presenting:
            return false
        }
    }

    private func submittedFenceWatermark(for queue: GPUQueueID) -> UInt64 {
        if renderQueue == presentationQueue {
            return renderSubmittedFenceValue > presentationSubmittedFenceValue
                ? renderSubmittedFenceValue
                : presentationSubmittedFenceValue
        }
        if queue == renderQueue { return renderSubmittedFenceValue }
        return presentationSubmittedFenceValue
    }

    private mutating func recordSubmittedFence(_ point: GPUFencePoint) {
        if point.queue == renderQueue { renderSubmittedFenceValue = point.value }
        if point.queue == presentationQueue {
            presentationSubmittedFenceValue = point.value
        }
    }

    private func completedFenceWatermark(for queue: GPUQueueID) -> UInt64 {
        if renderQueue == presentationQueue {
            return renderCompletedFenceValue > presentationCompletedFenceValue
                ? renderCompletedFenceValue
                : presentationCompletedFenceValue
        }
        if queue == renderQueue { return renderCompletedFenceValue }
        return presentationCompletedFenceValue
    }

    private mutating func recordCompletedFence(_ point: GPUFencePoint) {
        if point.queue == renderQueue { renderCompletedFenceValue = point.value }
        if point.queue == presentationQueue {
            presentationCompletedFenceValue = point.value
        }
    }

    private mutating func retireCompletedPresentations(
        into batch: inout GPUFrameRetirementBatch
    ) {
        retireCompletedPresentation(at: .first, into: &batch)
        retireCompletedPresentation(at: .second, into: &batch)
        retireCompletedPresentation(at: .third, into: &batch)
    }

    private mutating func retireCompletedPresentation(
        at slot: GPUFrameSlotID,
        into batch: inout GPUFrameRetirementBatch
    ) {
        guard case .presenting(let identity, _, let fence) = state(at: slot),
              fence.epoch == currentEpoch,
              fence.point.value <= completedFenceWatermark(for: fence.point.queue)
        else {
            return
        }
        setState(.available, at: slot)
        batch.append(GPUFrameRetirement(slot: slot, identity: identity))
        statistics.retiredFrameCount = Self.incremented(
            statistics.retiredFrameCount
        )
    }

    private static func incremented(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }
}
