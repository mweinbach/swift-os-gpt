@main
struct SecondaryProcessorWorkSchedulerTests {
    static func main() {
        buildsTwoDistinctAffinityPinnedTasksPerSecondary()
        executesMultipleBoundedQuantaAndDrainsEachCPU()
        rejectsCrossCPUCompletionClaims()
        validatesUniqueSecondaryStackOwnership()
        rejectsInvalidExecutorAndSchedulerConfiguration()
        boundsEvidenceWaitByCounterTimeAndDefensivePolls()
        print("Secondary processor work scheduler host tests: 6 passed")
    }

    private static func buildsTwoDistinctAffinityPinnedTasksPerSecondary() {
        withScheduler(processorCount: 4) { scheduler in
            expect(scheduler.taskCount == 6, "four-core task count")
            var priorIdentifier: UInt32 = 0
            var cpu = 1
            while cpu < 4 {
                let first = scheduler.context(
                    logicalProcessorID: cpu,
                    slot: 0
                )
                let second = scheduler.context(
                    logicalProcessorID: cpu,
                    slot: 1
                )
                expect(first?.logicalProcessorID == UInt32(cpu),
                       "first context CPU ownership")
                expect(second?.logicalProcessorID == UInt32(cpu),
                       "second context CPU ownership")
                expect(first?.taskIdentifier != second?.taskIdentifier,
                       "per-CPU task identifiers aliased")
                expect((first?.taskIdentifier ?? 0) > priorIdentifier,
                       "task identifiers are not deterministic")
                expect(first?.expectedChecksum != 0,
                       "first expected checksum")
                expect(second?.expectedChecksum != 0,
                       "second expected checksum")
                priorIdentifier = second?.taskIdentifier ?? 0
                cpu += 1
            }
        }
    }

    private static func executesMultipleBoundedQuantaAndDrainsEachCPU() {
        withScheduler(processorCount: 4) { scheduler in
            var cpu = 1
            while cpu < 4 {
                guard var lease = scheduler.begin(on: cpu) else {
                    fatalError("missing first CPU lease")
                }
                var slot = 0
                while slot < 2 {
                    guard let context = scheduler.context(for: lease),
                          var executor = SecondaryProcessorWorkExecutor(
                              context: context
                          )
                    else {
                        fatalError("invalid work context")
                    }
                    var completion: SecondaryProcessorWorkQuantum = .progressed
                    while !executor.isComplete {
                        completion = executor.executeQuantum(
                            iterationBudget: 64
                        )
                    }
                    expect(
                        completion
                            == .completed(
                                checksum: context.expectedChecksum
                            ),
                        "deterministic checksum mismatch"
                    )
                    expect(executor.quantumCount > 1,
                           "task did not consume multiple quanta")

                    switch scheduler.complete(lease, on: cpu) {
                    case let .next(next):
                        expect(slot == 0, "extra next lease")
                        expect(next.taskIdentifier != lease.taskIdentifier,
                               "scheduler repeated one work slot")
                        lease = next
                    case .drained:
                        expect(slot == 1, "queue drained before second slot")
                    case .rejected:
                        fatalError("valid completion rejected")
                    }
                    slot += 1
                }
                cpu += 1
            }
        }
    }

    private static func rejectsCrossCPUCompletionClaims() {
        withScheduler(processorCount: 3) { scheduler in
            guard let cpuOne = scheduler.begin(on: 1),
                  let cpuTwo = scheduler.begin(on: 2)
            else {
                fatalError("missing cross-CPU leases")
            }
            expect(scheduler.complete(cpuOne, on: 2) == .rejected,
                   "CPU2 claimed CPU1 evidence")
            expect(scheduler.complete(cpuTwo, on: 1) == .rejected,
                   "CPU1 claimed CPU2 evidence")
            expect(scheduler.complete(cpuOne, on: 1) != .rejected,
                   "CPU1 lost its lease after rejected claim")
            expect(scheduler.complete(cpuTwo, on: 2) != .rejected,
                   "CPU2 lost its lease after rejected claim")
        }
    }

    private static func validatesUniqueSecondaryStackOwnership() {
        let start: UInt64 = 0x1000_0000
        let stackSize: UInt64 = 64 * 1_024
        let end = start + stackSize * 3
        expect(SecondaryProcessorStackOwnership.owns(
            stackPointer: start + stackSize,
            logicalProcessorID: 1,
            secondaryStackStart: start,
            secondaryStackEnd: end
        ), "CPU1 stack top")
        expect(SecondaryProcessorStackOwnership.owns(
            stackPointer: start + stackSize + 0x1000,
            logicalProcessorID: 2,
            secondaryStackStart: start,
            secondaryStackEnd: end
        ), "CPU2 stack body")
        expect(!SecondaryProcessorStackOwnership.owns(
            stackPointer: start + stackSize,
            logicalProcessorID: 2,
            secondaryStackStart: start,
            secondaryStackEnd: end
        ), "CPU2 claimed CPU1 stack")
        expect(!SecondaryProcessorStackOwnership.owns(
            stackPointer: start + stackSize + 1,
            logicalProcessorID: 2,
            secondaryStackStart: start,
            secondaryStackEnd: end
        ), "misaligned stack pointer")
    }

    private static func rejectsInvalidExecutorAndSchedulerConfiguration() {
        expect(SecondaryProcessorWorkExecutor(context: .vacant) == nil,
               "vacant executor")
        let context = SecondaryProcessorWorkContext(
            taskIdentifier: 1,
            logicalProcessorID: 1,
            iterationCount: 1,
            seed: 1,
            expectedChecksum: 0
        )
        var executor = SecondaryProcessorWorkExecutor(context: context)!
        expect(executor.executeQuantum(iterationBudget: 0) == .invalidBudget,
               "zero quantum budget")

        let threads = UnsafeMutableBufferPointer<ScheduledThread>.allocate(
            capacity: 2
        )
        let indices = UnsafeMutableBufferPointer<Int32>.allocate(capacity: 4)
        let contexts = UnsafeMutableBufferPointer<SecondaryProcessorWorkContext>
            .allocate(capacity: 2)
        defer {
            threads.deallocate()
            indices.deallocate()
            contexts.deallocate()
        }
        expect(SecondaryProcessorWorkScheduler(
            threadStorage: threads,
            currentIndexStorage: indices,
            contextStorage: contexts,
            processorCount: 1
        ) == nil, "single-CPU work scheduler")
        expect(SecondaryProcessorWorkScheduler(
            threadStorage: threads,
            currentIndexStorage: indices,
            contextStorage: contexts,
            processorCount: 4
        ) == nil, "undersized task storage")
    }

    private static func boundsEvidenceWaitByCounterTimeAndDefensivePolls() {
        expect(SecondaryProcessorWorkWaitPolicy(
            startedAtTicks: 0,
            timeoutTicks: 0,
            maximumPollCount: 1
        ) == nil, "zero evidence timeout")
        expect(SecondaryProcessorWorkWaitPolicy(
            startedAtTicks: 0,
            timeoutTicks: 1,
            maximumPollCount: 0
        ) == nil, "zero evidence poll bound")

        var wrapping = SecondaryProcessorWorkWaitPolicy(
            startedAtTicks: UInt64.max - 5,
            timeoutTicks: 10,
            maximumPollCount: 8
        )!
        expect(
            wrapping.permitAnotherPoll(counterTick: 2),
            "wrapping counter elapsed too early"
        )
        expect(
            !wrapping.permitAnotherPoll(counterTick: 4),
            "wrapping counter exceeded its deadline"
        )

        var bounded = SecondaryProcessorWorkWaitPolicy(
            startedAtTicks: 100,
            timeoutTicks: 1_000,
            maximumPollCount: 2
        )!
        expect(bounded.permitAnotherPoll(counterTick: 100), "first poll")
        expect(bounded.permitAnotherPoll(counterTick: 100), "second poll")
        expect(
            !bounded.permitAnotherPoll(counterTick: 100),
            "stopped counter bypassed the defensive poll bound"
        )
    }
}

private func withScheduler(
    processorCount: Int,
    body: (inout SecondaryProcessorWorkScheduler) -> Void
) {
    let taskCount = (processorCount - 1)
        * SecondaryProcessorWorkScheduler.tasksPerSecondaryProcessor
    let threads = UnsafeMutableBufferPointer<ScheduledThread>.allocate(
        capacity: taskCount
    )
    let indices = UnsafeMutableBufferPointer<Int32>.allocate(
        capacity: processorCount
    )
    let contexts = UnsafeMutableBufferPointer<SecondaryProcessorWorkContext>
        .allocate(capacity: taskCount)
    defer {
        threads.deallocate()
        indices.deallocate()
        contexts.deallocate()
    }
    guard var scheduler = SecondaryProcessorWorkScheduler(
              threadStorage: threads,
              currentIndexStorage: indices,
              contextStorage: contexts,
              processorCount: processorCount
          )
    else {
        fatalError("valid scheduler configuration rejected")
    }
    body(&scheduler)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
