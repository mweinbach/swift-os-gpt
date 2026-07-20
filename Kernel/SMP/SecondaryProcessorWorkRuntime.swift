enum SecondaryProcessorWorkState: UInt64, Equatable {
    case absent = 0
    case prepared = 1
    case currentProcessorInitializationFailed = 2
    case running = 3
    case completed = 4
    case schedulingFailed = 5
    case clockFailed = 6
    case restartInterrupted = 7
}

struct SecondaryProcessorWorkResult: Equatable {
    let taskIdentifier: UInt32
    let reserved: UInt32
    let checksum: UInt64
    let quantumCount: UInt64

    static let vacant = SecondaryProcessorWorkResult(
        taskIdentifier: 0,
        reserved: 0,
        checksum: 0,
        quantumCount: 0
    )
}

struct SecondaryProcessorWorkEvidence: Equatable {
    let logicalProcessorID: UInt32
    let first: SecondaryProcessorWorkResult
    let second: SecondaryProcessorWorkResult
    let observedStackPointer: UInt64
}

enum SecondaryProcessorWorkEvidenceResult: Equatable {
    case complete(SecondaryProcessorWorkEvidence)
    case failed(SecondaryProcessorWorkState)
    case timedOut
    case invalidContext
}

enum SecondaryProcessorWorkRunResult: Equatable {
    case completed
    case invalidContext
    case schedulingFailed
    case clockFailed
    case restartInterrupted
}

private enum SecondaryProcessorQuantumTickResult: Equatable {
    case tick
    case clockFailed
    case restartInterrupted
}

/// Counter-backed cooperative tick source. It is intentionally outside the
/// scheduler model so a per-CPU timer interrupt can replace it without changing
/// leases, contexts, or execution quanta.
private struct SecondaryProcessorCounterTickSource {
    private static let ticksPerSecondDivisor: UInt64 = 100_000
    private static let pollLimit: UInt64 = 1_000_000

    let periodTicks: UInt64

    init?() {
        let frequency = AArch64.counterFrequency
        guard frequency > 0 else { return nil }
        let divided = frequency / Self.ticksPerSecondDivisor
        periodTicks = divided > 0 ? divided : 1
    }

    mutating func awaitTick(
        logicalProcessorID: UInt64,
        observedRestartEpoch: inout UInt64
    ) -> SecondaryProcessorQuantumTickResult {
        let start = AArch64.counterValue
        var pollCount: UInt64 = 0
        while true {
            switch SMPKernelRestartRendezvous.checkpoint(
                logicalProcessorID: logicalProcessorID,
                observedEpoch: &observedRestartEpoch
            ) {
            case .idle:
                break
            case .invalidContext, .shutdownReturned:
                return .restartInterrupted
            }
            if AArch64.counterValue &- start >= periodTicks {
                return .tick
            }
            pollCount &+= 1
            if pollCount >= Self.pollLimit { return .clockFailed }
            AArch64.spinHint()
        }
    }
}

/// Shared kernel-work runtime. CPU0 builds and release-publishes every pointer
/// before CPU_ON. Secondaries acquire that publication before local controller
/// setup, serialize only run-queue transitions, execute leases independently,
/// and release-publish completion after all evidence fields are populated.
enum SecondaryProcessorWorkRuntime {
    private static let threadCapacity =
        SecondaryProcessorWorkScheduler.maximumTaskCount
    private static let indexCapacity =
        ProcessorStartupPlan.maximumOnlineProcessorCount
    private static let contextCapacity =
        SecondaryProcessorWorkScheduler.maximumTaskCount
    private static let resultCapacity =
        SecondaryProcessorWorkScheduler.maximumTaskCount
    private static let stateCapacity =
        ProcessorStartupPlan.maximumOnlineProcessorCount
    private static let stackCapacity =
        ProcessorStartupPlan.maximumOnlineProcessorCount
    private static let iterationBudgetPerQuantum: UInt64 = 64

    private nonisolated(unsafe) static var scheduler:
        SecondaryProcessorWorkScheduler?
    private nonisolated(unsafe) static var resultStorage:
        UnsafeMutableBufferPointer<SecondaryProcessorWorkResult>?
    private nonisolated(unsafe) static var stateStorage:
        UnsafeMutableBufferPointer<UInt64>?
    private nonisolated(unsafe) static var stackStorage:
        UnsafeMutableBufferPointer<UInt64>?
    private nonisolated(unsafe) static var schedulerLock: UInt32 = 0
    private nonisolated(unsafe) static var publishedProcessorCount: UInt64 = 0

    static func configure(processorCount: Int) -> Bool {
        guard processorCount > 1,
              processorCount
                <= ProcessorStartupPlan.maximumOnlineProcessorCount,
              let threads: UnsafeMutableBufferPointer<ScheduledThread> = buffer(
                  at: KernelLinkerLayout.smpWorkThreadStorage,
                  count: threadCapacity
              ),
              let indices: UnsafeMutableBufferPointer<Int32> = buffer(
                  at: KernelLinkerLayout.smpWorkIndexStorage,
                  count: indexCapacity
              ),
              let contexts:
                UnsafeMutableBufferPointer<SecondaryProcessorWorkContext> = buffer(
                  at: KernelLinkerLayout.smpWorkContextStorage,
                  count: contextCapacity
              ),
              let results:
                UnsafeMutableBufferPointer<SecondaryProcessorWorkResult> = buffer(
                  at: KernelLinkerLayout.smpWorkResultStorage,
                  count: resultCapacity
              ),
              let states: UnsafeMutableBufferPointer<UInt64> = buffer(
                  at: KernelLinkerLayout.smpWorkStateStorage,
                  count: stateCapacity
              ),
              let stacks: UnsafeMutableBufferPointer<UInt64> = buffer(
                  at: KernelLinkerLayout.smpWorkStackStorage,
                  count: stackCapacity
              ),
              let active = SecondaryProcessorWorkScheduler(
                  threadStorage: threads,
                  currentIndexStorage: indices,
                  contextStorage: contexts,
                  processorCount: processorCount
              )
        else {
            return false
        }

        smpStoreRelease(&publishedProcessorCount, 0)
        var index = 0
        while index < results.count {
            results[index] = .vacant
            index += 1
        }
        index = 0
        while index < states.count {
            smpStoreRelease(
                states.baseAddress!.advanced(by: index),
                index > 0 && index < processorCount
                    ? SecondaryProcessorWorkState.prepared.rawValue
                    : SecondaryProcessorWorkState.absent.rawValue
            )
            index += 1
        }
        index = 0
        while index < stacks.count {
            stacks[index] = 0
            index += 1
        }

        let interruptState = lockScheduler()
        scheduler = active
        resultStorage = results
        stateStorage = states
        stackStorage = stacks
        unlockScheduler(restoring: interruptState)

        smpStoreRelease(&publishedProcessorCount, UInt64(processorCount))
        return true
    }

    /// Acquire-validates the context and every published storage pointer. This
    /// must succeed before a secondary initializes its local GIC state or
    /// advertises ONLINE.
    static func prepareSecondary(contextID: UInt64) -> Bool {
        guard let logicalProcessorID = validatedProcessorID(contextID),
              let states = stateStorage,
              let stateBase = states.baseAddress,
              logicalProcessorID < states.count,
              SecondaryProcessorWorkState(rawValue: smpLoadAcquire(
                  stateBase.advanced(by: logicalProcessorID)
              )) == .prepared
        else {
            return false
        }

        let interruptState = lockScheduler()
        defer { unlockScheduler(restoring: interruptState) }
        guard let active = scheduler,
              active.context(
                  logicalProcessorID: logicalProcessorID,
                  slot: 0
              ) != nil,
              active.context(
                  logicalProcessorID: logicalProcessorID,
                  slot: 1
              ) != nil,
              resultStorage != nil,
              stackStorage != nil
        else {
            return false
        }
        return true
    }

    static func recordCurrentProcessorInitializationFailure(
        contextID: UInt64
    ) {
        publishState(
            contextID: contextID,
            state: .currentProcessorInitializationFailed
        )
    }

    static func run(
        contextID: UInt64,
        observedRestartEpoch: inout UInt64
    ) -> SecondaryProcessorWorkRunResult {
        guard let logicalProcessorID = validatedProcessorID(contextID),
              let results = resultStorage,
              let states = stateStorage,
              let stateBase = states.baseAddress,
              let stacks = stackStorage,
              logicalProcessorID < states.count,
              logicalProcessorID < stacks.count,
              var tickSource = SecondaryProcessorCounterTickSource()
        else {
            return .invalidContext
        }

        stacks[logicalProcessorID] = AArch64.stackPointer
        smpStoreRelease(
            stateBase.advanced(by: logicalProcessorID),
            SecondaryProcessorWorkState.running.rawValue
        )

        guard var lease = begin(on: logicalProcessorID) else {
            publishState(
                logicalProcessorID: logicalProcessorID,
                state: .schedulingFailed
            )
            return .schedulingFailed
        }

        var completedSlot = 0
        while completedSlot
                < SecondaryProcessorWorkScheduler.tasksPerSecondaryProcessor {
            guard let context = context(for: lease),
                  context.logicalProcessorID == UInt32(logicalProcessorID),
                  var executor = SecondaryProcessorWorkExecutor(context: context)
            else {
                publishState(
                    logicalProcessorID: logicalProcessorID,
                    state: .schedulingFailed
                )
                return .schedulingFailed
            }

            var completedChecksum: UInt64?
            while completedChecksum == nil {
                switch tickSource.awaitTick(
                    logicalProcessorID: contextID,
                    observedRestartEpoch: &observedRestartEpoch
                ) {
                case .tick:
                    break
                case .clockFailed:
                    publishState(
                        logicalProcessorID: logicalProcessorID,
                        state: .clockFailed
                    )
                    return .clockFailed
                case .restartInterrupted:
                    publishState(
                        logicalProcessorID: logicalProcessorID,
                        state: .restartInterrupted
                    )
                    return .restartInterrupted
                }

                switch executor.executeQuantum(
                    iterationBudget: iterationBudgetPerQuantum
                ) {
                case .progressed:
                    break
                case let .completed(checksum):
                    completedChecksum = checksum
                case .invalidBudget:
                    publishState(
                        logicalProcessorID: logicalProcessorID,
                        state: .schedulingFailed
                    )
                    return .schedulingFailed
                }
            }

            guard let checksum = completedChecksum,
                  checksum == context.expectedChecksum
            else {
                publishState(
                    logicalProcessorID: logicalProcessorID,
                    state: .schedulingFailed
                )
                return .schedulingFailed
            }
            let resultIndex = (logicalProcessorID - 1)
                * SecondaryProcessorWorkScheduler.tasksPerSecondaryProcessor
                + completedSlot
            guard resultIndex < results.count else {
                publishState(
                    logicalProcessorID: logicalProcessorID,
                    state: .schedulingFailed
                )
                return .schedulingFailed
            }
            results[resultIndex] = SecondaryProcessorWorkResult(
                taskIdentifier: context.taskIdentifier,
                reserved: 0,
                checksum: checksum,
                quantumCount: executor.quantumCount
            )

            switch complete(lease, on: logicalProcessorID) {
            case let .next(next):
                guard completedSlot + 1
                        < SecondaryProcessorWorkScheduler
                            .tasksPerSecondaryProcessor
                else {
                    publishState(
                        logicalProcessorID: logicalProcessorID,
                        state: .schedulingFailed
                    )
                    return .schedulingFailed
                }
                lease = next
            case .drained:
                guard completedSlot + 1
                        == SecondaryProcessorWorkScheduler
                            .tasksPerSecondaryProcessor
                else {
                    publishState(
                        logicalProcessorID: logicalProcessorID,
                        state: .schedulingFailed
                    )
                    return .schedulingFailed
                }
            case .rejected:
                publishState(
                    logicalProcessorID: logicalProcessorID,
                    state: .schedulingFailed
                )
                return .schedulingFailed
            }
            completedSlot += 1
        }

        smpStoreRelease(
            stateBase.advanced(by: logicalProcessorID),
            SecondaryProcessorWorkState.completed.rawValue
        )
        smpSendEvent()
        return .completed
    }

    static func waitForEvidence(
        logicalProcessorID: Int,
        pollLimit: UInt64
    ) -> SecondaryProcessorWorkEvidenceResult {
        guard pollLimit > 0,
              logicalProcessorID > 0,
              let processorCount = publishedCount(),
              logicalProcessorID < processorCount,
              let states = stateStorage,
              let stateBase = states.baseAddress,
              let results = resultStorage,
              let stacks = stackStorage,
              logicalProcessorID < states.count,
              logicalProcessorID < stacks.count
        else {
            return .invalidContext
        }

        var pollCount: UInt64 = 0
        while pollCount < pollLimit {
            let rawState = smpLoadAcquire(
                stateBase.advanced(by: logicalProcessorID)
            )
            guard let state = SecondaryProcessorWorkState(rawValue: rawState)
            else {
                return .invalidContext
            }
            switch state {
            case .completed:
                return validateEvidence(
                    logicalProcessorID: logicalProcessorID,
                    results: results,
                    observedStackPointer: stacks[logicalProcessorID]
                )
            case .currentProcessorInitializationFailed,
                 .schedulingFailed, .clockFailed, .restartInterrupted:
                return .failed(state)
            case .prepared, .running:
                break
            case .absent:
                return .invalidContext
            }
            pollCount &+= 1
            AArch64.spinHint()
        }
        return .timedOut
    }

    static func state(
        logicalProcessorID: Int
    ) -> SecondaryProcessorWorkState? {
        guard logicalProcessorID > 0,
              let processorCount = publishedCount(),
              logicalProcessorID < processorCount,
              let states = stateStorage,
              let base = states.baseAddress,
              logicalProcessorID < states.count
        else {
            return nil
        }
        return SecondaryProcessorWorkState(
            rawValue: smpLoadAcquire(base.advanced(by: logicalProcessorID))
        )
    }

    private static func validateEvidence(
        logicalProcessorID: Int,
        results: UnsafeMutableBufferPointer<SecondaryProcessorWorkResult>,
        observedStackPointer: UInt64
    ) -> SecondaryProcessorWorkEvidenceResult {
        let resultIndex = (logicalProcessorID - 1)
            * SecondaryProcessorWorkScheduler.tasksPerSecondaryProcessor
        guard resultIndex + 1 < results.count,
              let firstContext = context(
                  logicalProcessorID: logicalProcessorID,
                  slot: 0
              ),
              let secondContext = context(
                  logicalProcessorID: logicalProcessorID,
                  slot: 1
              )
        else {
            return .invalidContext
        }
        let first = results[resultIndex]
        let second = results[resultIndex + 1]
        let stacks = KernelLinkerLayout.secondaryStacks
        guard first.taskIdentifier == firstContext.taskIdentifier,
              second.taskIdentifier == secondContext.taskIdentifier,
              first.taskIdentifier != second.taskIdentifier,
              first.checksum == firstContext.expectedChecksum,
              second.checksum == secondContext.expectedChecksum,
              first.quantumCount > 1,
              second.quantumCount > 1,
              SecondaryProcessorStackOwnership.owns(
                  stackPointer: observedStackPointer,
                  logicalProcessorID: logicalProcessorID,
                  secondaryStackStart: stacks.start,
                  secondaryStackEnd: stacks.end
              )
        else {
            return .failed(.schedulingFailed)
        }
        return .complete(SecondaryProcessorWorkEvidence(
            logicalProcessorID: UInt32(logicalProcessorID),
            first: first,
            second: second,
            observedStackPointer: observedStackPointer
        ))
    }

    private static func publishedCount() -> Int? {
        let rawCount = smpLoadAcquire(&publishedProcessorCount)
        guard rawCount > 1,
              rawCount
                <= UInt64(ProcessorStartupPlan.maximumOnlineProcessorCount),
              rawCount <= UInt64(Int.max)
        else {
            return nil
        }
        return Int(rawCount)
    }

    private static func validatedProcessorID(_ contextID: UInt64) -> Int? {
        guard let count = publishedCount(),
              contextID > 0,
              contextID < UInt64(count),
              contextID <= UInt64(Int.max)
        else {
            return nil
        }
        return Int(contextID)
    }

    private static func publishState(
        contextID: UInt64,
        state: SecondaryProcessorWorkState
    ) {
        guard let logicalProcessorID = validatedProcessorID(contextID) else {
            return
        }
        publishState(logicalProcessorID: logicalProcessorID, state: state)
    }

    private static func publishState(
        logicalProcessorID: Int,
        state: SecondaryProcessorWorkState
    ) {
        guard let states = stateStorage,
              let base = states.baseAddress,
              logicalProcessorID > 0,
              logicalProcessorID < states.count
        else {
            return
        }
        smpStoreRelease(base.advanced(by: logicalProcessorID), state.rawValue)
        smpSendEvent()
    }

    private static func begin(
        on logicalProcessorID: Int
    ) -> SecondaryProcessorWorkLease? {
        let interruptState = lockScheduler()
        defer { unlockScheduler(restoring: interruptState) }
        guard var active = scheduler else { return nil }
        let lease = active.begin(on: logicalProcessorID)
        scheduler = active
        return lease
    }

    private static func complete(
        _ lease: SecondaryProcessorWorkLease,
        on logicalProcessorID: Int
    ) -> SecondaryProcessorWorkCompletion {
        let interruptState = lockScheduler()
        defer { unlockScheduler(restoring: interruptState) }
        guard var active = scheduler else { return .rejected }
        let completion = active.complete(lease, on: logicalProcessorID)
        scheduler = active
        return completion
    }

    private static func context(
        for lease: SecondaryProcessorWorkLease
    ) -> SecondaryProcessorWorkContext? {
        let interruptState = lockScheduler()
        defer { unlockScheduler(restoring: interruptState) }
        return scheduler?.context(for: lease)
    }

    private static func context(
        logicalProcessorID: Int,
        slot: Int
    ) -> SecondaryProcessorWorkContext? {
        let interruptState = lockScheduler()
        defer { unlockScheduler(restoring: interruptState) }
        return scheduler?.context(
            logicalProcessorID: logicalProcessorID,
            slot: slot
        )
    }

    private static func lockScheduler() -> UInt64 {
        withUnsafeMutablePointer(to: &schedulerLock) { word in
            AArch64.acquireInterruptSafeLock(word)
        }
    }

    private static func unlockScheduler(restoring interruptState: UInt64) {
        withUnsafeMutablePointer(to: &schedulerLock) { word in
            AArch64.releaseInterruptSafeLock(
                word,
                restoring: interruptState
            )
        }
    }

    private static func buffer<T>(
        at address: UInt64,
        count: Int
    ) -> UnsafeMutableBufferPointer<T>? {
        guard address != 0,
              count > 0,
              address <= UInt64(UInt.max),
              address % UInt64(MemoryLayout<T>.alignment) == 0,
              let base = UnsafeMutablePointer<T>(bitPattern: UInt(address))
        else {
            return nil
        }
        return UnsafeMutableBufferPointer(start: base, count: count)
    }
}
