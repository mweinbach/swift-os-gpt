/// Binds device-tree topology and linker-owned early storage to the allocation-
/// free PSCI runtime. CPU0 reports evidence only after acquire-loading each
/// secondary's publication. Each secondary then consumes two affinity-pinned
/// Swift work slots and release-publishes deterministic completion evidence.
enum KernelSMP {
    static let onlineMarker: StaticString = "SWIFTOS:SMP_OK\n"
    static let workReadyMarker: StaticString = "SWIFTOS:SMP_WORK_OK\n"

    private static let topologyCapacity = 64
    private static let targetCapacity = 3
    private static let stateCapacity = 4
    private static let reportCapacity = 3
    private static let pollLimit: UInt64 = 10_000_000
    private static let workEvidenceTimeoutSeconds: UInt64 = 1
    private static let workEvidenceMaximumPollCount: UInt64 = 1_000_000_000

    /// Starts as many unique DT processors as are available, capped at four
    /// including CPU0. Returns true only when every selected secondary entered
    /// our veneer, published online with release semantics, and is now parked.
    static func start(platform: Platform, console: EarlyConsole) -> Bool {
        guard let managedProcessorCount = platform.processorCount(
                  limitedTo:
                    ProcessorStartupPlan.maximumOnlineProcessorCount
              ),
              storageLayoutIsValid(),
              let topologyStorage:
                UnsafeMutableBufferPointer<ProcessorDescription> = buffer(
                    at: KernelLinkerLayout.smpTopologyStorage,
                    count: topologyCapacity
                ),
              let targetStorage:
                UnsafeMutableBufferPointer<SecondaryProcessorTarget> = buffer(
                    at: KernelLinkerLayout.smpTargetStorage,
                    count: targetCapacity
                ),
              let stateStorage: UnsafeMutableBufferPointer<UInt64> = buffer(
                    at: KernelLinkerLayout.smpStateStorage,
                    count: stateCapacity
                ),
              let reportStorage:
                UnsafeMutableBufferPointer<SecondaryProcessorStartReport> = buffer(
                    at: KernelLinkerLayout.smpReportStorage,
                    count: reportCapacity
                ),
              var topology = ProcessorTopology(storage: topologyStorage)
        else {
            console.write("SWIFTOS:SMP_BAD_STORAGE\n")
            return false
        }

        var deviceTreeIndex = 0
        while deviceTreeIndex < topologyCapacity,
              let affinity = platform.processorAffinity(at: deviceTreeIndex) {
            switch topology.register(deviceTreeAffinity: affinity) {
            case .inserted, .duplicate:
                break
            case .conflictingDescription, .invalidAffinity, .capacityExhausted:
                console.write("SWIFTOS:SMP_BAD_TOPOLOGY\n")
                return false
            }
            deviceTreeIndex += 1
        }
        let resources = ProcessorBootResourceCapacity(
            topologyDescriptions: topologyStorage.count,
            secondaryTargets: targetStorage.count,
            bootStates: stateStorage.count,
            startupReports: reportStorage.count
        )
        guard topology.count > 0,
              let configuration = ProcessorBootConfiguration(
                  requestedProcessorLimit:
                    managedProcessorCount,
                  resources: resources
              ),
              let plan = ProcessorStartupPlan(
                  topology: topology,
                  bootMPIDR: AArch64.multiprocessorAffinity,
                  configuration: configuration,
                  targetStorage: targetStorage
              )
        else {
            console.write("SWIFTOS:SMP_BOOT_CPU_MISSING\n")
            return false
        }

        let conduit: PSCIConduit
        switch platform.firmwareCallConduit {
        case .hypervisorCall:
            conduit = .hypervisorCall
        case .secureMonitorCall:
            conduit = .secureMonitorCall
        case nil:
            console.write("SWIFTOS:SMP_NO_PSCI_METHOD\n")
            return false
        }
        guard var runtime = SMPRuntime(
            conduit: conduit,
            plan: plan,
            stateStorage: stateStorage,
            reportStorage: reportStorage
        ) else {
            console.write("SWIFTOS:SMP_BAD_STORAGE\n")
            return false
        }
        guard SecondaryProcessorWorkRuntime.configure(
                  processorCount: plan.processorCount
              )
        else {
            console.write("SWIFTOS:SMP_WORK_BAD_STORAGE\n")
            return false
        }

        let result = runtime.startSecondaryProcessors(
            secondaryEntryPhysicalAddress:
                AArch64.secondaryEntryPhysicalAddress,
            pollLimit: pollLimit
        )
        switch result {
        case .invalidConfiguration:
            console.write("SWIFTOS:SMP_BAD_CONFIG\n")
            return false
        case let .completed(summary):
            var reportIndex = 0
            var everySecondaryOnline = true
            while reportIndex < plan.secondaryProcessorCount {
                guard let report = runtime.report(at: reportIndex) else {
                    console.write("SWIFTOS:SMP_BAD_REPORT\n")
                    return false
                }
                switch report.outcome {
                case .online:
                    writeOnlineMarker(
                        logicalProcessorID:
                            report.target.logicalProcessorID,
                        console: console
                    )
                case .timedOut:
                    if SecondaryProcessorWorkRuntime.state(
                        logicalProcessorID:
                            Int(report.target.logicalProcessorID)
                    ) == .currentProcessorInitializationFailed {
                        console.write("SWIFTOS:SMP_CPU_LOCAL_INIT_FAILED\n")
                    }
                    console.write("SWIFTOS:SMP_TIMEOUT\n")
                    everySecondaryOnline = false
                case .firmwareAlreadyOn:
                    console.write("SWIFTOS:SMP_ALREADY_ON\n")
                    everySecondaryOnline = false
                case .rejected:
                    console.write("SWIFTOS:SMP_PSCI_REJECTED\n")
                    everySecondaryOnline = false
                }
                reportIndex += 1
            }

            guard everySecondaryOnline,
                  summary.onlineProcessorCount
                    == summary.selectedProcessorCount,
                  summary.firmwareAlreadyOnCount == 0,
                  summary.timedOutCount == 0,
                  summary.rejectedCount == 0
            else {
                return false
            }
            let counterFrequency = AArch64.counterFrequency
            guard counterFrequency > 0,
                  counterFrequency
                    <= UInt64.max / workEvidenceTimeoutSeconds
            else {
                console.write("SWIFTOS:SMP_WORK_BAD_CLOCK\n")
                return false
            }
            let workEvidenceTimeoutTicks = counterFrequency
                * workEvidenceTimeoutSeconds
            reportIndex = 0
            while reportIndex < plan.secondaryProcessorCount {
                guard let report = runtime.report(at: reportIndex) else {
                    console.write("SWIFTOS:SMP_BAD_REPORT\n")
                    return false
                }
                let logicalProcessorID = Int(
                    report.target.logicalProcessorID
                )
                switch SecondaryProcessorWorkRuntime.waitForEvidence(
                    logicalProcessorID: logicalProcessorID,
                    timeoutTicks: workEvidenceTimeoutTicks,
                    maximumPollCount: workEvidenceMaximumPollCount
                ) {
                case let .complete(evidence):
                    writeWorkEvidence(evidence, console: console)
                case .timedOut:
                    console.write("SWIFTOS:SMP_WORK_TIMEOUT\n")
                    return false
                case .failed:
                    console.write("SWIFTOS:SMP_WORK_FAILED\n")
                    return false
                case .invalidContext:
                    console.write("SWIFTOS:SMP_WORK_BAD_CONTEXT\n")
                    return false
                }
                reportIndex += 1
            }
            console.write(workReadyMarker)
            console.write(onlineMarker)
            return true
        }
    }

    private static func writeOnlineMarker(
        logicalProcessorID: UInt8,
        console: EarlyConsole
    ) {
        switch logicalProcessorID {
        case 1: console.write("SWIFTOS:SMP_CPU1_ONLINE\n")
        case 2: console.write("SWIFTOS:SMP_CPU2_ONLINE\n")
        case 3: console.write("SWIFTOS:SMP_CPU3_ONLINE\n")
        default: console.write("SWIFTOS:SMP_BAD_CONTEXT\n")
        }
    }

    private static func writeWorkEvidence(
        _ evidence: SecondaryProcessorWorkEvidence,
        console: EarlyConsole
    ) {
        switch evidence.logicalProcessorID {
        case 1:
            console.write("SWIFTOS:SMP_CPU1_TASK1_OK\n")
            console.write("SWIFTOS:SMP_CPU1_TASK1_CHECKSUM=")
            console.writeHex(evidence.first.checksum)
            console.write("\nSWIFTOS:SMP_CPU1_TASK1_QUANTA=")
            console.writeHex(evidence.first.quantumCount)
            console.write("\nSWIFTOS:SMP_CPU1_TASK2_OK\n")
            console.write("SWIFTOS:SMP_CPU1_TASK2_CHECKSUM=")
            console.writeHex(evidence.second.checksum)
            console.write("\nSWIFTOS:SMP_CPU1_TASK2_QUANTA=")
            console.writeHex(evidence.second.quantumCount)
            console.write("\nSWIFTOS:SMP_CPU1_STACK=")
            console.writeHex(evidence.observedStackPointer)
            console.write("\nSWIFTOS:SMP_CPU1_TIMER_IRQS=")
        case 2:
            console.write("SWIFTOS:SMP_CPU2_TASK1_OK\n")
            console.write("SWIFTOS:SMP_CPU2_TASK1_CHECKSUM=")
            console.writeHex(evidence.first.checksum)
            console.write("\nSWIFTOS:SMP_CPU2_TASK1_QUANTA=")
            console.writeHex(evidence.first.quantumCount)
            console.write("\nSWIFTOS:SMP_CPU2_TASK2_OK\n")
            console.write("SWIFTOS:SMP_CPU2_TASK2_CHECKSUM=")
            console.writeHex(evidence.second.checksum)
            console.write("\nSWIFTOS:SMP_CPU2_TASK2_QUANTA=")
            console.writeHex(evidence.second.quantumCount)
            console.write("\nSWIFTOS:SMP_CPU2_STACK=")
            console.writeHex(evidence.observedStackPointer)
            console.write("\nSWIFTOS:SMP_CPU2_TIMER_IRQS=")
        case 3:
            console.write("SWIFTOS:SMP_CPU3_TASK1_OK\n")
            console.write("SWIFTOS:SMP_CPU3_TASK1_CHECKSUM=")
            console.writeHex(evidence.first.checksum)
            console.write("\nSWIFTOS:SMP_CPU3_TASK1_QUANTA=")
            console.writeHex(evidence.first.quantumCount)
            console.write("\nSWIFTOS:SMP_CPU3_TASK2_OK\n")
            console.write("SWIFTOS:SMP_CPU3_TASK2_CHECKSUM=")
            console.writeHex(evidence.second.checksum)
            console.write("\nSWIFTOS:SMP_CPU3_TASK2_QUANTA=")
            console.writeHex(evidence.second.quantumCount)
            console.write("\nSWIFTOS:SMP_CPU3_STACK=")
            console.writeHex(evidence.observedStackPointer)
            console.write("\nSWIFTOS:SMP_CPU3_TIMER_IRQS=")
        default:
            console.write("SWIFTOS:SMP_WORK_BAD_CONTEXT\n")
            return
        }
        console.writeHex(evidence.timerInterruptCount)
        console.write("\n")
    }

    private static func storageLayoutIsValid() -> Bool {
        let topology = KernelLinkerLayout.smpTopologyStorage
        let targets = KernelLinkerLayout.smpTargetStorage
        let states = KernelLinkerLayout.smpStateStorage
        let reports = KernelLinkerLayout.smpReportStorage
        let workThreads = KernelLinkerLayout.smpWorkThreadStorage
        let workIndices = KernelLinkerLayout.smpWorkIndexStorage
        let workContexts = KernelLinkerLayout.smpWorkContextStorage
        let workResults = KernelLinkerLayout.smpWorkResultStorage
        let workStates = KernelLinkerLayout.smpWorkStateStorage
        let workStacks = KernelLinkerLayout.smpWorkStackStorage
        let workTimerTicks = KernelLinkerLayout.smpWorkTimerTickStorage
        let followingStorage = KernelLinkerLayout.pagingLayoutStorage.start
        guard topology <= targets,
              targets <= states,
              states <= reports,
              reports <= workThreads,
              workThreads <= workIndices,
              workIndices <= workContexts,
              workContexts <= workResults,
              workResults <= workStates,
              workStates <= workStacks,
              workStacks <= workTimerTicks,
              workTimerTicks <= followingStorage
        else {
            return false
        }
        return targets - topology >= requiredBytes(
            ProcessorDescription.self,
            count: topologyCapacity
        ) && states - targets >= requiredBytes(
            SecondaryProcessorTarget.self,
            count: targetCapacity
        ) && reports - states >= requiredBytes(
            UInt64.self,
            count: stateCapacity
        ) && workThreads - reports >= requiredBytes(
            SecondaryProcessorStartReport.self,
            count: reportCapacity
        ) && workIndices - workThreads >= requiredBytes(
            ScheduledThread.self,
            count: SecondaryProcessorWorkScheduler.maximumTaskCount
        ) && workContexts - workIndices >= requiredBytes(
            Int32.self,
            count: ProcessorStartupPlan.maximumOnlineProcessorCount
        ) && workResults - workContexts >= requiredBytes(
            SecondaryProcessorWorkContext.self,
            count: SecondaryProcessorWorkScheduler.maximumTaskCount
        ) && workStates - workResults >= requiredBytes(
            SecondaryProcessorWorkResult.self,
            count: SecondaryProcessorWorkScheduler.maximumTaskCount
        ) && workStacks - workStates >= requiredBytes(
            UInt64.self,
            count: ProcessorStartupPlan.maximumOnlineProcessorCount
        ) && workTimerTicks - workStacks >= requiredBytes(
            UInt64.self,
            count: ProcessorStartupPlan.maximumOnlineProcessorCount
        ) && followingStorage - workTimerTicks >= requiredBytes(
            UInt64.self,
            count: ProcessorStartupPlan.maximumOnlineProcessorCount
        )
    }

    private static func requiredBytes<T>(
        _ type: T.Type,
        count: Int
    ) -> UInt64 {
        UInt64(MemoryLayout<T>.stride) * UInt64(count)
    }

    private static func buffer<T>(
        at address: UInt64,
        count: Int
    ) -> UnsafeMutableBufferPointer<T>? {
        guard address != 0,
              address <= UInt64(UInt.max),
              address % UInt64(MemoryLayout<T>.alignment) == 0,
              let base = UnsafeMutablePointer<T>(
                  bitPattern: UInt(address)
              )
        else {
            return nil
        }
        return UnsafeMutableBufferPointer(start: base, count: count)
    }
}
