/// One immutable kernel-work context. The 32-byte stride keeps every linked
/// context 16-byte aligned so a `ScheduledThread` can own it directly.
struct SecondaryProcessorWorkContext: Equatable {
    let taskIdentifier: UInt32
    let logicalProcessorID: UInt32
    let iterationCount: UInt64
    let seed: UInt64
    let expectedChecksum: UInt64

    static let vacant = SecondaryProcessorWorkContext(
        taskIdentifier: 0,
        logicalProcessorID: 0,
        iterationCount: 0,
        seed: 0,
        expectedChecksum: 0
    )
}

struct SecondaryProcessorWorkLease: Equatable {
    let taskIdentifier: UInt32
    let logicalProcessorID: UInt32
    let contextAddress: UInt64
}

enum SecondaryProcessorWorkCompletion: Equatable {
    case next(SecondaryProcessorWorkLease)
    case drained
    case rejected
}

enum SecondaryProcessorWorkQuantum: Equatable {
    case progressed
    case completed(checksum: UInt64)
    case invalidBudget
}

/// Resumable deterministic Swift work. Timing is deliberately absent from the
/// executor: the processor-local timer IRQ runtime grants exactly one bounded
/// quantum without putting scheduling policy in the exception handler.
struct SecondaryProcessorWorkExecutor {
    private static let mixingConstant: UInt64 = 0x9e37_79b9_7f4a_7c15
    private static let multiplier: UInt64 = 0xbf58_476d_1ce4_e5b9

    let context: SecondaryProcessorWorkContext
    private(set) var completedIterationCount: UInt64 = 0
    private(set) var quantumCount: UInt64 = 0
    private var accumulator: UInt64

    init?(context: SecondaryProcessorWorkContext) {
        guard context.taskIdentifier != 0,
              context.logicalProcessorID > 0,
              context.iterationCount > 0
        else {
            return nil
        }
        self.context = context
        accumulator = context.seed
            ^ UInt64(context.taskIdentifier) << 32
            ^ UInt64(context.logicalProcessorID)
    }

    var isComplete: Bool {
        completedIterationCount == context.iterationCount
    }

    var checksum: UInt64? {
        isComplete ? accumulator : nil
    }

    mutating func executeQuantum(
        iterationBudget: UInt64
    ) -> SecondaryProcessorWorkQuantum {
        guard iterationBudget > 0 else { return .invalidBudget }
        guard !isComplete else {
            return .completed(checksum: accumulator)
        }

        let remaining = context.iterationCount - completedIterationCount
        let count = iterationBudget < remaining ? iterationBudget : remaining
        let end = completedIterationCount + count
        while completedIterationCount < end {
            let ordinal = completedIterationCount &+ 1
            var mixed = accumulator
                ^ (ordinal &* Self.mixingConstant)
                ^ context.seed
            let rotation = UInt64(
                (context.taskIdentifier &+ UInt32(truncatingIfNeeded: ordinal))
                    % 63 &+ 1
            )
            mixed = (mixed << rotation) | (mixed >> (64 - rotation))
            accumulator = mixed &* Self.multiplier
                &+ UInt64(context.logicalProcessorID)
            completedIterationCount = ordinal
        }
        quantumCount &+= 1
        return isComplete
            ? .completed(checksum: accumulator)
            : .progressed
    }

    static func expectedChecksum(
        taskIdentifier: UInt32,
        logicalProcessorID: UInt32,
        iterationCount: UInt64,
        seed: UInt64
    ) -> UInt64? {
        let context = SecondaryProcessorWorkContext(
            taskIdentifier: taskIdentifier,
            logicalProcessorID: logicalProcessorID,
            iterationCount: iterationCount,
            seed: seed,
            expectedChecksum: 0
        )
        guard var executor = SecondaryProcessorWorkExecutor(context: context)
        else {
            return nil
        }
        while !executor.isComplete {
            _ = executor.executeQuantum(iterationBudget: 256)
        }
        return executor.checksum
    }
}

/// Fixed-storage scheduler for kernel work on processors brought online by
/// PSCI. Each secondary owns two distinct contexts pinned by affinity. Callers
/// serialize mutation; execution itself occurs outside the scheduler lock.
struct SecondaryProcessorWorkScheduler {
    static let tasksPerSecondaryProcessor = 2
    static let maximumTaskCount =
        (ProcessorStartupPlan.maximumOnlineProcessorCount - 1)
        * tasksPerSecondaryProcessor

    private static let processIdentifier: UInt32 = 2
    private static let baseIterationCount: UInt64 = 1_024
    private static let iterationStride: UInt64 = 97
    private static let seedBase: UInt64 = 0x5357_4946_545f_534d

    private var runQueue: RunQueue
    private var contexts:
        UnsafeMutableBufferPointer<SecondaryProcessorWorkContext>
    private(set) var taskCount: Int = 0

    init?(
        threadStorage: UnsafeMutableBufferPointer<ScheduledThread>,
        currentIndexStorage: UnsafeMutableBufferPointer<Int32>,
        contextStorage:
            UnsafeMutableBufferPointer<SecondaryProcessorWorkContext>,
        processorCount: Int
    ) {
        let requiredTaskCount = (processorCount - 1)
            * Self.tasksPerSecondaryProcessor
        guard processorCount > 1,
              processorCount
                <= ProcessorStartupPlan.maximumOnlineProcessorCount,
              requiredTaskCount <= threadStorage.count,
              requiredTaskCount <= contextStorage.count,
              currentIndexStorage.count >= processorCount,
              MemoryLayout<SecondaryProcessorWorkContext>.stride % 16 == 0,
              let contextBase = contextStorage.baseAddress,
              UInt(bitPattern: contextBase) & 0xf == 0,
              var queue = RunQueue(
                  threadStorage: threadStorage,
                  currentIndexStorage: currentIndexStorage,
                  processorCount: processorCount
              )
        else {
            return nil
        }

        var index = 0
        while index < contextStorage.count {
            contextStorage[index] = .vacant
            index += 1
        }

        var logicalProcessorID = 1
        while logicalProcessorID < processorCount {
            var slot = 0
            while slot < Self.tasksPerSecondaryProcessor {
                let taskIndex = (logicalProcessorID - 1)
                    * Self.tasksPerSecondaryProcessor + slot
                let taskIdentifier = UInt32(logicalProcessorID * 16 + slot + 1)
                let iterationCount = Self.baseIterationCount
                    + UInt64(taskIndex) * Self.iterationStride
                let seed = Self.seedBase
                    ^ UInt64(logicalProcessorID) << 48
                    ^ UInt64(slot + 1) << 8
                guard let expectedChecksum =
                        SecondaryProcessorWorkExecutor.expectedChecksum(
                            taskIdentifier: taskIdentifier,
                            logicalProcessorID: UInt32(logicalProcessorID),
                            iterationCount: iterationCount,
                            seed: seed
                        )
                else {
                    return nil
                }
                contextStorage[taskIndex] = SecondaryProcessorWorkContext(
                    taskIdentifier: taskIdentifier,
                    logicalProcessorID: UInt32(logicalProcessorID),
                    iterationCount: iterationCount,
                    seed: seed,
                    expectedChecksum: expectedChecksum
                )
                let contextAddress = UInt64(UInt(bitPattern:
                    contextBase.advanced(by: taskIndex)
                ))
                guard queue.add(
                          identifier: taskIdentifier,
                          processIdentifier: Self.processIdentifier,
                          affinityMask:
                            UInt64(1) << UInt64(logicalProcessorID),
                          contextAddress: contextAddress
                      )
                else {
                    return nil
                }
                slot += 1
            }
            logicalProcessorID += 1
        }

        runQueue = queue
        contexts = contextStorage
        taskCount = requiredTaskCount
    }

    mutating func begin(
        on logicalProcessorID: Int
    ) -> SecondaryProcessorWorkLease? {
        guard validSecondary(logicalProcessorID),
              let decision = runQueue.begin(on: logicalProcessorID)
        else {
            return nil
        }
        return lease(
            for: decision.nextThreadIdentifier,
            contextAddress: decision.nextContextAddress,
            logicalProcessorID: logicalProcessorID
        )
    }

    mutating func complete(
        _ lease: SecondaryProcessorWorkLease,
        on logicalProcessorID: Int
    ) -> SecondaryProcessorWorkCompletion {
        guard validSecondary(logicalProcessorID),
              lease.logicalProcessorID == UInt32(logicalProcessorID),
              let current = runQueue.currentThread(on: logicalProcessorID),
              current.identifier == lease.taskIdentifier,
              current.contextAddress == lease.contextAddress
        else {
            return .rejected
        }

        let decision = runQueue.exitCurrent(on: logicalProcessorID)
        guard let decision else { return .drained }
        guard let next = self.lease(
                  for: decision.nextThreadIdentifier,
                  contextAddress: decision.nextContextAddress,
                  logicalProcessorID: logicalProcessorID
              )
        else {
            return .rejected
        }
        return .next(next)
    }

    func context(
        for lease: SecondaryProcessorWorkLease
    ) -> SecondaryProcessorWorkContext? {
        guard lease.logicalProcessorID > 0,
              let context = context(identifier: lease.taskIdentifier),
              context.logicalProcessorID == lease.logicalProcessorID,
              contextAddress(of: context.taskIdentifier)
                == lease.contextAddress
        else {
            return nil
        }
        return context
    }

    func context(
        logicalProcessorID: Int,
        slot: Int
    ) -> SecondaryProcessorWorkContext? {
        guard validSecondary(logicalProcessorID),
              slot >= 0,
              slot < Self.tasksPerSecondaryProcessor
        else {
            return nil
        }
        let index = (logicalProcessorID - 1)
            * Self.tasksPerSecondaryProcessor + slot
        guard index < taskCount else { return nil }
        return contexts[index]
    }

    private func lease(
        for identifier: UInt32,
        contextAddress: UInt64,
        logicalProcessorID: Int
    ) -> SecondaryProcessorWorkLease? {
        guard let context = context(identifier: identifier),
              context.logicalProcessorID == UInt32(logicalProcessorID),
              self.contextAddress(of: identifier) == contextAddress
        else {
            return nil
        }
        return SecondaryProcessorWorkLease(
            taskIdentifier: identifier,
            logicalProcessorID: UInt32(logicalProcessorID),
            contextAddress: contextAddress
        )
    }

    private func context(
        identifier: UInt32
    ) -> SecondaryProcessorWorkContext? {
        var index = 0
        while index < taskCount {
            if contexts[index].taskIdentifier == identifier {
                return contexts[index]
            }
            index += 1
        }
        return nil
    }

    private func contextAddress(of identifier: UInt32) -> UInt64? {
        guard let base = contexts.baseAddress else { return nil }
        var index = 0
        while index < taskCount {
            if contexts[index].taskIdentifier == identifier {
                return UInt64(UInt(bitPattern: base.advanced(by: index)))
            }
            index += 1
        }
        return nil
    }

    private func validSecondary(_ logicalProcessorID: Int) -> Bool {
        logicalProcessorID > 0
            && logicalProcessorID < runQueue.processorCount
    }
}

enum SecondaryProcessorStackOwnership {
    static func owns(
        stackPointer: UInt64,
        logicalProcessorID: Int,
        secondaryStackStart: UInt64,
        secondaryStackEnd: UInt64,
        maximumProcessorCount: Int =
            ProcessorStartupPlan.maximumOnlineProcessorCount
    ) -> Bool {
        let secondaryCount = maximumProcessorCount - 1
        guard logicalProcessorID > 0,
              logicalProcessorID <= secondaryCount,
              secondaryCount > 0,
              secondaryStackEnd > secondaryStackStart
        else {
            return false
        }
        let regionLength = secondaryStackEnd - secondaryStackStart
        guard regionLength % UInt64(secondaryCount) == 0 else {
            return false
        }
        let stackByteCount = regionLength
            / UInt64(secondaryCount)
        let lower = secondaryStackStart
            + UInt64(logicalProcessorID - 1) * stackByteCount
        let upper = lower + stackByteCount
        return stackPointer > lower
            && stackPointer <= upper
            && stackPointer & 0xf == 0
    }
}
