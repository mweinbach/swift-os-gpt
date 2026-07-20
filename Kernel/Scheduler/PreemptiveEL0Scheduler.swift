struct EL0ThreadBootstrap {
    let identifier: UInt32
    let contextAddress: UInt64
    let contextByteCount: Int
    let userStackTop: UInt64
    let threadPointer: UInt64

    init(
        identifier: UInt32,
        contextAddress: UInt64,
        contextByteCount: Int = AArch64ExceptionFrame.byteCount,
        userStackTop: UInt64,
        threadPointer: UInt64
    ) {
        self.identifier = identifier
        self.contextAddress = contextAddress
        self.contextByteCount = contextByteCount
        self.userStackTop = userStackTop
        self.threadPointer = threadPointer
    }
}

enum EL0SystemCallDisposition: UInt8, Equatable {
    case notFromEL0
    case notSupervisorCall
    case unsupported
    case rejectedReport
    case reportAccepted
}

struct EL0ThreadReportSnapshot: Equatable {
    let reportCount: UInt64
    let lastSequence: UInt64
    let lastChecksum: UInt64
    let processorMask: UInt64
    let migrationCount: UInt64

    static let empty = EL0ThreadReportSnapshot(
        reportCount: 0,
        lastSequence: 0,
        lastChecksum: 0,
        processorMask: 0,
        migrationCount: 0
    )

    /// A migration is counted only after this thread reaches the report SVC
    /// on another processor. Merely selecting a stored context is not proof
    /// that userspace executed there.
    var observedMultipleProcessors: Bool {
        processorMask != 0
            && processorMask & (processorMask &- 1) != 0
            && migrationCount > 0
    }
}

/// Caller-owned report state for one EL0 thread. Keeping this separate from
/// `ScheduledThread` leaves the generic run queue usable for kernel work.
struct EL0ThreadReportRecord: Equatable {
    let threadIdentifier: UInt32
    var reportCount: UInt64
    var lastSequence: UInt64
    var lastChecksum: UInt64
    var processorMask: UInt64
    var migrationCount: UInt64
    var lastProcessor: Int32

    static let vacant = EL0ThreadReportRecord(
        threadIdentifier: 0,
        reportCount: 0,
        lastSequence: 0,
        lastChecksum: 0,
        processorMask: 0,
        migrationCount: 0,
        lastProcessor: -1
    )

    init(threadIdentifier: UInt32) {
        self.threadIdentifier = threadIdentifier
        reportCount = 0
        lastSequence = 0
        lastChecksum = 0
        processorMask = 0
        migrationCount = 0
        lastProcessor = -1
    }

    private init(
        threadIdentifier: UInt32,
        reportCount: UInt64,
        lastSequence: UInt64,
        lastChecksum: UInt64,
        processorMask: UInt64,
        migrationCount: UInt64,
        lastProcessor: Int32
    ) {
        self.threadIdentifier = threadIdentifier
        self.reportCount = reportCount
        self.lastSequence = lastSequence
        self.lastChecksum = lastChecksum
        self.processorMask = processorMask
        self.migrationCount = migrationCount
        self.lastProcessor = lastProcessor
    }

    var snapshot: EL0ThreadReportSnapshot {
        EL0ThreadReportSnapshot(
            reportCount: reportCount,
            lastSequence: lastSequence,
            lastChecksum: lastChecksum,
            processorMask: processorMask,
            migrationCount: migrationCount
        )
    }
}

struct EL0SchedulingEvidence: Equatable {
    let timerInterruptCount: UInt64
    let involuntarySwitchCount: UInt64
    let firstThread: EL0ThreadReportSnapshot
    let secondThread: EL0ThreadReportSnapshot
    let reportingProcessorMask: UInt64
    let reportingThreadCount: Int
    let threadCount: Int
    let migratedThreadCount: Int

    var bothThreadsReported: Bool {
        firstThread.reportCount > 0 && secondThread.reportCount > 0
    }

    var allThreadsReported: Bool {
        threadCount > 0 && reportingThreadCount == threadCount
    }

    var demonstratesPreemptiveMultithreading: Bool {
        allThreadsReported
            && involuntarySwitchCount
                >= PreemptiveEL0Scheduler.minimumSwitchesForEvidence
    }

    var demonstratesCrossProcessorMigration: Bool {
        migratedThreadCount > 0
    }
}

/// Fixed-capacity round-robin EL0 scheduler for one shared address space.
///
/// The caller owns the queue, report, and complete register-image storage. A
/// runtime using more than one processor must serialize every mutating method
/// with one interrupt-safe lock. Under that lock, a running thread is owned by
/// exactly one `RunQueue` processor slot and no stored context is concurrently
/// live on another processor.
struct PreemptiveEL0Scheduler {
    static let maximumProcessorCount = 4
    static let maximumThreadCount = maximumProcessorCount + 1
    static let reportSystemCallNumber: UInt64 = 1
    static let minimumSwitchesForEvidence: UInt64 = 2
    static let evidenceMarker: StaticString =
        "SWIFTOS:EL0_PREEMPTION_PROVEN\n"
    static let migrationEvidenceMarker: StaticString =
        "SWIFTOS:EL0_MIGRATION_PROVEN\n"

    private static let supervisorCall64ExceptionClass: UInt64 = 0x15
    private static let exceptionClassShift: UInt64 = 26
    private static let exceptionClassMask: UInt64 = 0x3f
    private static let el0tProgramStatus: UInt64 = 0

    private var runQueue: RunQueue
    private var reports: UnsafeMutableBufferPointer<EL0ThreadReportRecord>
    private var timerInterrupts: UInt64 = 0
    private var involuntarySwitches: UInt64 = 0

    init?(
        threadStorage: UnsafeMutableBufferPointer<ScheduledThread>,
        currentIndexStorage: UnsafeMutableBufferPointer<Int32>,
        reportStorage: UnsafeMutableBufferPointer<EL0ThreadReportRecord>,
        processorCount: Int,
        processIdentifier: UInt32,
        userEntryAddress: UInt64,
        threads: UnsafeBufferPointer<EL0ThreadBootstrap>
    ) {
        guard processIdentifier != 0,
              userEntryAddress != 0,
              userEntryAddress & 3 == 0,
              processorCount > 0,
              processorCount <= Self.maximumProcessorCount,
              threads.count >= processorCount,
              threads.count <= Self.maximumThreadCount,
              threadStorage.count >= threads.count,
              currentIndexStorage.count >= processorCount,
              reportStorage.count >= threads.count,
              Self.validThreads(threads),
              var queue = RunQueue(
                  threadStorage: threadStorage,
                  currentIndexStorage: currentIndexStorage,
                  processorCount: processorCount
              )
        else {
            return nil
        }

        let affinityMask = (UInt64(1) << UInt64(processorCount)) &- 1
        var index = 0
        while index < threads.count {
            let thread = threads[index]
            Self.synthesizeInitialFrame(
                at: thread.contextAddress,
                thread: thread,
                userEntryAddress: userEntryAddress
            )
            guard queue.add(
                      identifier: thread.identifier,
                      processIdentifier: processIdentifier,
                      affinityMask: affinityMask,
                      contextAddress: thread.contextAddress
                  )
            else {
                return nil
            }
            reportStorage[index] = EL0ThreadReportRecord(
                threadIdentifier: thread.identifier
            )
            index += 1
        }

        runQueue = queue
        reports = UnsafeMutableBufferPointer(
            rebasing: reportStorage.prefix(threads.count)
        )
    }

    var processorCount: Int { runQueue.processorCount }
    var threadCount: Int { reports.count }

    var evidence: EL0SchedulingEvidence {
        var reportingProcessorMask: UInt64 = 0
        var reportingThreadCount = 0
        var migratedThreadCount = 0
        var index = 0
        while index < reports.count {
            let snapshot = reports[index].snapshot
            reportingProcessorMask |= snapshot.processorMask
            if snapshot.reportCount > 0 { reportingThreadCount += 1 }
            if snapshot.observedMultipleProcessors {
                migratedThreadCount += 1
            }
            index += 1
        }
        return EL0SchedulingEvidence(
            timerInterruptCount: timerInterrupts,
            involuntarySwitchCount: involuntarySwitches,
            firstThread: reports.count > 0
                ? reports[0].snapshot : .empty,
            secondThread: reports.count > 1
                ? reports[1].snapshot : .empty,
            reportingProcessorMask: reportingProcessorMask,
            reportingThreadCount: reportingThreadCount,
            threadCount: reports.count,
            migratedThreadCount: migratedThreadCount
        )
    }

    func activeThreadIdentifier(on processor: Int) -> UInt32? {
        runQueue.currentThread(on: processor)?.identifier
    }

    func reportSnapshot(
        threadIdentifier: UInt32
    ) -> EL0ThreadReportSnapshot? {
        guard let index = reportIndex(
                  threadIdentifier: threadIdentifier
              )
        else {
            return nil
        }
        return reports[index].snapshot
    }

    /// Replaces one caller-provided exception image with the first runnable
    /// context for `processor`. Returning through the exception veneer then
    /// enters EL0t on that processor.
    mutating func installInitialContext(
        on processor: Int,
        in rawFrame: UnsafeMutableRawPointer
    ) -> Bool {
        guard !isContextStorage(rawFrame),
              let decision = runQueue.begin(on: processor),
              Self.copyStoredFrame(
                  at: decision.nextContextAddress,
                  to: rawFrame
              )
        else {
            return false
        }
        return true
    }

    /// Timer-hook entry point. The outgoing image is copied while its queue
    /// lease still says `running`; only then may `preempt` make that context
    /// visible as ready to another processor.
    @discardableResult
    mutating func handleTimerInterrupt(
        on processor: Int,
        frame rawFrame: UnsafeMutableRawPointer
    ) -> Bool {
        guard !isContextStorage(rawFrame),
              let outgoing = runQueue.currentThread(on: processor),
              Self.copyLiveFrame(
                  rawFrame,
                  to: outgoing.contextAddress
              )
        else {
            return false
        }

        timerInterrupts &+= 1
        guard let decision = runQueue.preempt(on: processor),
              Self.copyStoredFrame(
                  at: decision.nextContextAddress,
                  to: rawFrame
              )
        else {
            return false
        }

        involuntarySwitches &+= 1
        return true
    }

    /// Saves and releases a processor's live EL0 lease before a no-return
    /// firmware shutdown attempt. If CPU_OFF returns, `installInitialContext`
    /// may safely lease any ready context into the same exception frame.
    @discardableResult
    mutating func relinquishProcessor(
        on processor: Int,
        frame rawFrame: UnsafeMutableRawPointer
    ) -> Bool {
        guard !isContextStorage(rawFrame),
              let outgoing = runQueue.currentThread(on: processor),
              Self.copyLiveFrame(
                  rawFrame,
                  to: outgoing.contextAddress
              ),
              runQueue.relinquishCurrent(on: processor)
        else {
            return false
        }
        return true
    }

    /// Records the proof-oriented report ABI without making a scheduling
    /// decision. Identity is attributed through the queue's processor lease;
    /// the user-provided x0 must agree but is never trusted on its own.
    @discardableResult
    mutating func handleReportSystemCall(
        on processor: Int,
        frame rawFrame: UnsafeMutableRawPointer
    ) -> EL0SystemCallDisposition {
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        guard frame.pointee.exceptionKind == .synchronous,
              frame.pointee.cameFromLowerExceptionLevel
        else {
            return .notFromEL0
        }

        let exceptionClass =
            (frame.pointee.syndrome >> Self.exceptionClassShift)
            & Self.exceptionClassMask
        guard exceptionClass == Self.supervisorCall64ExceptionClass else {
            return .notSupervisorCall
        }
        guard frame.pointee.x8 == Self.reportSystemCallNumber else {
            return .unsupported
        }
        guard let activeThread = runQueue.currentThread(on: processor),
              frame.pointee.x0 == UInt64(activeThread.identifier),
              let index = reportIndex(
                  threadIdentifier: activeThread.identifier
              )
        else {
            return .rejectedReport
        }

        let sequence = frame.pointee.x1
        var record = reports[index]
        guard sequence > record.lastSequence else {
            return .rejectedReport
        }

        let processorBit = UInt64(1) << UInt64(processor)
        if record.lastProcessor >= 0,
           record.lastProcessor != Int32(processor) {
            record.migrationCount &+= 1
        }
        record.reportCount &+= 1
        record.lastSequence = sequence
        record.lastChecksum = frame.pointee.x2
        record.processorMask |= processorBit
        record.lastProcessor = Int32(processor)
        reports[index] = record

        frame.pointee.x0 = 0
        return .reportAccepted
    }

    private static func validThreads(
        _ threads: UnsafeBufferPointer<EL0ThreadBootstrap>
    ) -> Bool {
        var index = 0
        while index < threads.count {
            let thread = threads[index]
            guard valid(thread) else { return false }

            var prior = 0
            while prior < index {
                let other = threads[prior]
                guard thread.identifier != other.identifier,
                      thread.userStackTop != other.userStackTop,
                      thread.threadPointer != other.threadPointer,
                      !contextFramesOverlap(thread, other)
                else {
                    return false
                }
                prior += 1
            }
            index += 1
        }
        return true
    }

    private static func valid(_ thread: EL0ThreadBootstrap) -> Bool {
        thread.identifier != 0
            && thread.contextAddress != 0
            && thread.contextAddress & 0xf == 0
            && thread.contextByteCount >= AArch64ExceptionFrame.byteCount
            && thread.contextAddress
                <= UInt64.max - UInt64(AArch64ExceptionFrame.byteCount)
            && thread.userStackTop != 0
            && thread.userStackTop & 0xf == 0
            && thread.threadPointer != 0
            && UnsafeMutableRawPointer(
                bitPattern: UInt(thread.contextAddress)
            ) != nil
    }

    private static func contextFramesOverlap(
        _ first: EL0ThreadBootstrap,
        _ second: EL0ThreadBootstrap
    ) -> Bool {
        let byteCount = UInt64(AArch64ExceptionFrame.byteCount)
        return first.contextAddress < second.contextAddress + byteCount
            && second.contextAddress < first.contextAddress + byteCount
    }

    private static func synthesizeInitialFrame(
        at address: UInt64,
        thread: EL0ThreadBootstrap,
        userEntryAddress: UInt64
    ) {
        guard let rawFrame = UnsafeMutableRawPointer(
            bitPattern: UInt(address)
        ) else {
            return
        }
        zeroFrame(rawFrame)
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        frame.pointee.x0 = UInt64(thread.identifier)
        frame.pointee.exceptionLink = userEntryAddress
        frame.pointee.savedProgramStatus = el0tProgramStatus
        frame.pointee.stackPointerEL0 = thread.userStackTop
        frame.pointee.threadPointerEL0 = thread.threadPointer
    }

    private func isContextStorage(
        _ rawFrame: UnsafeMutableRawPointer
    ) -> Bool {
        let address = UInt64(UInt(bitPattern: rawFrame))
        guard address <= UInt64.max
                - UInt64(AArch64ExceptionFrame.byteCount)
        else {
            return true
        }
        let end = address + UInt64(AArch64ExceptionFrame.byteCount)
        var index = 0
        while index < runQueue.threadCount {
            guard let thread = runQueue.thread(at: index) else {
                return true
            }
            let contextStart = thread.contextAddress
            let contextEnd = contextStart
                + UInt64(AArch64ExceptionFrame.byteCount)
            if address < contextEnd && contextStart < end { return true }
            index += 1
        }
        return false
    }

    private func reportIndex(threadIdentifier: UInt32) -> Int? {
        var index = 0
        while index < reports.count {
            if reports[index].threadIdentifier == threadIdentifier {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func zeroFrame(_ destination: UnsafeMutableRawPointer) {
        var offset = 0
        while offset < AArch64ExceptionFrame.byteCount {
            destination.storeBytes(
                of: UInt8(0),
                toByteOffset: offset,
                as: UInt8.self
            )
            offset += 1
        }
    }

    private static func copyLiveFrame(
        _ source: UnsafeRawPointer,
        to destinationAddress: UInt64
    ) -> Bool {
        guard let destination = UnsafeMutableRawPointer(
            bitPattern: UInt(destinationAddress)
        ) else {
            return false
        }
        copyFrame(from: source, to: destination)
        return true
    }

    private static func copyStoredFrame(
        at sourceAddress: UInt64,
        to destination: UnsafeMutableRawPointer
    ) -> Bool {
        guard let source = UnsafeRawPointer(
            bitPattern: UInt(sourceAddress)
        ) else {
            return false
        }
        copyFrame(from: source, to: destination)
        return true
    }

    /// Byte copies deliberately avoid an alignment assumption for the live
    /// exception frame. Stored frames are 16-byte aligned for the assembly ABI.
    private static func copyFrame(
        from source: UnsafeRawPointer,
        to destination: UnsafeMutableRawPointer
    ) {
        var offset = 0
        while offset < AArch64ExceptionFrame.byteCount {
            let byte = source.load(fromByteOffset: offset, as: UInt8.self)
            destination.storeBytes(
                of: byte,
                toByteOffset: offset,
                as: UInt8.self
            )
            offset += 1
        }
    }
}
