@main
struct GPUFrameSchedulerTests {
    static func main() {
        validatesOpaqueHandlesAndMemoryBindings()
        validatesIndependentTripleBufferResources()
        ordersAndCoalescesFrameRequests()
        pipelinesThreeFramesWithoutEarlyReuse()
        ordersRetirementsByFrameIDAfterSlotReuse()
        sharesOneQueueTimelineSafely()
        abandonsOnlyCPUOwnedFrames()
        quarantinesSlotsAcrossFailureAndReset()
        preservesValueSemantics()
        print("GPU frame scheduler host tests: 9 groups passed")
    }

    private static func validatesOpaqueHandlesAndMemoryBindings() {
        expect(GPUHandleNamespace(rawValue: 0) == nil, "zero namespace accepted")
        let system = namespace(1)
        let device = namespace(2)
        expect(
            GPUResourceHandle(namespace: system, value: 0) == nil,
            "zero resource handle accepted"
        )
        expect(
            GPUMemoryObjectHandle(namespace: device, value: 0) == nil,
            "zero memory handle accepted"
        )
        expect(
            GPUMemoryBinding(
                object: memoryObject(namespaceID: 1, value: 1),
                byteOffset: 0,
                byteCount: 0
            ) == nil,
            "empty memory binding accepted"
        )
        expect(
            GPUMemoryBinding(
                object: memoryObject(namespaceID: 1, value: 1),
                byteOffset: UInt64.max,
                byteCount: 1
            ) == nil,
            "overflowing memory binding accepted"
        )

        let object = memoryObject(namespaceID: 1, value: 9)
        let first = memoryBinding(object: object, offset: 0, count: 4_096)
        let adjacent = memoryBinding(object: object, offset: 4_096, count: 4_096)
        let overlap = memoryBinding(object: object, offset: 2_048, count: 4_096)
        let foreign = memoryBinding(
            object: memoryObject(namespaceID: 2, value: 9),
            offset: 0,
            count: 4_096
        )
        expect(!first.overlaps(adjacent), "adjacent memory ranges overlap")
        expect(first.overlaps(overlap), "overlap not detected")
        expect(!first.overlaps(foreign), "foreign memory objects overlap")
        expect(first.endByteOffset == 4_096, "binding end offset")
    }

    private static func validatesIndependentTripleBufferResources() {
        let slot0 = resources(
            targetID: 1,
            resourceNamespace: 10,
            resourceValue: 100,
            memoryNamespace: 20,
            memoryValue: 200,
            offset: 0
        )
        let slot1 = resources(
            targetID: 2,
            resourceNamespace: 11,
            resourceValue: 101,
            memoryNamespace: 21,
            memoryValue: 201,
            offset: 0
        )
        let slot2 = resources(
            targetID: 3,
            resourceNamespace: 12,
            resourceValue: 102,
            memoryNamespace: 22,
            memoryValue: 202,
            offset: 0
        )
        let scheduler = requireScheduler(slot0: slot0, slot1: slot1, slot2: slot2)
        expect(scheduler.availableSlotCount == 3, "initial available count")
        expect(scheduler.currentEpoch == 1, "initial epoch")
        expect(scheduler.snapshot(for: .first).resources == slot0, "slot zero resources")
        expect(scheduler.snapshot(for: .second).state == .available, "slot one state")
        expect(
            scheduler.snapshot(for: .third).resources.memory.object.namespace
                == namespace(22),
            "heterogeneous memory namespace"
        )
        expect(GPUFrameSlotID(rawValue: 3) == nil, "fourth triple-buffer slot accepted")

        expect(
            GPUTripleBufferFrameScheduler(
                renderQueue: queue(1),
                presentationQueue: queue(2),
                slot0: slot0,
                slot1: slot0,
                slot2: slot2
            ) == nil,
            "aliased render resources accepted"
        )

        let sharedObject = memoryObject(namespaceID: 30, value: 300)
        let shared0 = resources(
            targetID: 4,
            resourceNamespace: 40,
            resourceValue: 400,
            memory: memoryBinding(object: sharedObject, offset: 0, count: 4_096)
        )
        let shared1 = resources(
            targetID: 5,
            resourceNamespace: 40,
            resourceValue: 401,
            memory: memoryBinding(object: sharedObject, offset: 4_096, count: 4_096)
        )
        let shared2 = resources(
            targetID: 6,
            resourceNamespace: 40,
            resourceValue: 402,
            memory: memoryBinding(object: sharedObject, offset: 8_192, count: 4_096)
        )
        expect(
            GPUTripleBufferFrameScheduler(
                renderQueue: queue(1),
                presentationQueue: queue(2),
                slot0: shared0,
                slot1: shared1,
                slot2: shared2
            ) != nil,
            "disjoint ranges of one memory object rejected"
        )
        let overlapping1 = resources(
            targetID: 7,
            resourceNamespace: 40,
            resourceValue: 403,
            memory: memoryBinding(object: sharedObject, offset: 2_048, count: 4_096)
        )
        expect(
            GPUTripleBufferFrameScheduler(
                renderQueue: queue(1),
                presentationQueue: queue(2),
                slot0: shared0,
                slot1: overlapping1,
                slot2: shared2
            ) == nil,
            "overlapping slot memory accepted"
        )
    }

    private static func ordersAndCoalescesFrameRequests() {
        var scheduler = requireScheduler()
        expect(
            scheduler.requestFrame(request(id: 1, revision: 100)) == .queued,
            "first request not queued"
        )
        expect(
            scheduler.requestFrame(request(id: 1, revision: 101))
                == .rejected(.requestIDNotIncreasing),
            "duplicate request ID accepted"
        )
        expect(
            scheduler.requestFrame(request(id: 2, revision: 102))
                == .coalesced(replacedRequestID: 1),
            "newest pending request not coalesced"
        )
        let lease = requireAcquired(scheduler.acquireNextFrame())
        expect(lease.identity.frameID == 1, "first frame ID")
        expect(lease.identity.request.requestID == 2, "stale request rendered")
        expect(lease.identity.request.sceneRevision == 102, "scene revision lost")
        expect(lease.slot == .first, "first round-robin slot")
        expect(scheduler.acquireNextFrame() == .noPendingRequest, "phantom request")
        expect(scheduler.statistics.acceptedRequestCount == 2, "accepted request count")
        expect(scheduler.statistics.rejectedRequestCount == 1, "rejected request count")
        expect(scheduler.statistics.coalescedRequestCount == 1, "coalesced count")
        expect(scheduler.statistics.droppedRequestCount == 1, "coalesced drop count")
    }

    private static func pipelinesThreeFramesWithoutEarlyReuse() {
        var scheduler = requireScheduler()
        let first = requestAndAcquire(&scheduler, requestID: 1)
        let second = requestAndAcquire(&scheduler, requestID: 2)
        let third = requestAndAcquire(&scheduler, requestID: 3)
        expect(first.slot == .first, "first slot order")
        expect(second.slot == .second, "second slot order")
        expect(third.slot == .third, "third slot order")
        expect(scheduler.availableSlotCount == 0, "triple buffer not saturated")

        expect(scheduler.requestFrame(request(id: 4, revision: 4)) == .queued, "busy request queue")
        expect(scheduler.acquireNextFrame() == .busy, "busy acquire succeeded")
        expect(scheduler.statistics.busyAcquireCount == 1, "busy count")
        expect(
            scheduler.requestFrame(request(id: 5, revision: 5))
                == .coalesced(replacedRequestID: 4),
            "busy request did not coalesce"
        )

        expect(
            scheduler.submit(second, signaling: fence(queueID: 1, value: 1))
                == .rejected(.frameOrderViolation),
            "out-of-order frame submitted"
        )
        expect(
            scheduler.submit(first, signaling: fence(queueID: 1, value: 10))
                == .transitioned,
            "first submit"
        )
        expect(
            scheduler.submit(second, signaling: fence(queueID: 1, value: 9))
                == .rejected(.fenceNotIncreasing),
            "regressing render fence accepted"
        )
        expect(
            scheduler.submit(second, signaling: fence(queueID: 1, value: 11))
                == .transitioned,
            "second submit"
        )
        expect(
            scheduler.submit(third, signaling: fence(queueID: 1, value: 12))
                == .transitioned,
            "third submit"
        )
        expect(
            scheduler.beginPresentation(
                second,
                signaling: fence(queueID: 2, value: 21)
            ) == .rejected(.frameOrderViolation),
            "out-of-order presentation accepted"
        )
        expect(
            scheduler.beginPresentation(
                first,
                signaling: fence(queueID: 2, value: 20)
            ) == .transitioned,
            "first presentation"
        )
        expect(
            scheduler.beginPresentation(
                second,
                signaling: fence(queueID: 2, value: 21)
            ) == .transitioned,
            "second presentation"
        )
        expect(
            scheduler.beginPresentation(
                third,
                signaling: fence(queueID: 2, value: 22)
            ) == .transitioned,
            "third presentation"
        )

        let renderCompletion = frameFence(
            epoch: 1,
            queueID: 1,
            value: 12
        )
        expectAdvanced(
            scheduler.completeFence(renderCompletion),
            retiredCount: 0,
            "render completion retired scanout"
        )
        expect(scheduler.availableSlotCount == 0, "render completion reused slot")
        expect(scheduler.acquireNextFrame() == .busy, "render-only completion acquired")

        expectAdvanced(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 19)),
            retiredCount: 0,
            "pre-presentation completion"
        )
        expect(scheduler.availableSlotCount == 0, "early present completion reused slot")
        let firstRetirement = requireAdvanced(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 20))
        )
        expect(firstRetirement.count == 1, "first retirement count")
        expect(
            firstRetirement.retirement(at: 0)?.identity == first.identity,
            "first retirement identity"
        )
        expect(scheduler.availableSlotCount == 1, "completed present not released")

        let fourth = requireAcquired(scheduler.acquireNextFrame())
        expect(fourth.identity.request.requestID == 5, "coalesced busy request lost")
        expect(fourth.slot == .first, "retired slot not reused")
        expect(fourth.identity.frameID == 4, "frame ID did not increase")
        expect(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 20))
                == .unchanged,
            "duplicate completion advanced"
        )
        expect(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 19))
                == .rejected(.fenceRegressed),
            "regressing completion accepted"
        )
        expect(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 23))
                == .rejected(.fenceBeyondSubmittedWork),
            "completion beyond submitted work accepted"
        )
        let remaining = requireAdvanced(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 22))
        )
        expect(remaining.count == 2, "jump completion retirement count")
        expect(remaining.retirement(at: -1) == nil, "negative retirement index")
        expect(remaining.retirement(at: 2) == nil, "past-end retirement index")
        expect(scheduler.availableSlotCount == 2, "remaining slots not released")
        expect(scheduler.statistics.retiredFrameCount == 3, "retired statistics")
    }

    private static func sharesOneQueueTimelineSafely() {
        var scheduler = requireScheduler(renderQueueID: 7, presentationQueueID: 7)
        let lease = requestAndAcquire(&scheduler, requestID: 1)
        expect(
            scheduler.submit(lease, signaling: fence(queueID: 7, value: 1))
                == .transitioned,
            "shared queue render submit"
        )
        expect(
            scheduler.beginPresentation(
                lease,
                signaling: fence(queueID: 7, value: 1)
            ) == .rejected(.fenceNotIncreasing),
            "shared queue reused render fence"
        )
        expect(
            scheduler.beginPresentation(
                lease,
                signaling: fence(queueID: 7, value: 2)
            ) == .transitioned,
            "shared queue presentation submit"
        )
        expectAdvanced(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 7, value: 1)),
            retiredCount: 0,
            "render point retired shared-queue image"
        )
        expect(scheduler.availableSlotCount == 2, "shared queue early reuse")
        expectAdvanced(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 7, value: 2)),
            retiredCount: 1,
            "shared queue present completion"
        )
        expect(scheduler.availableSlotCount == 3, "shared queue retirement")
    }

    private static func ordersRetirementsByFrameIDAfterSlotReuse() {
        var scheduler = requireScheduler()
        let first = requestAndAcquire(&scheduler, requestID: 1)
        let second = requestAndAcquire(&scheduler, requestID: 2)
        let third = requestAndAcquire(&scheduler, requestID: 3)

        expect(
            scheduler.submit(first, signaling: fence(queueID: 1, value: 1))
                == .transitioned,
            "reuse-order first submit"
        )
        expect(
            scheduler.submit(second, signaling: fence(queueID: 1, value: 2))
                == .transitioned,
            "reuse-order second submit"
        )
        expect(
            scheduler.submit(third, signaling: fence(queueID: 1, value: 3))
                == .transitioned,
            "reuse-order third submit"
        )
        expect(
            scheduler.beginPresentation(
                first,
                signaling: fence(queueID: 2, value: 1)
            ) == .transitioned,
            "reuse-order first present"
        )
        expect(
            scheduler.beginPresentation(
                second,
                signaling: fence(queueID: 2, value: 2)
            ) == .transitioned,
            "reuse-order second present"
        )
        expect(
            scheduler.beginPresentation(
                third,
                signaling: fence(queueID: 2, value: 3)
            ) == .transitioned,
            "reuse-order third present"
        )
        expectAdvanced(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 1)),
            retiredCount: 1,
            "reuse-order first completion"
        )

        let fourth = requestAndAcquire(&scheduler, requestID: 4)
        expect(fourth.slot == .first, "slot zero was not reused")
        expect(
            scheduler.submit(fourth, signaling: fence(queueID: 1, value: 4))
                == .transitioned,
            "reuse-order fourth submit"
        )
        expect(
            scheduler.beginPresentation(
                fourth,
                signaling: fence(queueID: 2, value: 4)
            ) == .transitioned,
            "reuse-order fourth present"
        )

        let retired = requireAdvanced(
            scheduler.completeFence(frameFence(epoch: 1, queueID: 2, value: 4))
        )
        expect(retired.count == 3, "slot-reuse retirement count")
        expect(
            retired.retirement(at: 0)?.identity.frameID == 2,
            "retirement batch exposed slot order at index zero"
        )
        expect(
            retired.retirement(at: 1)?.identity.frameID == 3,
            "retirement batch frame order at index one"
        )
        expect(
            retired.retirement(at: 2)?.identity.frameID == 4,
            "retirement batch frame order at index two"
        )
        expect(
            retired.retirement(at: 2)?.slot == .first,
            "newest reused slot identity lost"
        )
    }

    private static func abandonsOnlyCPUOwnedFrames() {
        var scheduler = requireScheduler()
        let abandoned = requestAndAcquire(&scheduler, requestID: 1)
        expect(scheduler.abandon(abandoned) == .transitioned, "acquired abandon")
        expect(scheduler.availableSlotCount == 3, "abandon did not release")
        expect(
            scheduler.abandon(abandoned) == .rejected(.leaseMismatch),
            "abandoned lease reused"
        )

        let submitted = requestAndAcquire(&scheduler, requestID: 2)
        expect(
            scheduler.submit(submitted, signaling: fence(queueID: 1, value: 1))
                == .transitioned,
            "submit before abandon test"
        )
        expect(
            scheduler.abandon(submitted) == .rejected(.invalidSlotState),
            "submitted image abandoned"
        )
        expect(scheduler.availableSlotCount == 2, "submitted slot released")
        expect(scheduler.statistics.abandonedFrameCount == 1, "abandon count")
    }

    private static func quarantinesSlotsAcrossFailureAndReset() {
        var scheduler = requireScheduler()
        let oldLease = requestAndAcquire(&scheduler, requestID: 1)
        expect(
            scheduler.submit(oldLease, signaling: fence(queueID: 1, value: 1))
                == .transitioned,
            "old submit"
        )
        expect(
            scheduler.beginPresentation(
                oldLease,
                signaling: fence(queueID: 2, value: 1)
            ) == .transitioned,
            "old presentation"
        )
        let oldCompletion = frameFence(epoch: 1, queueID: 2, value: 1)
        expect(
            scheduler.requestFrame(request(id: 2, revision: 2)) == .queued,
            "pending before failure"
        )
        expect(scheduler.fail(.deviceLost) == .enteredFailedState, "failure transition")
        expect(scheduler.fail(.timedOut) == .alreadyFailed, "double failure")
        expect(scheduler.availableSlotCount == 2, "failure released in-flight slot")
        expect(
            scheduler.requestFrame(request(id: 3, revision: 3))
                == .rejected(.schedulerFailed(.deviceLost)),
            "request accepted while failed"
        )
        expect(scheduler.acquireNextFrame() == .failed(.deviceLost), "acquire while failed")
        expect(
            scheduler.completeFence(oldCompletion)
                == .rejected(.schedulerFailed(.deviceLost)),
            "completion accepted while failed"
        )
        expect(
            scheduler.abandon(oldLease)
                == .rejected(.schedulerFailed(.deviceLost)),
            "lease transition accepted while failed"
        )

        expect(scheduler.resetAfterDeviceQuiescence() == .reset(epoch: 2), "quiescent reset")
        expect(scheduler.currentEpoch == 2, "reset epoch")
        expect(scheduler.availableSlotCount == 3, "reset did not release slots")
        expect(scheduler.pendingRequest == nil, "reset retained pending request")
        expect(scheduler.statistics.droppedRequestCount == 1, "reset pending drop")
        expect(
            scheduler.resetAfterDeviceQuiescence()
                == .rejected(.schedulerNotFailed),
            "healthy reset accepted"
        )
        expect(
            scheduler.submit(oldLease, signaling: fence(queueID: 1, value: 2))
                == .rejected(.staleEpoch),
            "pre-reset lease accepted"
        )

        let newLease = requestAndAcquire(&scheduler, requestID: 4)
        expect(newLease.identity.epoch == 2, "new lease epoch")
        expect(newLease.identity.frameID == 2, "frame ID regressed across reset")
        expect(
            scheduler.submit(newLease, signaling: fence(queueID: 1, value: 1))
                == .transitioned,
            "reset render fence namespace"
        )
        expect(
            scheduler.beginPresentation(
                newLease,
                signaling: fence(queueID: 2, value: 1)
            ) == .transitioned,
            "reset present fence namespace"
        )
        expect(
            scheduler.completeFence(oldCompletion) == .rejected(.staleEpoch),
            "stale completion retired new frame"
        )
        expectAdvanced(
            scheduler.completeFence(frameFence(epoch: 2, queueID: 2, value: 1)),
            retiredCount: 1,
            "post-reset completion"
        )
        expect(scheduler.statistics.failureCount == 1, "failure count")
        expect(scheduler.statistics.resetCount == 1, "reset count")
    }

    private static func preservesValueSemantics() {
        var original = requireScheduler()
        var copy = original
        let lease = requestAndAcquire(&copy, requestID: 1)
        expect(copy.availableSlotCount == 2, "copy acquire")
        expect(original.availableSlotCount == 3, "scheduler storage aliased")
        expect(original.pendingRequest == nil, "request storage aliased")
        expect(copy.snapshot(for: lease.slot).state == .acquired(lease.identity), "copy state")
        expect(original.snapshot(for: lease.slot).state == .available, "original state")

        expect(original.requestFrame(request(id: 9, revision: 9)) == .queued, "original mutation")
        expect(copy.pendingRequest == nil, "reverse request alias")
    }

    private static func requireScheduler(
        renderQueueID: UInt16 = 1,
        presentationQueueID: UInt16 = 2,
        slot0: GPUFrameSlotResources? = nil,
        slot1: GPUFrameSlotResources? = nil,
        slot2: GPUFrameSlotResources? = nil
    ) -> GPUTripleBufferFrameScheduler {
        let first = slot0 ?? resources(
            targetID: 1,
            resourceNamespace: 1,
            resourceValue: 1,
            memoryNamespace: 1,
            memoryValue: 1,
            offset: 0
        )
        let second = slot1 ?? resources(
            targetID: 2,
            resourceNamespace: 1,
            resourceValue: 2,
            memoryNamespace: 1,
            memoryValue: 2,
            offset: 0
        )
        let third = slot2 ?? resources(
            targetID: 3,
            resourceNamespace: 1,
            resourceValue: 3,
            memoryNamespace: 1,
            memoryValue: 3,
            offset: 0
        )
        guard let scheduler = GPUTripleBufferFrameScheduler(
            renderQueue: queue(renderQueueID),
            presentationQueue: queue(presentationQueueID),
            slot0: first,
            slot1: second,
            slot2: third
        ) else {
            fatalError("invalid test scheduler")
        }
        return scheduler
    }

    private static func requestAndAcquire(
        _ scheduler: inout GPUTripleBufferFrameScheduler,
        requestID: UInt64
    ) -> GPUFrameLease {
        expect(
            scheduler.requestFrame(request(id: requestID, revision: requestID)) == .queued,
            "request-and-acquire queue"
        )
        return requireAcquired(scheduler.acquireNextFrame())
    }

    private static func resources(
        targetID: UInt32,
        resourceNamespace: UInt32,
        resourceValue: UInt64,
        memoryNamespace: UInt32,
        memoryValue: UInt64,
        offset: UInt64
    ) -> GPUFrameSlotResources {
        resources(
            targetID: targetID,
            resourceNamespace: resourceNamespace,
            resourceValue: resourceValue,
            memory: memoryBinding(
                object: memoryObject(namespaceID: memoryNamespace, value: memoryValue),
                offset: offset,
                count: 4_096
            )
        )
    }

    private static func resources(
        targetID: UInt32,
        resourceNamespace: UInt32,
        resourceValue: UInt64,
        memory: GPUMemoryBinding
    ) -> GPUFrameSlotResources {
        GPUFrameSlotResources(
            renderTarget: target(targetID),
            image: resource(namespaceID: resourceNamespace, value: resourceValue),
            memory: memory
        )
    }

    private static func namespace(_ value: UInt32) -> GPUHandleNamespace {
        guard let result = GPUHandleNamespace(rawValue: value) else {
            fatalError("invalid test namespace")
        }
        return result
    }

    private static func resource(
        namespaceID: UInt32,
        value: UInt64
    ) -> GPUResourceHandle {
        guard let result = GPUResourceHandle(
            namespace: namespace(namespaceID),
            value: value
        ) else {
            fatalError("invalid test resource")
        }
        return result
    }

    private static func memoryObject(
        namespaceID: UInt32,
        value: UInt64
    ) -> GPUMemoryObjectHandle {
        guard let result = GPUMemoryObjectHandle(
            namespace: namespace(namespaceID),
            value: value
        ) else {
            fatalError("invalid test memory object")
        }
        return result
    }

    private static func memoryBinding(
        object: GPUMemoryObjectHandle,
        offset: UInt64,
        count: UInt64
    ) -> GPUMemoryBinding {
        guard let result = GPUMemoryBinding(
            object: object,
            byteOffset: offset,
            byteCount: count
        ) else {
            fatalError("invalid test memory binding")
        }
        return result
    }

    private static func target(_ value: UInt32) -> GPURenderTargetID {
        guard let result = GPURenderTargetID(rawValue: value) else {
            fatalError("invalid test target")
        }
        return result
    }

    private static func queue(_ value: UInt16) -> GPUQueueID {
        guard let result = GPUQueueID(rawValue: value) else {
            fatalError("invalid test queue")
        }
        return result
    }

    private static func fence(queueID: UInt16, value: UInt64) -> GPUFencePoint {
        guard let result = GPUFencePoint(queue: queue(queueID), value: value) else {
            fatalError("invalid test fence")
        }
        return result
    }

    private static func frameFence(
        epoch: UInt64,
        queueID: UInt16,
        value: UInt64
    ) -> GPUFrameFence {
        guard let result = GPUFrameFence(
            epoch: epoch,
            point: fence(queueID: queueID, value: value)
        ) else {
            fatalError("invalid test frame fence")
        }
        return result
    }

    private static func request(id: UInt64, revision: UInt64) -> GPUFrameRequest {
        guard let result = GPUFrameRequest(requestID: id, sceneRevision: revision) else {
            fatalError("invalid test frame request")
        }
        return result
    }

    private static func requireAcquired(
        _ result: GPUFrameAcquireResult
    ) -> GPUFrameLease {
        guard case .acquired(let lease) = result else {
            fatalError("expected acquired frame, got \(result)")
        }
        return lease
    }

    private static func requireAdvanced(
        _ result: GPUFenceCompletionResult
    ) -> GPUFrameRetirementBatch {
        guard case .advanced(let batch) = result else {
            fatalError("expected advanced fence, got \(result)")
        }
        return batch
    }

    private static func expectAdvanced(
        _ result: GPUFenceCompletionResult,
        retiredCount: Int,
        _ message: String
    ) {
        guard case .advanced(let batch) = result, batch.count == retiredCount else {
            fatalError("\(message): \(result)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
