struct KernelEL0ThreadAddressSpaceMapping: Equatable {
    let stack: FinalMappingRegion
    let guardRegion: FinalGuardRegion
    let stackTop: UInt64
    let threadPointer: UInt64
}

struct KernelEL0AddressSpaceMappings: Equatable {
    static let threadCapacity = 5

    let userText: FinalMappingRegion
    let userReadOnlyData: FinalMappingRegion?
    let userEntryAddress: UInt64
    private let thread0: KernelEL0ThreadAddressSpaceMapping
    private let thread1: KernelEL0ThreadAddressSpaceMapping
    private let thread2: KernelEL0ThreadAddressSpaceMapping
    private let thread3: KernelEL0ThreadAddressSpaceMapping
    private let thread4: KernelEL0ThreadAddressSpaceMapping

    fileprivate init(
        userText: FinalMappingRegion,
        userReadOnlyData: FinalMappingRegion?,
        userEntryAddress: UInt64,
        thread0: KernelEL0ThreadAddressSpaceMapping,
        thread1: KernelEL0ThreadAddressSpaceMapping,
        thread2: KernelEL0ThreadAddressSpaceMapping,
        thread3: KernelEL0ThreadAddressSpaceMapping,
        thread4: KernelEL0ThreadAddressSpaceMapping
    ) {
        self.userText = userText
        self.userReadOnlyData = userReadOnlyData
        self.userEntryAddress = userEntryAddress
        self.thread0 = thread0
        self.thread1 = thread1
        self.thread2 = thread2
        self.thread3 = thread3
        self.thread4 = thread4
    }

    func thread(at index: Int) -> KernelEL0ThreadAddressSpaceMapping? {
        switch index {
        case 0: return thread0
        case 1: return thread1
        case 2: return thread2
        case 3: return thread3
        case 4: return thread4
        default: return nil
        }
    }
}

typealias KernelEL0ExternalSystemCallHook =
    @convention(c) (UnsafeMutableRawPointer) -> UInt64

/// Binds the linker-owned userspace image and scheduler storage to the
/// exception subsystem. The final translation table must contain the mappings
/// returned by `addressSpaceMappings()` before `launch` is called.
///
/// Every managed processor shares one immutable EL0 address space. Context and
/// run-queue ownership are serialized separately by the runtime scheduler lock.
enum KernelEL0Runtime {
    // All aliases stay in the upper half of the 39-bit TTBR0 address space.
    // They are intentionally far from identity-mapped kernel and MMIO ranges.
    static let userTextVirtualBase: UInt64 = 0x40_0000_0000
    static let firstUserStackVirtualBase: UInt64 = 0x40_1000_0000
    static let userStackVirtualStride: UInt64 = 0x0000_1000_0000

    /// Preserves the linked text-to-rodata displacement so ADRP/ADD references
    /// remain correct when the user image executes through its high alias.
    static var userReadOnlyDataVirtualBase: UInt64? {
        let text = KernelLinkerLayout.userText
        let readOnlyData = KernelLinkerLayout.userReadOnlyData
        guard let offset = subtracting(readOnlyData.start, text.start) else {
            return nil
        }
        return adding(userTextVirtualBase, offset)
    }

    static let el0ReadyMarker: StaticString = "SWIFTOS:EL0_OK\n"
    static let threadsReadyMarker: StaticString = "SWIFTOS:THREADS_OK\n"
    static let preemptionReadyMarker: StaticString = "SWIFTOS:PREEMPT_OK\n"
    static let schedulerReadyMarker: StaticString =
        "SWIFTOS:SCHEDULER_READY\n"
    static let migrationReadyMarker: StaticString =
        "SWIFTOS:EL0_MIGRATION_PROVEN\n"
    static let capabilitySystemCallNumber: UInt64 = 2
    static let fileSystemCapability: UInt64 = 1 << 0

    private static let maximumProcessorCount = 4
    private static let maximumThreadCount =
        KernelEL0AddressSpaceMappings.threadCapacity
    private static let processIdentifier: UInt32 = 1
    private static let guardPageCount: UInt64 = 1
    private static let threadPointerOffset: UInt64 = 0x100

    private nonisolated(unsafe) static var activeScheduler:
        PreemptiveEL0Scheduler?
    private nonisolated(unsafe) static var activeConsole: EarlyConsole?
    private nonisolated(unsafe) static var schedulerLockWord: UInt32 = 0
    private nonisolated(unsafe) static var publishedProcessorCount: UInt64 = 0
    private nonisolated(unsafe) static var timerPeriodTicks: UInt64 = 0
    private nonisolated(unsafe) static var processor0TimerStarted = false
    private nonisolated(unsafe) static var processor1TimerStarted = false
    private nonisolated(unsafe) static var processor2TimerStarted = false
    private nonisolated(unsafe) static var processor3TimerStarted = false
    private nonisolated(unsafe) static var processor1RestartEpoch: UInt64 = 0
    private nonisolated(unsafe) static var processor2RestartEpoch: UInt64 = 0
    private nonisolated(unsafe) static var processor3RestartEpoch: UInt64 = 0
    private nonisolated(unsafe) static var el0MarkerWritten = false
    private nonisolated(unsafe) static var threadsMarkerWritten = false
    private nonisolated(unsafe) static var preemptionMarkerWritten = false
    private nonisolated(unsafe) static var migrationMarkerWritten = false
    private nonisolated(unsafe) static var reportProcessorMarkerMask: UInt64 = 0
    private nonisolated(unsafe) static var timerProcessorMarkerMask: UInt64 = 0
    private nonisolated(unsafe) static var externalSystemCallHook:
        KernelEL0ExternalSystemCallHook?
    private nonisolated(unsafe) static var capabilityMarkerWritten = false
    private nonisolated(unsafe) static var externalCallMarkerWritten = false

    /// Installs one extension before CPU0 publishes the scheduler. Calls run
    /// from processor-local synchronous exception context with IRQs masked;
    /// the adapter must provide its own shared-state serialization.
    static func installExternalSystemCallHook(
        _ hook: KernelEL0ExternalSystemCallHook
    ) -> Bool {
        guard activeScheduler == nil, externalSystemCallHook == nil else {
            return false
        }
        externalSystemCallHook = hook
        return true
    }

    /// Describes the exact high-VA aliases root startup must add to its final
    /// page-table layout. The text entry preserves its offset within the linked
    /// physical user-text section; each stack has a separate unmapped guard.
    static func addressSpaceMappings() -> KernelEL0AddressSpaceMappings? {
        let physicalText = KernelLinkerLayout.userText
        let physicalReadOnlyData = KernelLinkerLayout.userReadOnlyData
        guard let userText = mapping(
                  physical: physicalText,
                  virtualBaseAddress: userTextVirtualBase,
                  role: .userText
              ),
              KernelLinkerLayout.userEntryPhysicalAddress
                >= physicalText.start,
              KernelLinkerLayout.userEntryPhysicalAddress < physicalText.end,
              let entryOffset = subtracting(
                  KernelLinkerLayout.userEntryPhysicalAddress,
                  physicalText.start
              ),
              let userEntryAddress = adding(
                  userTextVirtualBase,
                  entryOffset
              )
        else {
            return nil
        }

        let readOnlyData: FinalMappingRegion?
        if physicalReadOnlyData.length == 0 {
            readOnlyData = nil
        } else {
            guard let virtualBaseAddress = userReadOnlyDataVirtualBase,
                  let mapping = mapping(
                physical: physicalReadOnlyData,
                virtualBaseAddress: virtualBaseAddress,
                role: .userReadOnlyData
            ) else {
                return nil
            }
            readOnlyData = mapping
        }

        guard let thread0 = threadMapping(at: 0),
              let thread1 = threadMapping(at: 1),
              let thread2 = threadMapping(at: 2),
              let thread3 = threadMapping(at: 3),
              let thread4 = threadMapping(at: 4)
        else {
            return nil
        }

        return KernelEL0AddressSpaceMappings(
            userText: userText,
            userReadOnlyData: readOnlyData,
            userEntryAddress: userEntryAddress,
            thread0: thread0,
            thread1: thread1,
            thread2: thread2,
            thread3: thread3,
            thread4: thread4
        )
    }

    private static func threadMapping(
        at index: Int
    ) -> KernelEL0ThreadAddressSpaceMapping? {
        guard index >= 0,
              index < maximumThreadCount,
              let physical = KernelLinkerLayout.userStack(at: index),
              let scaled = multiplying(
                  UInt64(index),
                  userStackVirtualStride
              ),
              let virtualBase = adding(
                  firstUserStackVirtualBase,
                  scaled
              ),
              virtualBase >= MemoryPageGeometry.pageSize,
              let stack = mapping(
                  physical: physical,
                  virtualBaseAddress: virtualBase,
                  role: .userData
              ),
              let guardRegion = FinalGuardRegion(
                  virtualBaseAddress:
                    virtualBase - MemoryPageGeometry.pageSize,
                  pageCount: guardPageCount
              ),
              let threadPointer = adding(
                  virtualBase,
                  threadPointerOffset
              )
        else {
            return nil
        }
        return KernelEL0ThreadAddressSpaceMapping(
            stack: stack,
            guardRegion: guardRegion,
            stackTop: stack.virtualEndAddress,
            threadPointer: threadPointer
        )
    }

    /// Publishes one shared queue with one more runnable context than managed
    /// processors, leases CPU0's initial context, then releases the secondary
    /// processors into the same EL0 address space. Each processor arms only its
    /// own physical timer after its first accepted report.
    static func launch(
        console: EarlyConsole,
        mappings: KernelEL0AddressSpaceMappings,
        processorCount: Int,
        timerPeriodTicks requestedTimerPeriodTicks: UInt64
    ) -> Never {
        let threadCount = processorCount + 1
        guard activeScheduler == nil,
              processorCount > 0,
              processorCount <= maximumProcessorCount,
              threadCount <= maximumThreadCount,
              requestedTimerPeriodTicks > 0,
              addressSpaceMappings() == mappings,
              let schedulerStorage = schedulerStorage(),
              let scratchFrame = launchScratchFrame(),
              prepareBootstraps(
                  schedulerStorage.bootstraps,
                  count: threadCount,
                  mappings: mappings
              ),
              var scheduler = PreemptiveEL0Scheduler(
                  threadStorage: schedulerStorage.threads,
                  currentIndexStorage: schedulerStorage.currentIndices,
                  reportStorage: schedulerStorage.reports,
                  processorCount: processorCount,
                  processIdentifier: processIdentifier,
                  userEntryAddress: mappings.userEntryAddress,
                  threads: UnsafeBufferPointer(
                      start: schedulerStorage.bootstraps.baseAddress,
                      count: threadCount
                  )
              ),
              scheduler.installInitialContext(on: 0, in: scratchFrame),
              let initial = launchContext(from: scratchFrame)
        else {
            console.write("SWIFTOS:PANIC:EL0_SETUP\n")
            parkForever()
        }

        smpStoreRelease(&publishedProcessorCount, 0)
        activeConsole = console
        activeScheduler = scheduler
        timerPeriodTicks = requestedTimerPeriodTicks
        resetProcessorTimerState()
        processor1RestartEpoch = 0
        processor2RestartEpoch = 0
        processor3RestartEpoch = 0
        el0MarkerWritten = false
        threadsMarkerWritten = false
        preemptionMarkerWritten = false
        migrationMarkerWritten = false
        reportProcessorMarkerMask = 0
        timerProcessorMarkerMask = 0
        capabilityMarkerWritten = false
        externalCallMarkerWritten = false

        // Configuration may have inherited an earlier timer proof hook. Stop
        // it before publishing these noncapturing runtime callbacks.
        InterruptSubsystem.stopPhysicalTimer()
        guard InterruptSubsystem.setTimerInterruptHook(
                  swiftOSKernelEL0TimerHook
              ),
              InterruptSubsystem.setSynchronousExceptionHook(
                  swiftOSKernelEL0SynchronousHook
              )
        else {
            console.write("SWIFTOS:PANIC:EL0_CPU0_HOOKS\n")
            parkForever()
        }
        console.write(schedulerReadyMarker)
        writeProcessorOnlineMarker(0)
        smpStoreRelease(&publishedProcessorCount, UInt64(processorCount))
        smpSendEvent()

        AArch64.enterEL0(
            entryAddress: initial.entryAddress,
            stackPointer: initial.stackPointer,
            argument: initial.argument,
            threadPointer: initial.threadPointer
        )
    }

    /// Keeps a prepared secondary restart-aware until CPU0 release-publishes
    /// the scheduler, then installs processor-local hooks and leases exactly
    /// one context before entering EL0.
    static func waitForSecondaryLaunch(
        contextID: UInt64,
        observedRestartEpoch: inout UInt64
    ) -> Never {
        guard contextID > 0,
              contextID < UInt64(maximumProcessorCount),
              contextID <= UInt64(Int.max)
        else {
            parkForever()
        }
        let processor = Int(contextID)
        while true {
            _ = SMPKernelRestartRendezvous.checkpoint(
                logicalProcessorID: contextID,
                observedEpoch: &observedRestartEpoch
            )
            let count = smpLoadAcquire(&publishedProcessorCount)
            guard count > contextID,
                  count <= UInt64(maximumProcessorCount)
            else {
                AArch64.waitForEvent()
                continue
            }

            setRestartEpoch(observedRestartEpoch, on: processor)
            InterruptSubsystem.stopPhysicalTimer()
            guard InterruptSubsystem.setTimerInterruptHook(
                      swiftOSKernelEL0TimerHook
                  ),
                  InterruptSubsystem.setSynchronousExceptionHook(
                      swiftOSKernelEL0SynchronousHook
                  ),
                  let initial = takeInitialContext(on: processor)
            else {
                activeConsole?.write("SWIFTOS:PANIC:EL0_SECONDARY_SETUP\n")
                parkForever()
            }
            writeProcessorOnlineMarker(processor)
            AArch64.enterEL0(
                entryAddress: initial.entryAddress,
                stackPointer: initial.stackPointer,
                argument: initial.argument,
                threadPointer: initial.threadPointer
            )
        }
    }

    fileprivate static func handleTimerInterrupt(
        _ rawFrame: UnsafeMutableRawPointer
    ) {
        guard let processor = currentProcessorIndex() else {
            haltFromException("SWIFTOS:PANIC:EL0_BAD_CPU\n")
        }
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        // The scheduler remains user-preemptive, never kernel-preemptive. A
        // timer arriving in EL1 is rearmed by the interrupt subsystem only.
        guard frame.pointee.cameFromLowerExceptionLevel else { return }
        if serviceRestartRequestIfNeeded(
            on: processor,
            frame: rawFrame
        ) {
            return
        }
        let interruptState = lockScheduler()
        guard var scheduler = activeScheduler,
              scheduler.handleTimerInterrupt(
                  on: processor,
                  frame: rawFrame
              ) else {
            unlockScheduler(restoring: interruptState)
            haltFromException("SWIFTOS:PANIC:EL0_PREEMPT\n")
        }
        activeScheduler = scheduler
        writeTimerProcessorMarkerLocked(processor)
        writeEvidenceMarkersLocked(for: scheduler.evidence)
        unlockScheduler(restoring: interruptState)
    }

    fileprivate static func handleSynchronousException(
        _ rawFrame: UnsafeMutableRawPointer
    ) -> UInt64 {
        guard let processor = currentProcessorIndex() else {
            return 0
        }
        let interruptState = lockScheduler()
        guard var scheduler = activeScheduler,
              scheduler.activeThreadIdentifier(on: processor) != nil
        else {
            unlockScheduler(restoring: interruptState)
            return 0
        }
        let disposition = scheduler.handleReportSystemCall(
            on: processor,
            frame: rawFrame
        )
        activeScheduler = scheduler
        if disposition == .reportAccepted {
            writeReportProcessorMarkerLocked(processor)
            writeEvidenceMarkersLocked(for: scheduler.evidence)
            guard startTimerIfNeededLocked(on: processor) else {
                unlockScheduler(restoring: interruptState)
                return 0
            }
            unlockScheduler(restoring: interruptState)
            return 1
        }

        guard disposition == .unsupported else {
            unlockScheduler(restoring: interruptState)
            return 0
        }
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        if frame.pointee.x8 == capabilitySystemCallNumber {
            if !capabilityMarkerWritten {
                capabilityMarkerWritten = true
                activeConsole?.write("SWIFTOS:EL0_CAPABILITY_QUERY\n")
            }
            frame.pointee.x0 = externalSystemCallHook == nil
                ? 0 : fileSystemCapability
            unlockScheduler(restoring: interruptState)
            return 1
        }
        guard let hook = externalSystemCallHook else {
            unlockScheduler(restoring: interruptState)
            return 0
        }
        if !externalCallMarkerWritten {
            externalCallMarkerWritten = true
            activeConsole?.write("SWIFTOS:EL0_EXTERNAL_SYSCALL\n")
        }
        // The filesystem adapter owns a separate serialization boundary. Do
        // not retain the run-queue lock while it touches transport state.
        unlockScheduler(restoring: interruptState)
        return hook(rawFrame)
    }

    private struct SchedulerStorage {
        let threads: UnsafeMutableBufferPointer<ScheduledThread>
        let reports: UnsafeMutableBufferPointer<EL0ThreadReportRecord>
        let bootstraps: UnsafeMutableBufferPointer<EL0ThreadBootstrap>
        let currentIndices: UnsafeMutableBufferPointer<Int32>
    }

    private static func schedulerStorage() -> SchedulerStorage? {
        let scheduledThreadAddress = KernelLinkerLayout.schedulerThreads
        let currentIndexAddress = KernelLinkerLayout.schedulerCurrentIndices
        let schedulerPageByteCount: UInt64 = 4_096
        let threadBytes = UInt64(
            maximumThreadCount * MemoryLayout<ScheduledThread>.stride
        )
        let reportBytes = UInt64(
            maximumThreadCount * MemoryLayout<EL0ThreadReportRecord>.stride
        )
        let bootstrapBytes = UInt64(
            maximumThreadCount * MemoryLayout<EL0ThreadBootstrap>.stride
        )

        guard scheduledThreadAddress != 0,
              currentIndexAddress != 0,
              let threadEnd = adding(
                  scheduledThreadAddress,
                  threadBytes
              ),
              let reportAddress = alignedAddress(
                  after: threadEnd,
                  alignment: MemoryLayout<EL0ThreadReportRecord>.alignment
              ),
              let reportEnd = adding(reportAddress, reportBytes),
              let bootstrapAddress = alignedAddress(
                  after: reportEnd,
                  alignment: MemoryLayout<EL0ThreadBootstrap>.alignment
              ),
              let bootstrapOffset = subtracting(
                  bootstrapAddress,
                  scheduledThreadAddress
              ),
              bootstrapOffset <= schedulerPageByteCount,
              bootstrapBytes
                <= schedulerPageByteCount - bootstrapOffset,
              let scheduledThreadPointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(scheduledThreadAddress)
              )?.assumingMemoryBound(to: ScheduledThread.self),
              let reportPointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(reportAddress)
              )?.assumingMemoryBound(to: EL0ThreadReportRecord.self),
              let bootstrapPointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(bootstrapAddress)
              )?.assumingMemoryBound(to: EL0ThreadBootstrap.self),
              let currentIndexPointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(currentIndexAddress)
              )?.assumingMemoryBound(to: Int32.self)
        else {
            return nil
        }

        return SchedulerStorage(
            threads: UnsafeMutableBufferPointer(
                start: scheduledThreadPointer,
                count: maximumThreadCount
            ),
            reports: UnsafeMutableBufferPointer(
                start: reportPointer,
                count: maximumThreadCount
            ),
            bootstraps: UnsafeMutableBufferPointer(
                start: bootstrapPointer,
                count: maximumThreadCount
            ),
            currentIndices: UnsafeMutableBufferPointer(
                start: currentIndexPointer,
                count: maximumProcessorCount
            )
        )
    }

    private static func launchScratchFrame() -> UnsafeMutableRawPointer? {
        guard let address = KernelLinkerLayout.launchScratchContextAddress(
                  frameByteCount: AArch64ExceptionFrame.byteCount
              )
        else {
            return nil
        }
        return UnsafeMutableRawPointer(bitPattern: UInt(address))
    }

    private static func prepareBootstraps(
        _ storage: UnsafeMutableBufferPointer<EL0ThreadBootstrap>,
        count: Int,
        mappings: KernelEL0AddressSpaceMappings
    ) -> Bool {
        guard count > 0,
              count <= storage.count,
              count <= maximumThreadCount
        else {
            return false
        }
        var index = 0
        while index < count {
            guard let mapping = mappings.thread(at: index),
                  let contextAddress = KernelLinkerLayout
                    .threadContextAddress(
                        at: index,
                        frameByteCount: AArch64ExceptionFrame.byteCount
                    )
            else {
                return false
            }
            storage[index] = EL0ThreadBootstrap(
                identifier: UInt32(index + 1),
                contextAddress: contextAddress,
                userStackTop: mapping.stackTop,
                threadPointer: mapping.threadPointer
            )
            index += 1
        }
        return true
    }

    private struct EL0LaunchContext {
        let entryAddress: UInt64
        let stackPointer: UInt64
        let argument: UInt64
        let threadPointer: UInt64
    }

    private static func launchContext(
        from rawFrame: UnsafeMutableRawPointer
    ) -> EL0LaunchContext? {
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        guard frame.pointee.exceptionLink != 0,
              frame.pointee.exceptionLink & 3 == 0,
              frame.pointee.stackPointerEL0 != 0,
              frame.pointee.stackPointerEL0 & 0xf == 0,
              frame.pointee.x0 != 0,
              frame.pointee.threadPointerEL0 != 0
        else {
            return nil
        }
        return EL0LaunchContext(
            entryAddress: frame.pointee.exceptionLink,
            stackPointer: frame.pointee.stackPointerEL0,
            argument: frame.pointee.x0,
            threadPointer: frame.pointee.threadPointerEL0
        )
    }

    private static func takeInitialContext(
        on processor: Int
    ) -> EL0LaunchContext? {
        let interruptState = lockScheduler()
        defer { unlockScheduler(restoring: interruptState) }
        guard let scratchFrame = launchScratchFrame(),
              var scheduler = activeScheduler,
              scheduler.installInitialContext(
                  on: processor,
                  in: scratchFrame
              ),
              let initial = launchContext(from: scratchFrame)
        else {
            return nil
        }
        activeScheduler = scheduler
        return initial
    }

    private static func mapping(
        physical: LinkerRegion,
        virtualBaseAddress: UInt64,
        role: MemoryRegionRole
    ) -> FinalMappingRegion? {
        guard physical.length > 0,
              MemoryPageGeometry.isPageAligned(physical.start),
              let alignedEnd = MemoryPageGeometry.alignUp(physical.end),
              alignedEnd > physical.start
        else {
            return nil
        }
        return FinalMappingRegion(
            virtualBaseAddress: virtualBaseAddress,
            physicalBaseAddress: physical.start,
            byteCount: alignedEnd - physical.start,
            role: role
        )
    }

    /// Called only while `schedulerLockWord` is held.
    private static func writeEvidenceMarkersLocked(
        for evidence: EL0SchedulingEvidence
    ) {
        if !el0MarkerWritten,
           evidence.reportingThreadCount > 0 {
            el0MarkerWritten = true
            activeConsole?.write(el0ReadyMarker)
        }
        if !threadsMarkerWritten, evidence.allThreadsReported {
            threadsMarkerWritten = true
            activeConsole?.write(threadsReadyMarker)
        }
        if !preemptionMarkerWritten,
           evidence.demonstratesPreemptiveMultithreading {
            preemptionMarkerWritten = true
            activeConsole?.write(preemptionReadyMarker)
            activeConsole?.write(PreemptiveEL0Scheduler.evidenceMarker)
        }
        if !migrationMarkerWritten,
           evidence.demonstratesCrossProcessorMigration,
           evidence.demonstratesPreemptiveMultithreading {
            migrationMarkerWritten = true
            activeConsole?.write(migrationReadyMarker)
        }
    }

    private static func writeProcessorOnlineMarker(_ processor: Int) {
        switch processor {
        case 0: activeConsole?.write("SWIFTOS:EL0_CPU0_ONLINE\n")
        case 1: activeConsole?.write("SWIFTOS:EL0_CPU1_ONLINE\n")
        case 2: activeConsole?.write("SWIFTOS:EL0_CPU2_ONLINE\n")
        case 3: activeConsole?.write("SWIFTOS:EL0_CPU3_ONLINE\n")
        default: activeConsole?.write("SWIFTOS:PANIC:EL0_BAD_CPU\n")
        }
    }

    /// Called only while `schedulerLockWord` is held.
    private static func writeReportProcessorMarkerLocked(_ processor: Int) {
        let bit = UInt64(1) << UInt64(processor)
        guard reportProcessorMarkerMask & bit == 0 else { return }
        reportProcessorMarkerMask |= bit
        switch processor {
        case 0: activeConsole?.write("SWIFTOS:EL0_CPU0_REPORT\n")
        case 1: activeConsole?.write("SWIFTOS:EL0_CPU1_REPORT\n")
        case 2: activeConsole?.write("SWIFTOS:EL0_CPU2_REPORT\n")
        case 3: activeConsole?.write("SWIFTOS:EL0_CPU3_REPORT\n")
        default: break
        }
    }

    /// Called only while `schedulerLockWord` is held.
    private static func writeTimerProcessorMarkerLocked(_ processor: Int) {
        let bit = UInt64(1) << UInt64(processor)
        guard timerProcessorMarkerMask & bit == 0 else { return }
        timerProcessorMarkerMask |= bit
        switch processor {
        case 0: activeConsole?.write("SWIFTOS:EL0_CPU0_TIMER_IRQ\n")
        case 1: activeConsole?.write("SWIFTOS:EL0_CPU1_TIMER_IRQ\n")
        case 2: activeConsole?.write("SWIFTOS:EL0_CPU2_TIMER_IRQ\n")
        case 3: activeConsole?.write("SWIFTOS:EL0_CPU3_TIMER_IRQ\n")
        default: break
        }
    }

    /// Called only while `schedulerLockWord` is held.
    private static func startTimerIfNeededLocked(on processor: Int) -> Bool {
        if timerStarted(on: processor) { return true }
        setTimerStarted(true, on: processor)
        guard InterruptSubsystem.startPhysicalTimer(
                  periodTicks: timerPeriodTicks,
                  unmaskIRQs: false
              )
        else {
            setTimerStarted(false, on: processor)
            return false
        }
        return true
    }

    private static func timerStarted(on processor: Int) -> Bool {
        switch processor {
        case 0: return processor0TimerStarted
        case 1: return processor1TimerStarted
        case 2: return processor2TimerStarted
        case 3: return processor3TimerStarted
        default: return false
        }
    }

    private static func setTimerStarted(_ started: Bool, on processor: Int) {
        switch processor {
        case 0: processor0TimerStarted = started
        case 1: processor1TimerStarted = started
        case 2: processor2TimerStarted = started
        case 3: processor3TimerStarted = started
        default: break
        }
    }

    private static func resetProcessorTimerState() {
        processor0TimerStarted = false
        processor1TimerStarted = false
        processor2TimerStarted = false
        processor3TimerStarted = false
    }

    private static func currentProcessorIndex() -> Int? {
        let raw = AArch64.logicalProcessorID
        guard raw < UInt64(maximumProcessorCount),
              raw <= UInt64(Int.max)
        else {
            return nil
        }
        return Int(raw)
    }

    private static func setRestartEpoch(
        _ epoch: UInt64,
        on processor: Int
    ) {
        switch processor {
        case 1: processor1RestartEpoch = epoch
        case 2: processor2RestartEpoch = epoch
        case 3: processor3RestartEpoch = epoch
        default: break
        }
    }

    /// Saves and releases the live lease under the scheduler lock, then drops
    /// that lock before CPU_OFF. If firmware returns, the processor safely
    /// acquires any ready context and rearms its local timer. A processor that
    /// powered off leaves no `.running` queue owner behind.
    private static func serviceRestartRequestIfNeeded(
        on processor: Int,
        frame rawFrame: UnsafeMutableRawPointer
    ) -> Bool {
        guard processor > 0,
              SMPKernelRestartRendezvous.requestIsPending(
                  after: restartEpoch(on: processor)
              )
        else {
            return false
        }

        var interruptState = lockScheduler()
        guard var scheduler = activeScheduler,
              scheduler.relinquishProcessor(
                  on: processor,
                  frame: rawFrame
              )
        else {
            unlockScheduler(restoring: interruptState)
            haltFromException("SWIFTOS:PANIC:EL0_RESTART_RELEASE\n")
        }
        activeScheduler = scheduler
        unlockScheduler(restoring: interruptState)

        _ = checkpointRestart(on: processor)

        // Reaching this line means CPU_OFF did not power down the processor.
        // Its prior context is already ready and may have migrated elsewhere.
        interruptState = lockScheduler()
        guard var resumedScheduler = activeScheduler,
              resumedScheduler.installInitialContext(
                  on: processor,
                  in: rawFrame
              )
        else {
            unlockScheduler(restoring: interruptState)
            haltFromException("SWIFTOS:PANIC:EL0_RESTART_RESUME\n")
        }
        activeScheduler = resumedScheduler
        guard InterruptSubsystem.startPhysicalTimer(
                  periodTicks: timerPeriodTicks,
                  unmaskIRQs: false
              )
        else {
            _ = resumedScheduler.relinquishProcessor(
                on: processor,
                frame: rawFrame
            )
            activeScheduler = resumedScheduler
            unlockScheduler(restoring: interruptState)
            haltFromException("SWIFTOS:PANIC:EL0_RESTART_TIMER\n")
        }
        unlockScheduler(restoring: interruptState)
        return true
    }

    private static func restartEpoch(on processor: Int) -> UInt64 {
        switch processor {
        case 1: return processor1RestartEpoch
        case 2: return processor2RestartEpoch
        case 3: return processor3RestartEpoch
        default: return 0
        }
    }

    private static func checkpointRestart(
        on processor: Int
    ) -> SMPKernelRestartCheckpointResult {
        let logicalProcessorID = UInt64(processor)
        switch processor {
        case 1:
            return SMPKernelRestartRendezvous.checkpoint(
                logicalProcessorID: logicalProcessorID,
                observedEpoch: &processor1RestartEpoch
            )
        case 2:
            return SMPKernelRestartRendezvous.checkpoint(
                logicalProcessorID: logicalProcessorID,
                observedEpoch: &processor2RestartEpoch
            )
        case 3:
            return SMPKernelRestartRendezvous.checkpoint(
                logicalProcessorID: logicalProcessorID,
                observedEpoch: &processor3RestartEpoch
            )
        default:
            return .invalidContext
        }
    }

    private static func lockScheduler() -> UInt64 {
        withUnsafeMutablePointer(to: &schedulerLockWord) { word in
            AArch64.acquireInterruptSafeLock(word)
        }
    }

    private static func unlockScheduler(restoring interruptState: UInt64) {
        withUnsafeMutablePointer(to: &schedulerLockWord) { word in
            AArch64.releaseInterruptSafeLock(
                word,
                restoring: interruptState
            )
        }
    }

    private static func alignedAddress(
        after address: UInt64,
        alignment: Int
    ) -> UInt64? {
        guard alignment > 0,
              alignment.nonzeroBitCount == 1
        else {
            return nil
        }
        let mask = UInt64(alignment - 1)
        guard address <= UInt64.max - mask else { return nil }
        return (address + mask) & ~mask
    }

    private static func adding(_ left: UInt64, _ right: UInt64) -> UInt64? {
        guard right <= UInt64.max - left else { return nil }
        return left + right
    }

    private static func subtracting(_ left: UInt64, _ right: UInt64) -> UInt64? {
        guard left >= right else { return nil }
        return left - right
    }

    private static func multiplying(_ left: UInt64, _ right: UInt64) -> UInt64? {
        guard left == 0 || right <= UInt64.max / left else { return nil }
        return left * right
    }

    private static func haltFromException(_ marker: StaticString) -> Never {
        activeConsole?.write(marker)
        InterruptSubsystem.stopPhysicalTimer()
        parkForever()
    }

    private static func parkForever() -> Never {
        AArch64.disableIRQs()
        while true {
            AArch64.waitForEvent()
        }
    }
}

/// Top-level functions satisfy `@convention(c)` without capturing runtime
/// state. Every processor reaches the same runtime through its processor-local
/// hook, while the runtime serializes shared scheduler state with one IRQ-safe
/// lock.
@_cdecl("swiftos_kernel_el0_timer_hook")
func swiftOSKernelEL0TimerHook(_ rawFrame: UnsafeMutableRawPointer) {
    KernelEL0Runtime.handleTimerInterrupt(rawFrame)
}

@_cdecl("swiftos_kernel_el0_synchronous_hook")
func swiftOSKernelEL0SynchronousHook(
    _ rawFrame: UnsafeMutableRawPointer
) -> UInt64 {
    KernelEL0Runtime.handleSynchronousException(rawFrame)
}
