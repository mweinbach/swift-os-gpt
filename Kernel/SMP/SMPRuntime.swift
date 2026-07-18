private nonisolated(unsafe) var publishedProcessorStateBase:
    UnsafeMutablePointer<UInt64>?
private nonisolated(unsafe) var publishedProcessorStateCount: UInt64 = 0

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
        guard stateStorage.count >= plan.processorCount,
              reportStorage.count >= plan.secondaryProcessorCount,
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
        publishedProcessorStateBase = stateBase
        publishedProcessorStateCount = UInt64(plan.processorCount)
        archSMPPublicationBarrier()

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
        let rawValue: UInt64
        switch conduit {
        case .hypervisorCall:
            rawValue = archPSCIHVC(
                PSCIFunctionID.cpuOn64,
                target.affinity.rawValue,
                entryAddress,
                target.contextID
            )
        case .secureMonitorCall:
            rawValue = archPSCISMC(
                PSCIFunctionID.cpuOn64,
                target.affinity.rawValue,
                entryAddress,
                target.contextID
            )
        }
        return PSCIReturnValue(rawRegisterValue: rawValue)
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
    guard contextID > 0,
          contextID < publishedProcessorStateCount,
          let stateBase = publishedProcessorStateBase,
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

// Root-provided AArch64 veneers. HVC/SMC receive x0=function ID,
// x1=target affinity, x2=entry physical address, x3=context ID.
@_silgen_name("arch_psci_hvc")
private func archPSCIHVC(
    _ functionID: UInt64,
    _ argument0: UInt64,
    _ argument1: UInt64,
    _ argument2: UInt64
) -> UInt64

@_silgen_name("arch_psci_smc")
private func archPSCISMC(
    _ functionID: UInt64,
    _ argument0: UInt64,
    _ argument1: UInt64,
    _ argument2: UInt64
) -> UInt64

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

/// DMB ISHST after publishing the state-buffer registry and before CPU_ON.
@_silgen_name("arch_smp_publication_barrier")
private func archSMPPublicationBarrier()

/// A bounded nonblocking pause, expected to be one AArch64 YIELD instruction.
@_silgen_name("arch_smp_relax")
private func archSMPRelax()

/// Sends an event after online publication, expected to execute SEV.
@_silgen_name("arch_smp_send_event")
private func archSMPSendEvent()
