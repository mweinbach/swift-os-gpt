private enum MockCPUOnBehavior: UInt64 {
    case publishOnline
    case returnAlreadyOn
    case returnDenied
    case acceptWithoutPublication
}

private nonisolated(unsafe) var mockBehaviors: (
    MockCPUOnBehavior,
    MockCPUOnBehavior,
    MockCPUOnBehavior
) = (.publishOnline, .publishOnline, .publishOnline)
private nonisolated(unsafe) var hvcCallCount = 0
private nonisolated(unsafe) var smcCallCount = 0
private nonisolated(unsafe) var relaxCount: UInt64 = 0
private nonisolated(unsafe) var eventCount: UInt64 = 0

@main
struct SMPRuntimeTests {
    static func main() {
        startsAndClassifiesFourProcessorsThroughHVC()
        reportsBoundedTimeoutAndSelectsSMC()
        rejectsInvalidRuntimeConfiguration()
        print("SMP runtime host tests: 3 passed")
    }

    private static func startsAndClassifiesFourProcessorsThroughHVC() {
        mockBehaviors = (.publishOnline, .returnAlreadyOn, .returnDenied)
        resetMockCounters()
        withRuntime(processorCount: 4, conduit: .hypervisorCall) { runtime in
            let result = runtime.startSecondaryProcessors(
                secondaryEntryPhysicalAddress: 0x80000,
                pollLimit: 8
            )
            expect(result == .completed(SMPStartupSummary(
                selectedProcessorCount: 4,
                onlineProcessorCount: 2,
                firmwareAlreadyOnCount: 1,
                timedOutCount: 0,
                rejectedCount: 1
            )), "HVC startup summary")
            expect(runtime.report(at: 0)?.outcome == .online,
                   "published processor")
            expect(runtime.report(at: 1)?.outcome == .firmwareAlreadyOn,
                   "ALREADY_ON processor")
            expect(runtime.report(at: 2)?.outcome == .rejected(.denied),
                   "denied processor")
            expect(hvcCallCount == 3 && smcCallCount == 0,
                   "wrong PSCI conduit")
            expect(eventCount == 1, "online publication omitted SEV")
        }
    }

    private static func reportsBoundedTimeoutAndSelectsSMC() {
        mockBehaviors = (
            .acceptWithoutPublication,
            .publishOnline,
            .publishOnline
        )
        resetMockCounters()
        withRuntime(processorCount: 2, conduit: .secureMonitorCall) { runtime in
            let result = runtime.startSecondaryProcessors(
                secondaryEntryPhysicalAddress: 0x100000,
                pollLimit: 3
            )
            expect(result == .completed(SMPStartupSummary(
                selectedProcessorCount: 2,
                onlineProcessorCount: 1,
                firmwareAlreadyOnCount: 0,
                timedOutCount: 1,
                rejectedCount: 0
            )), "timeout summary")
            expect(runtime.report(at: 0)?.outcome == .timedOut,
                   "timeout report")
            expect(runtime.report(at: 0)?.pollCount == 3,
                   "timeout was not bounded")
            expect(relaxCount == 3, "poll loop did not relax exactly three times")
            expect(smcCallCount == 1 && hvcCallCount == 0,
                   "SMC conduit was not selected")
        }
    }

    private static func rejectsInvalidRuntimeConfiguration() {
        mockBehaviors = (.publishOnline, .publishOnline, .publishOnline)
        resetMockCounters()
        withRuntime(processorCount: 2, conduit: .hypervisorCall) { runtime in
            expect(runtime.startSecondaryProcessors(
                secondaryEntryPhysicalAddress: 0,
                pollLimit: 1
            ) == .invalidConfiguration(.invalidSecondaryEntryAddress),
            "zero entry address")
            expect(runtime.startSecondaryProcessors(
                secondaryEntryPhysicalAddress: 0x80002,
                pollLimit: 1
            ) == .invalidConfiguration(.invalidSecondaryEntryAddress),
            "misaligned entry address")
            expect(runtime.startSecondaryProcessors(
                secondaryEntryPhysicalAddress: 0x80000,
                pollLimit: 0
            ) == .invalidConfiguration(.invalidPollLimit),
            "zero poll limit")
            expect(hvcCallCount == 0 && smcCallCount == 0,
                   "invalid configuration reached firmware")
        }
    }
}

private func withRuntime(
    processorCount: Int,
    conduit: PSCIConduit,
    body: (inout SMPRuntime) -> Void
) {
    let topologyStorage = UnsafeMutableBufferPointer<ProcessorDescription>
        .allocate(capacity: processorCount)
    let targetStorage = UnsafeMutableBufferPointer<SecondaryProcessorTarget>
        .allocate(capacity: max(0, processorCount - 1))
    let stateStorage = UnsafeMutableBufferPointer<UInt64>
        .allocate(capacity: processorCount)
    let reportStorage = UnsafeMutableBufferPointer<SecondaryProcessorStartReport>
        .allocate(capacity: max(0, processorCount - 1))
    defer {
        topologyStorage.deallocate()
        targetStorage.deallocate()
        stateStorage.deallocate()
        reportStorage.deallocate()
    }

    var topology = ProcessorTopology(storage: topologyStorage)!
    var processor = 0
    while processor < processorCount {
        _ = topology.register(
            deviceTreeAffinity: UInt64(processor) << 8
        )
        processor += 1
    }
    let plan = ProcessorStartupPlan(
        topology: topology,
        bootMPIDR: 0,
        configuration: ProcessorBootConfiguration(
            requestedProcessorLimit: processorCount,
            resources: ProcessorBootResourceCapacity(
                topologyDescriptions: topologyStorage.count,
                secondaryTargets: targetStorage.count,
                bootStates: stateStorage.count,
                startupReports: reportStorage.count
            )
        )!,
        targetStorage: targetStorage
    )!
    var runtime = SMPRuntime(
        conduit: conduit,
        plan: plan,
        stateStorage: stateStorage,
        reportStorage: reportStorage
    )!
    body(&runtime)
}

private func resetMockCounters() {
    hvcCallCount = 0
    smcCallCount = 0
    relaxCount = 0
    eventCount = 0
}

private func behavior(for contextID: UInt64) -> MockCPUOnBehavior {
    switch contextID {
    case 1: return mockBehaviors.0
    case 2: return mockBehaviors.1
    default: return mockBehaviors.2
    }
}

private func mockCPUOn(
    functionID: UInt64,
    contextID: UInt64
) -> UInt64 {
    guard functionID == PSCIFunctionID.cpuOn64 else {
        return UInt64(bitPattern: Int64(-1))
    }
    switch behavior(for: contextID) {
    case .publishOnline:
        return swiftOSSMPPublishOnline(contextID) == contextID
            ? 0
            : UInt64(bitPattern: Int64(-6))
    case .returnAlreadyOn:
        return UInt64(bitPattern: Int64(-4))
    case .returnDenied:
        return UInt64(bitPattern: Int64(-3))
    case .acceptWithoutPublication:
        return 0
    }
}

@_cdecl("arch_psci_hvc")
func mockPSCIHVC(
    _ functionID: UInt64,
    _ targetAffinity: UInt64,
    _ entryAddress: UInt64,
    _ contextID: UInt64
) -> UInt64 {
    hvcCallCount += 1
    return mockCPUOn(functionID: functionID, contextID: contextID)
}

@_cdecl("arch_psci_smc")
func mockPSCISMC(
    _ functionID: UInt64,
    _ targetAffinity: UInt64,
    _ entryAddress: UInt64,
    _ contextID: UInt64
) -> UInt64 {
    smcCallCount += 1
    return mockCPUOn(functionID: functionID, contextID: contextID)
}

@_cdecl("arch_smp_store_release")
func mockStoreRelease(
    _ address: UnsafeMutablePointer<UInt64>,
    _ value: UInt64
) {
    address.pointee = value
}

@_cdecl("arch_smp_load_acquire")
func mockLoadAcquire(
    _ address: UnsafePointer<UInt64>
) -> UInt64 {
    address.pointee
}

@_cdecl("arch_smp_relax")
func mockRelax() {
    relaxCount += 1
}

@_cdecl("arch_smp_send_event")
func mockSendEvent() {
    eventCount += 1
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
