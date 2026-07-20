// Low three bits encode count - 1. Publishing one packed word means a
// secondary's acquire load happens before it derives or dereferences the state
// buffer; there is no separately raced Swift pointer/count registry.
private nonisolated(unsafe) var publishedProcessorStateRegistry: UInt64 = 0
// Zero means no request. CPU0 is the single request writer, so an incrementing
// epoch lets a secondary retry after a failed PSCI CPU_OFF without racing a
// stale request from an earlier activation attempt.
private nonisolated(unsafe) var publishedKernelRestartEpoch: UInt64 = 0
// Stored as PSCIConduit.rawValue + 1 so zero remains an unpublished sentinel.
private nonisolated(unsafe) var publishedKernelRestartConduit: UInt64 = 0

enum SMPKernelRestartRequestResult: Equatable {
    case noManagedSecondaries
    case requested(epoch: UInt64, managedSecondaryCount: Int)
    case invalidRegistry
}

enum SMPKernelRestartCheckpointResult: Equatable {
    case idle
    case invalidContext
    /// CPU_OFF is specified not to return on success. Any returned value is a
    /// failure, retained here so host tests and future diagnostics can classify
    /// the firmware response without weakening the CPU0 affinity proof.
    case shutdownReturned(PSCIReturnValue)
}

/// Transport-neutral, allocation-free rendezvous state shared by the boot CPU
/// and kernel-managed secondaries. Waiting secondaries observe release-store +
/// SEV directly; an EL0-owning secondary checks the epoch from its bounded timer
/// path and relinquishes its scheduler lease before calling `checkpoint`.
enum SMPKernelRestartRendezvous {
    static func request() -> SMPKernelRestartRequestResult {
        let registry = archSMPLoadAcquire(&publishedProcessorStateRegistry)
        guard registry != 0 else { return .noManagedSecondaries }
        let stateBaseAddress = registry & ~UInt64(0x7)
        let processorCount = Int((registry & 0x7) + 1)
        guard processorCount > 0,
              processorCount
                <= ProcessorStartupPlan.maximumOnlineProcessorCount,
              stateBaseAddress != 0,
              stateBaseAddress <= UInt64(UInt.max),
              stateBaseAddress & 0x7 == 0,
              UnsafeMutablePointer<UInt64>(
                  bitPattern: UInt(stateBaseAddress)
              ) != nil
        else {
            return .invalidRegistry
        }
        guard processorCount > 1 else {
            return .noManagedSecondaries
        }
        guard decodePublishedConduit() != nil else {
            return .invalidRegistry
        }

        let priorEpoch = archSMPLoadAcquire(&publishedKernelRestartEpoch)
        var nextEpoch = priorEpoch &+ 1
        if nextEpoch == 0 { nextEpoch = 1 }
        archSMPStoreRelease(&publishedKernelRestartEpoch, nextEpoch)
        archSMPSendEvent()
        return .requested(
            epoch: nextEpoch,
            managedSecondaryCount: processorCount - 1
        )
    }

    /// Lets a scheduled secondary save and relinquish its live context before
    /// entering the no-return checkpoint. CPU0 is the only epoch writer, so a
    /// matching acquire load and the subsequent checkpoint describe the same
    /// request unless a newer request supersedes it, which remains pending.
    static func requestIsPending(after observedEpoch: UInt64) -> Bool {
        let requestedEpoch = archSMPLoadAcquire(
            &publishedKernelRestartEpoch
        )
        return requestedEpoch != 0 && requestedEpoch != observedEpoch
    }

    /// Services at most one request epoch. The logical ID is the same dense
    /// context value established by the PSCI CPU_ON path. Success never returns
    /// because PSCI powers the calling processor off.
    static func checkpoint(
        logicalProcessorID: UInt64,
        observedEpoch: inout UInt64
    ) -> SMPKernelRestartCheckpointResult {
        let requestedEpoch = archSMPLoadAcquire(
            &publishedKernelRestartEpoch
        )
        guard requestedEpoch != 0,
              requestedEpoch != observedEpoch
        else {
            return .idle
        }
        observedEpoch = requestedEpoch

        let registry = archSMPLoadAcquire(&publishedProcessorStateRegistry)
        let stateBaseAddress = registry & ~UInt64(0x7)
        let processorCount = (registry & 0x7) + 1
        guard registry != 0,
              logicalProcessorID > 0,
              logicalProcessorID < processorCount,
              logicalProcessorID <= UInt64(Int.max),
              stateBaseAddress != 0,
              stateBaseAddress <= UInt64(UInt.max),
              let stateBase = UnsafeMutablePointer<UInt64>(
                  bitPattern: UInt(stateBaseAddress)
              ),
              let conduit = decodePublishedConduit()
        else {
            return .invalidContext
        }
        let stateAddress = stateBase.advanced(by: Int(logicalProcessorID))
        let state = ProcessorBootState(
            rawValue: archSMPLoadAcquire(stateAddress)
        )
        guard state == .online || state == .shutdownFailed else {
            return .invalidContext
        }

        archSMPStoreRelease(
            stateAddress,
            ProcessorBootState.stopping.rawValue
        )
        archSMPPrepareCPUOff()
        let response = PSCIReturnValue(
            rawRegisterValue: PSCIFirmware.call(
                conduit: conduit,
                functionID: PSCIFunctionID.cpuOff,
                argument0: 0
            )
        )
        archSMPStoreRelease(
            stateAddress,
            ProcessorBootState.shutdownFailed.rawValue
        )
        archSMPSendEvent()
        return .shutdownReturned(response)
    }

    private static func decodePublishedConduit() -> PSCIConduit? {
        let encoded = archSMPLoadAcquire(&publishedKernelRestartConduit)
        guard encoded > 0,
              encoded - 1 <= UInt64(UInt8.max)
        else { return nil }
        return PSCIConduit(rawValue: UInt8(encoded - 1))
    }
}

/// Executes a PSCI SMP startup plan. All buffers must have static or otherwise
/// kernel-lifetime storage because a secondary processor publishes through the
/// state buffer after CPU_ON transfers control to the entry veneer.
struct SMPRuntime {
    private let conduit: PSCIConduit
    private let plan: ProcessorStartupPlan
    private var stateStorage: UnsafeMutableBufferPointer<UInt64>
    private var reportStorage:
        UnsafeMutableBufferPointer<SecondaryProcessorStartReport>

    init?(
        conduit: PSCIConduit,
        plan: ProcessorStartupPlan,
        stateStorage: UnsafeMutableBufferPointer<UInt64>,
        reportStorage: UnsafeMutableBufferPointer<SecondaryProcessorStartReport>
    ) {
        guard plan.processorCount > 0,
              plan.processorCount
                <= ProcessorStartupPlan.maximumOnlineProcessorCount,
              stateStorage.count >= plan.configuration.resources.bootStates,
              reportStorage.count
                >= plan.configuration.resources.startupReports,
              let stateBase = stateStorage.baseAddress,
              UInt(bitPattern: stateBase) & 0x7 == 0
        else {
            return nil
        }
        self.conduit = conduit
        self.plan = plan
        self.stateStorage = stateStorage
        self.reportStorage = reportStorage

        var index = 0
        while index < stateStorage.count {
            stateStorage[index] = ProcessorBootState.absent.rawValue
            index += 1
        }
        index = 0
        while index < reportStorage.count {
            reportStorage[index] = .vacant
            index += 1
        }
    }

    func report(at index: Int) -> SecondaryProcessorStartReport? {
        guard index >= 0, index < plan.secondaryProcessorCount else {
            return nil
        }
        return reportStorage[index]
    }

    func processorState(
        logicalProcessorID: Int
    ) -> ProcessorBootState? {
        guard logicalProcessorID >= 0,
              logicalProcessorID < plan.processorCount,
              let stateBase = stateStorage.baseAddress
        else {
            return nil
        }
        return ProcessorBootState(
            rawValue: archSMPLoadAcquire(
                stateBase.advanced(by: logicalProcessorID)
            )
        )
    }

    /// `secondaryEntryPhysicalAddress` is passed verbatim as CPU_ON x2. It must
    /// be a nonzero, four-byte-aligned physical address executable with the
    /// secondary's initial MMU state. `pollLimit` bounds each acquire-load loop.
    mutating func startSecondaryProcessors(
        secondaryEntryPhysicalAddress: UInt64,
        pollLimit: UInt64
    ) -> SMPStartupResult {
        guard secondaryEntryPhysicalAddress != 0,
              secondaryEntryPhysicalAddress & 0x3 == 0
        else {
            return .invalidConfiguration(.invalidSecondaryEntryAddress)
        }
        guard pollLimit > 0 else {
            return .invalidConfiguration(.invalidPollLimit)
        }
        guard let stateBase = stateStorage.baseAddress else {
            return .invalidConfiguration(.invalidSecondaryEntryAddress)
        }

        var logicalID = 0
        while logicalID < plan.processorCount {
            archSMPStoreRelease(
                stateBase.advanced(by: logicalID),
                logicalID == 0
                    ? ProcessorBootState.online.rawValue
                    : ProcessorBootState.offline.rawValue
            )
            logicalID += 1
        }
        let registry = UInt64(UInt(bitPattern: stateBase))
            | UInt64(plan.processorCount - 1)
        archSMPStoreRelease(&publishedKernelRestartEpoch, 0)
        archSMPStoreRelease(
            &publishedKernelRestartConduit,
            UInt64(conduit.rawValue) + 1
        )
        archSMPStoreRelease(&publishedProcessorStateRegistry, registry)

        var onlineProcessorCount = 1
        var alreadyOnCount = 0
        var timedOutCount = 0
        var rejectedCount = 0
        var targetIndex = 0
        while targetIndex < plan.secondaryProcessorCount {
            guard let target = plan.secondaryProcessor(at: targetIndex) else {
                break
            }
            let stateAddress = stateBase.advanced(
                by: Int(target.logicalProcessorID)
            )
            archSMPStoreRelease(
                stateAddress,
                ProcessorBootState.starting.rawValue
            )

            let response = invokeCPUOn(
                target: target,
                entryAddress: secondaryEntryPhysicalAddress
            )
            switch response {
            case .success, .onPending:
                let wait = waitUntilOnline(
                    at: stateAddress,
                    pollLimit: pollLimit
                )
                if wait.online {
                    onlineProcessorCount += 1
                    reportStorage[targetIndex] = SecondaryProcessorStartReport(
                        target: target,
                        outcome: .online,
                        pollCount: wait.pollCount
                    )
                } else {
                    timedOutCount += 1
                    reportStorage[targetIndex] = SecondaryProcessorStartReport(
                        target: target,
                        outcome: .timedOut,
                        pollCount: wait.pollCount
                    )
                }
            case .alreadyOn:
                alreadyOnCount += 1
                archSMPStoreRelease(
                    stateAddress,
                    ProcessorBootState.firmwareAlreadyOn.rawValue
                )
                reportStorage[targetIndex] = SecondaryProcessorStartReport(
                    target: target,
                    outcome: .firmwareAlreadyOn,
                    pollCount: 0
                )
            case let failure:
                rejectedCount += 1
                archSMPStoreRelease(
                    stateAddress,
                    ProcessorBootState.failed.rawValue
                )
                reportStorage[targetIndex] = SecondaryProcessorStartReport(
                    target: target,
                    outcome: .rejected(failure),
                    pollCount: 0
                )
            }
            targetIndex += 1
        }

        return .completed(SMPStartupSummary(
            selectedProcessorCount: plan.processorCount,
            onlineProcessorCount: onlineProcessorCount,
            firmwareAlreadyOnCount: alreadyOnCount,
            timedOutCount: timedOutCount,
            rejectedCount: rejectedCount
        ))
    }

    private func invokeCPUOn(
        target: SecondaryProcessorTarget,
        entryAddress: UInt64
    ) -> PSCIReturnValue {
        PSCIReturnValue(
            rawRegisterValue: PSCIFirmware.call(
                conduit: conduit,
                functionID: PSCIFunctionID.cpuOn64,
                argument0: target.affinity.rawValue,
                argument1: entryAddress,
                argument2: target.contextID
            )
        )
    }

    private func waitUntilOnline(
        at stateAddress: UnsafeMutablePointer<UInt64>,
        pollLimit: UInt64
    ) -> (online: Bool, pollCount: UInt64) {
        var pollCount: UInt64 = 0
        while pollCount < pollLimit {
            pollCount += 1
            if archSMPLoadAcquire(stateAddress)
                == ProcessorBootState.online.rawValue {
                return (true, pollCount)
            }
            archSMPRelax()
        }
        // Do not overwrite STARTING here: a secondary may publish immediately
        // after the final load. The primary-owned report records the timeout.
        return (false, pollCount)
    }
}

/// Called by the secondary path after it has installed its stack and completed
/// any required per-CPU architectural setup. Returns the dense logical CPU ID,
/// or UInt64.max when x0 did not contain a valid pending context ID.
@_cdecl("swiftos_smp_publish_online")
func swiftOSSMPPublishOnline(_ contextID: UInt64) -> UInt64 {
    let registry = archSMPLoadAcquire(&publishedProcessorStateRegistry)
    let stateBaseAddress = registry & ~UInt64(0x7)
    let processorCount = (registry & 0x7) + 1
    guard registry != 0,
          contextID > 0,
          contextID < processorCount,
          stateBaseAddress <= UInt64(UInt.max),
          let stateBase = UnsafeMutablePointer<UInt64>(
              bitPattern: UInt(stateBaseAddress)
          ),
          contextID <= UInt64(Int.max)
    else {
        return UInt64.max
    }
    let stateAddress = stateBase.advanced(by: Int(contextID))
    guard archSMPLoadAcquire(stateAddress)
        == ProcessorBootState.starting.rawValue
    else {
        return UInt64.max
    }
    archSMPStoreRelease(stateAddress, ProcessorBootState.online.rawValue)
    archSMPSendEvent()
    return contextID
}

/// Shared release/acquire primitives for SMP subsystems that publish storage
/// before CPU_ON or completion evidence back to CPU0. Keeping these wrappers
/// beside the boot-state protocol gives every secondary runtime one memory-
/// ordering contract rather than duplicating architecture declarations.
@inline(__always)
func smpStoreRelease(
    _ address: UnsafeMutablePointer<UInt64>,
    _ value: UInt64
) {
    archSMPStoreRelease(address, value)
}

@inline(__always)
func smpLoadAcquire(
    _ address: UnsafePointer<UInt64>
) -> UInt64 {
    archSMPLoadAcquire(address)
}

@inline(__always)
func smpSendEvent() {
    archSMPSendEvent()
}

// STLR/LDAR give the online state contract release/acquire semantics.
@_silgen_name("arch_smp_store_release")
private func archSMPStoreRelease(
    _ address: UnsafeMutablePointer<UInt64>,
    _ value: UInt64
)

@_silgen_name("arch_smp_load_acquire")
private func archSMPLoadAcquire(
    _ address: UnsafePointer<UInt64>
) -> UInt64

/// A bounded nonblocking pause, expected to be one AArch64 YIELD instruction.
@_silgen_name("arch_smp_relax")
private func archSMPRelax()

/// Sends an event after online publication, expected to execute SEV.
@_silgen_name("arch_smp_send_event")
private func archSMPSendEvent()

/// Masks local exceptions, disables the local physical timer, and orders the
/// stopping-state publication before PSCI CPU_OFF.
@_silgen_name("arch_smp_prepare_cpu_off")
private func archSMPPrepareCPUOff()
