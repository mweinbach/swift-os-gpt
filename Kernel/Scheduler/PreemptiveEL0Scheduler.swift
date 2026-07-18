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
}

struct EL0SchedulingEvidence: Equatable {
    let timerInterruptCount: UInt64
    let involuntarySwitchCount: UInt64
    let firstThread: EL0ThreadReportSnapshot
    let secondThread: EL0ThreadReportSnapshot

    var bothThreadsReported: Bool {
        firstThread.reportCount > 0 && secondThread.reportCount > 0
    }

    var demonstratesPreemptiveMultithreading: Bool {
        bothThreadsReported
            && involuntarySwitchCount
                >= PreemptiveEL0Scheduler.minimumSwitchesForEvidence
    }
}

/// A fixed two-thread, round-robin EL0 scheduler.
///
/// The caller owns all queue and register-image storage. Timer and synchronous
/// exception entry already mask IRQs, so the CPU0-only implementation needs no
/// allocator or lock. SMP extension requires per-CPU active-thread state and a
/// synchronization strategy before either thread may have affinity beyond bit
/// zero.
struct PreemptiveEL0Scheduler {
    static let reportSystemCallNumber: UInt64 = 1
    static let minimumSwitchesForEvidence: UInt64 = 2
    static let evidenceMarker: StaticString =
        "SWIFTOS:EL0_PREEMPTION_PROVEN\n"

    private static let cpu0 = 0
    private static let cpu0AffinityMask: UInt64 = 1
    private static let supervisorCall64ExceptionClass: UInt64 = 0x15
    private static let exceptionClassShift: UInt64 = 26
    private static let exceptionClassMask: UInt64 = 0x3f
    private static let el0tProgramStatus: UInt64 = 0

    private var runQueue: RunQueue
    private let firstThread: EL0ThreadBootstrap
    private let secondThread: EL0ThreadBootstrap
    private(set) var activeThreadIdentifier: UInt32?

    private var timerInterrupts: UInt64 = 0
    private var involuntarySwitches: UInt64 = 0
    private var firstReport = EL0ThreadReportSnapshot(
        reportCount: 0,
        lastSequence: 0,
        lastChecksum: 0
    )
    private var secondReport = EL0ThreadReportSnapshot(
        reportCount: 0,
        lastSequence: 0,
        lastChecksum: 0
    )

    init?(
        threadStorage: UnsafeMutableBufferPointer<ScheduledThread>,
        currentIndexStorage: UnsafeMutableBufferPointer<Int32>,
        processIdentifier: UInt32,
        userEntryAddress: UInt64,
        firstThread: EL0ThreadBootstrap,
        secondThread: EL0ThreadBootstrap
    ) {
        guard processIdentifier != 0,
              userEntryAddress != 0,
              userEntryAddress & 3 == 0,
              Self.valid(firstThread),
              Self.valid(secondThread),
              firstThread.identifier != secondThread.identifier,
              firstThread.contextAddress != secondThread.contextAddress,
              firstThread.userStackTop != secondThread.userStackTop,
              firstThread.threadPointer != secondThread.threadPointer,
              threadStorage.count >= 2,
              !currentIndexStorage.isEmpty,
              var queue = RunQueue(
                  threadStorage: threadStorage,
                  currentIndexStorage: currentIndexStorage,
                  processorCount: 1
              )
        else {
            return nil
        }

        Self.synthesizeInitialFrame(
            at: firstThread.contextAddress,
            thread: firstThread,
            userEntryAddress: userEntryAddress
        )
        Self.synthesizeInitialFrame(
            at: secondThread.contextAddress,
            thread: secondThread,
            userEntryAddress: userEntryAddress
        )

        guard queue.add(
                  identifier: firstThread.identifier,
                  processIdentifier: processIdentifier,
                  affinityMask: Self.cpu0AffinityMask,
                  contextAddress: firstThread.contextAddress
              ),
              queue.add(
                  identifier: secondThread.identifier,
                  processIdentifier: processIdentifier,
                  affinityMask: Self.cpu0AffinityMask,
                  contextAddress: secondThread.contextAddress
              )
        else {
            return nil
        }

        runQueue = queue
        self.firstThread = firstThread
        self.secondThread = secondThread
        activeThreadIdentifier = nil
    }

    var evidence: EL0SchedulingEvidence {
        EL0SchedulingEvidence(
            timerInterruptCount: timerInterrupts,
            involuntarySwitchCount: involuntarySwitches,
            firstThread: firstReport,
            secondThread: secondReport
        )
    }

    /// Replaces one caller-provided exception image with the first runnable
    /// EL0 context. Returning through the exception veneer then enters EL0t.
    mutating func installInitialContext(
        in rawFrame: UnsafeMutableRawPointer
    ) -> Bool {
        guard activeThreadIdentifier == nil,
              !isContextStorage(rawFrame),
              let decision = runQueue.begin(on: Self.cpu0),
              Self.copyStoredFrame(
                  at: decision.nextContextAddress,
                  to: rawFrame
              )
        else {
            return false
        }
        activeThreadIdentifier = decision.nextThreadIdentifier
        return true
    }

    /// Timer-hook entry point. The full outgoing 832-byte image is saved before
    /// the next image replaces the live exception frame, including all SIMD,
    /// SP_EL0, and TPIDR_EL0 state.
    @discardableResult
    mutating func handleTimerInterrupt(
        frame rawFrame: UnsafeMutableRawPointer
    ) -> Bool {
        guard let activeThreadIdentifier,
              !isContextStorage(rawFrame),
              let outgoing = runQueue.thread(
                  identifier: activeThreadIdentifier
              ),
              Self.copyLiveFrame(
                  rawFrame,
                  to: outgoing.contextAddress
              )
        else {
            return false
        }

        timerInterrupts &+= 1
        guard let decision = runQueue.preempt(on: Self.cpu0),
              Self.copyStoredFrame(
                  at: decision.nextContextAddress,
                  to: rawFrame
              )
        else {
            return false
        }

        self.activeThreadIdentifier = decision.nextThreadIdentifier
        involuntarySwitches &+= 1
        return true
    }

    /// Synchronous-exception entry point for the userspace report ABI. This
    /// records report arguments but never performs a scheduling decision.
    @discardableResult
    mutating func handleReportSystemCall(
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
        guard let activeThreadIdentifier,
              frame.pointee.x0 == UInt64(activeThreadIdentifier)
        else {
            return .rejectedReport
        }

        let sequence = frame.pointee.x1
        let checksum = frame.pointee.x2
        if activeThreadIdentifier == firstThread.identifier {
            guard sequence > firstReport.lastSequence else {
                return .rejectedReport
            }
            firstReport = EL0ThreadReportSnapshot(
                reportCount: firstReport.reportCount &+ 1,
                lastSequence: sequence,
                lastChecksum: checksum
            )
        } else if activeThreadIdentifier == secondThread.identifier {
            guard sequence > secondReport.lastSequence else {
                return .rejectedReport
            }
            secondReport = EL0ThreadReportSnapshot(
                reportCount: secondReport.reportCount &+ 1,
                lastSequence: sequence,
                lastChecksum: checksum
            )
        } else {
            return .rejectedReport
        }

        frame.pointee.x0 = 0
        return .reportAccepted
    }

    private static func valid(_ thread: EL0ThreadBootstrap) -> Bool {
        thread.identifier != 0
            && thread.contextAddress != 0
            && thread.contextAddress & 0xf == 0
            && thread.contextByteCount >= AArch64ExceptionFrame.byteCount
            && thread.userStackTop != 0
            && thread.userStackTop & 0xf == 0
            && thread.threadPointer != 0
            && UnsafeMutableRawPointer(
                bitPattern: UInt(thread.contextAddress)
            ) != nil
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
        return address == firstThread.contextAddress
            || address == secondThread.contextAddress
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
    /// exception frame. Stored frames are still required to be 16-byte aligned
    /// so the assembly restore ABI remains valid.
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
