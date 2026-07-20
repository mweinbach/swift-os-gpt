@main
struct RunQueueTests {
    static func main() {
        rotatesThreadsAndPreservesProcessIdentity()
        observesAffinityAcrossFourProcessors()
        blocksWakesAndExitsThreads()
        rejectsInvalidThreadsAndCapacityOverflow()
        print("run queue host tests: 4 passed")
    }

    private static func rotatesThreadsAndPreservesProcessIdentity() {
        withQueue(threadCapacity: 4, processorCount: 1) { queue in
            expect(queue.add(identifier: 1, processIdentifier: 7,
                             affinityMask: 1, contextAddress: 0x1000),
                   "thread 1 was rejected")
            expect(queue.add(identifier: 2, processIdentifier: 7,
                             affinityMask: 1, contextAddress: 0x2000),
                   "thread 2 was rejected")
            expect(queue.begin(on: 0)?.nextThreadIdentifier == 1,
                   "first thread did not start")
            let second = queue.preempt(on: 0)
            expect(second == SchedulingDecision(
                previousThreadIdentifier: 1,
                nextThreadIdentifier: 2,
                nextContextAddress: 0x2000
            ), "timer rotation did not select thread 2")
            expect(queue.preempt(on: 0)?.nextThreadIdentifier == 1,
                   "round robin did not wrap")
            expect(queue.thread(identifier: 2)?.processIdentifier == 7,
                   "process identity changed")
        }
    }

    private static func observesAffinityAcrossFourProcessors() {
        withQueue(threadCapacity: 6, processorCount: 4) { queue in
            expect(queue.add(identifier: 10, processIdentifier: 1,
                             affinityMask: 0b0001, contextAddress: 0x1000), "add")
            expect(queue.add(identifier: 11, processIdentifier: 1,
                             affinityMask: 0b0010, contextAddress: 0x2000), "add")
            expect(queue.add(identifier: 12, processIdentifier: 1,
                             affinityMask: 0b1100, contextAddress: 0x3000), "add")
            expect(queue.begin(on: 1)?.nextThreadIdentifier == 11,
                   "CPU 1 selected an ineligible thread")
            expect(queue.begin(on: 0)?.nextThreadIdentifier == 10,
                   "CPU 0 selected an ineligible thread")
            expect(queue.begin(on: 2)?.nextThreadIdentifier == 12,
                   "CPU 2 did not select shared-affinity thread")
            expect(queue.begin(on: 3) == nil,
                   "one thread ran on two processors")
            expect(queue.relinquishCurrent(on: 2),
                   "CPU 2 did not relinquish its thread")
            expect(queue.currentThread(on: 2) == nil,
                   "relinquished CPU retained an owner")
            expect(queue.thread(identifier: 12)?.state == .ready,
                   "relinquished thread did not become ready")
            expect(queue.begin(on: 3)?.nextThreadIdentifier == 12,
                   "another CPU could not acquire relinquished work")
            expect(!queue.relinquishCurrent(on: 2),
                   "ownerless CPU relinquished twice")
        }
    }

    private static func blocksWakesAndExitsThreads() {
        withQueue(threadCapacity: 3, processorCount: 1) { queue in
            expect(queue.add(identifier: 1, processIdentifier: 1,
                             affinityMask: 1, contextAddress: 0x1000), "add")
            expect(queue.add(identifier: 2, processIdentifier: 1,
                             affinityMask: 1, contextAddress: 0x2000), "add")
            _ = queue.begin(on: 0)
            expect(queue.blockCurrent(on: 0)?.nextThreadIdentifier == 2,
                   "blocking did not hand off")
            expect(queue.wake(identifier: 1), "blocked thread did not wake")
            expect(queue.preempt(on: 0)?.nextThreadIdentifier == 1,
                   "woken thread did not reenter rotation")
            expect(queue.exitCurrent(on: 0)?.nextThreadIdentifier == 2,
                   "exiting did not hand off")
            expect(queue.thread(identifier: 1)?.state == .exited,
                   "thread was not marked exited")
        }
    }

    private static func rejectsInvalidThreadsAndCapacityOverflow() {
        withQueue(threadCapacity: 1, processorCount: 1) { queue in
            expect(!queue.add(identifier: 0, processIdentifier: 1,
                              affinityMask: 1, contextAddress: 0x1000),
                   "zero identifier was accepted")
            expect(!queue.add(identifier: 1, processIdentifier: 1,
                              affinityMask: 2, contextAddress: 0x1000),
                   "unusable affinity was accepted")
            expect(!queue.add(identifier: 1, processIdentifier: 1,
                              affinityMask: 1, contextAddress: 0x1001),
                   "misaligned context was accepted")
            expect(queue.add(identifier: 1, processIdentifier: 1,
                             affinityMask: 1, contextAddress: 0x1000), "add")
            expect(!queue.add(identifier: 2, processIdentifier: 1,
                              affinityMask: 1, contextAddress: 0x2000),
                   "capacity overflow was accepted")
        }
    }
}

private func withQueue(
    threadCapacity: Int,
    processorCount: Int,
    body: (inout RunQueue) -> Void
) {
    let threads = UnsafeMutableBufferPointer<ScheduledThread>.allocate(
        capacity: threadCapacity
    )
    let processors = UnsafeMutableBufferPointer<Int32>.allocate(
        capacity: processorCount
    )
    defer {
        threads.deallocate()
        processors.deallocate()
    }
    var queue = RunQueue(
        threadStorage: threads,
        currentIndexStorage: processors,
        processorCount: processorCount
    )!
    body(&queue)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
