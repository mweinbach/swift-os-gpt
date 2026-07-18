struct KernelEL0AddressSpaceMappings: Equatable {
    let userText: FinalMappingRegion
    let userReadOnlyData: FinalMappingRegion?
    let firstUserStack: FinalMappingRegion
    let secondUserStack: FinalMappingRegion
    let firstUserStackGuard: FinalGuardRegion
    let secondUserStackGuard: FinalGuardRegion
    let userEntryAddress: UInt64
    let firstUserStackTop: UInt64
    let secondUserStackTop: UInt64
    let firstThreadPointer: UInt64
    let secondThreadPointer: UInt64
}

/// Binds the linker-owned userspace image and scheduler storage to the
/// exception subsystem. The final translation table must contain the mappings
/// returned by `addressSpaceMappings()` before `launch` is called.
///
/// Both threads remain pinned to CPU0. Secondary CPUs may run kernel work, but
/// sharing these contexts with them requires per-CPU scheduler state and locks.
enum KernelEL0Runtime {
    // All aliases stay in the upper half of the 39-bit TTBR0 address space.
    // They are intentionally far from identity-mapped kernel and MMIO ranges.
    static let userTextVirtualBase: UInt64 = 0x40_0000_0000
    static let firstUserStackVirtualBase: UInt64 = 0x40_1000_0000
    static let secondUserStackVirtualBase: UInt64 = 0x40_2000_0000

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

    private static let threadCount = 2
    private static let contextFrameCountIncludingLaunchScratch = 3
    private static let firstThreadIdentifier: UInt32 = 1
    private static let secondThreadIdentifier: UInt32 = 2
    private static let processIdentifier: UInt32 = 1
    private static let guardPageCount: UInt64 = 1
    private static let threadPointerOffset: UInt64 = 0x100

    private nonisolated(unsafe) static var activeScheduler:
        PreemptiveEL0Scheduler?
    private nonisolated(unsafe) static var activeConsole: EarlyConsole?
    private nonisolated(unsafe) static var timerPeriodTicks: UInt64 = 0
    private nonisolated(unsafe) static var timerStarted = false
    private nonisolated(unsafe) static var el0MarkerWritten = false
    private nonisolated(unsafe) static var threadsMarkerWritten = false
    private nonisolated(unsafe) static var preemptionMarkerWritten = false

    /// Describes the exact high-VA aliases root startup must add to its final
    /// page-table layout. The text entry preserves its offset within the linked
    /// physical user-text section; each stack has a separate unmapped guard.
    static func addressSpaceMappings() -> KernelEL0AddressSpaceMappings? {
        let physicalText = KernelLinkerLayout.userText
        let physicalReadOnlyData = KernelLinkerLayout.userReadOnlyData
        let physicalStack0 = KernelLinkerLayout.userStack0
        let physicalStack1 = KernelLinkerLayout.userStack1

        guard let userText = mapping(
                  physical: physicalText,
                  virtualBaseAddress: userTextVirtualBase,
                  role: .userText
              ),
              let firstStack = mapping(
                  physical: physicalStack0,
                  virtualBaseAddress: firstUserStackVirtualBase,
                  role: .userData
              ),
              let secondStack = mapping(
                  physical: physicalStack1,
                  virtualBaseAddress: secondUserStackVirtualBase,
                  role: .userData
              ),
              firstUserStackVirtualBase >= MemoryPageGeometry.pageSize,
              secondUserStackVirtualBase >= MemoryPageGeometry.pageSize,
              let firstGuard = FinalGuardRegion(
                  virtualBaseAddress: firstUserStackVirtualBase
                    - MemoryPageGeometry.pageSize,
                  pageCount: guardPageCount
              ),
              let secondGuard = FinalGuardRegion(
                  virtualBaseAddress: secondUserStackVirtualBase
                    - MemoryPageGeometry.pageSize,
                  pageCount: guardPageCount
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
              ),
              let firstThreadPointer = adding(
                  firstUserStackVirtualBase,
                  threadPointerOffset
              ),
              let secondThreadPointer = adding(
                  secondUserStackVirtualBase,
                  threadPointerOffset
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

        return KernelEL0AddressSpaceMappings(
            userText: userText,
            userReadOnlyData: readOnlyData,
            firstUserStack: firstStack,
            secondUserStack: secondStack,
            firstUserStackGuard: firstGuard,
            secondUserStackGuard: secondGuard,
            userEntryAddress: userEntryAddress,
            firstUserStackTop: firstStack.virtualEndAddress,
            secondUserStackTop: secondStack.virtualEndAddress,
            firstThreadPointer: firstThreadPointer,
            secondThreadPointer: secondThreadPointer
        )
    }

    /// Installs the two linker-backed scheduler contexts and enters thread one
    /// at EL0t. The timer is armed by the first valid report syscall, ensuring
    /// an EL1 timer IRQ cannot overwrite thread one before userspace starts.
    static func launch(
        console: EarlyConsole,
        mappings: KernelEL0AddressSpaceMappings,
        timerPeriodTicks requestedTimerPeriodTicks: UInt64
    ) -> Never {
        guard activeScheduler == nil,
              requestedTimerPeriodTicks > 0,
              addressSpaceMappings() == mappings,
              let schedulerStorage = schedulerStorage(),
              let scratchFrame = launchScratchFrame(),
              var scheduler = PreemptiveEL0Scheduler(
                  threadStorage: schedulerStorage.threads,
                  currentIndexStorage: schedulerStorage.currentIndices,
                  processIdentifier: processIdentifier,
                  userEntryAddress: mappings.userEntryAddress,
                  firstThread: EL0ThreadBootstrap(
                      identifier: firstThreadIdentifier,
                      contextAddress: schedulerStorage.firstContextAddress,
                      userStackTop: mappings.firstUserStackTop,
                      threadPointer: mappings.firstThreadPointer
                  ),
                  secondThread: EL0ThreadBootstrap(
                      identifier: secondThreadIdentifier,
                      contextAddress: schedulerStorage.secondContextAddress,
                      userStackTop: mappings.secondUserStackTop,
                      threadPointer: mappings.secondThreadPointer
                  )
              ),
              scheduler.installInitialContext(in: scratchFrame)
        else {
            console.write("SWIFTOS:PANIC:EL0_SETUP\n")
            parkForever()
        }

        let initialFrame = scratchFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        let initialEntry = initialFrame.pointee.exceptionLink
        let initialStack = initialFrame.pointee.stackPointerEL0
        let initialArgument = initialFrame.pointee.x0
        let initialThreadPointer = initialFrame.pointee.threadPointerEL0

        activeConsole = console
        activeScheduler = scheduler
        timerPeriodTicks = requestedTimerPeriodTicks
        timerStarted = false
        el0MarkerWritten = false
        threadsMarkerWritten = false
        preemptionMarkerWritten = false

        // Configuration may have inherited an earlier timer proof hook. Stop
        // it before publishing these noncapturing runtime callbacks.
        InterruptSubsystem.stopPhysicalTimer()
        InterruptSubsystem.setTimerInterruptHook(swiftOSKernelEL0TimerHook)
        InterruptSubsystem.setSynchronousExceptionHook(
            swiftOSKernelEL0SynchronousHook
        )
        console.write(schedulerReadyMarker)

        AArch64.enterEL0(
            entryAddress: initialEntry,
            stackPointer: initialStack,
            argument: initialArgument,
            threadPointer: initialThreadPointer
        )
    }

    fileprivate static func handleTimerInterrupt(
        _ rawFrame: UnsafeMutableRawPointer
    ) {
        let frame = rawFrame.assumingMemoryBound(
            to: AArch64ExceptionFrame.self
        )
        // The first implementation is intentionally CPU0/user-preemptive,
        // never kernel-preemptive. A timer arriving in EL1 is simply rearmed.
        guard frame.pointee.cameFromLowerExceptionLevel else { return }
        guard var scheduler = activeScheduler,
              scheduler.handleTimerInterrupt(frame: rawFrame)
        else {
            haltFromException("SWIFTOS:PANIC:EL0_PREEMPT\n")
        }
        activeScheduler = scheduler
        writeEvidenceMarkers(for: scheduler.evidence)
    }

    fileprivate static func handleSynchronousException(
        _ rawFrame: UnsafeMutableRawPointer
    ) -> UInt64 {
        guard var scheduler = activeScheduler else {
            return 0
        }
        let disposition = scheduler.handleReportSystemCall(frame: rawFrame)
        activeScheduler = scheduler
        guard disposition == .reportAccepted else {
            return 0
        }

        writeEvidenceMarkers(for: scheduler.evidence)
        if !timerStarted {
            // Mark the transition first so a future per-CPU nested IRQ path
            // cannot attempt to arm the shared physical timer twice.
            timerStarted = true
            guard InterruptSubsystem.startPhysicalTimer(
                periodTicks: timerPeriodTicks,
                unmaskIRQs: false
            ) else {
                timerStarted = false
                return 0
            }
        }
        return 1
    }

    private struct SchedulerStorage {
        let threads: UnsafeMutableBufferPointer<ScheduledThread>
        let currentIndices: UnsafeMutableBufferPointer<Int32>
        let firstContextAddress: UInt64
        let secondContextAddress: UInt64
    }

    private static func schedulerStorage() -> SchedulerStorage? {
        let contexts = KernelLinkerLayout.threadContexts
        let requiredContextBytes = UInt64(
            contextFrameCountIncludingLaunchScratch
                * AArch64ExceptionFrame.byteCount
        )
        let scheduledThreadAddress = KernelLinkerLayout.schedulerThreads
        let currentIndexAddress = KernelLinkerLayout.schedulerCurrentIndices

        guard contexts.length >= requiredContextBytes,
              contexts.start & 0xf == 0,
              scheduledThreadAddress != 0,
              currentIndexAddress != 0,
              scheduledThreadAddress
                & UInt64(MemoryLayout<ScheduledThread>.alignment - 1) == 0,
              currentIndexAddress
                & UInt64(MemoryLayout<Int32>.alignment - 1) == 0,
              let scheduledThreadPointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(scheduledThreadAddress)
              )?.assumingMemoryBound(to: ScheduledThread.self),
              let currentIndexPointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(currentIndexAddress)
              )?.assumingMemoryBound(to: Int32.self),
              let secondContextAddress = adding(
                  contexts.start,
                  UInt64(AArch64ExceptionFrame.byteCount)
              )
        else {
            return nil
        }

        return SchedulerStorage(
            threads: UnsafeMutableBufferPointer(
                start: scheduledThreadPointer,
                count: threadCount
            ),
            currentIndices: UnsafeMutableBufferPointer(
                start: currentIndexPointer,
                count: 1
            ),
            firstContextAddress: contexts.start,
            secondContextAddress: secondContextAddress
        )
    }

    private static func launchScratchFrame() -> UnsafeMutableRawPointer? {
        guard let offset = multiplying(
                  UInt64(AArch64ExceptionFrame.byteCount),
                  UInt64(threadCount)
              ),
              let address = adding(
                  KernelLinkerLayout.threadContexts.start,
                  offset
              )
        else {
            return nil
        }
        return UnsafeMutableRawPointer(bitPattern: UInt(address))
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

    private static func writeEvidenceMarkers(
        for evidence: EL0SchedulingEvidence
    ) {
        if !el0MarkerWritten,
           evidence.firstThread.reportCount > 0
            || evidence.secondThread.reportCount > 0 {
            el0MarkerWritten = true
            activeConsole?.write(el0ReadyMarker)
        }
        if !threadsMarkerWritten, evidence.bothThreadsReported {
            threadsMarkerWritten = true
            activeConsole?.write(threadsReadyMarker)
        }
        if !preemptionMarkerWritten,
           evidence.demonstratesPreemptiveMultithreading {
            preemptionMarkerWritten = true
            activeConsole?.write(preemptionReadyMarker)
            activeConsole?.write(PreemptiveEL0Scheduler.evidenceMarker)
        }
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
/// state. The mutable state itself remains in `KernelEL0Runtime` and is touched
/// only while CPU0 is executing an exception with IRQs masked.
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
