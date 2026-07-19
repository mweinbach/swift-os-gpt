@main
struct SMPFoundationTests {
    static func main() {
        validatesAndDecodesAllAffinityLevels()
        preservesCompactProcessorDescriptions()
        rejectsConflictingDescriptionsAndBoundsTopologyStorage()
        identifiesTheBootProcessorUsingAff3()
        validatesLinkedBootResourceConfigurations()
        buildsRequestedPlansWithDenseIdentifiers()
        decodesPSCIResultsAndTracksBootState()
        print("SMP foundation host tests: 7 passed")
    }

    private static func validatesAndDecodesAllAffinityLevels() {
        let raw: UInt64 = 0x0000_0044_0033_2211
        let affinity = ProcessorAffinity(deviceTreeValue: raw)
        expect(affinity?.affinityLevel0 == 0x11, "Aff0 decode")
        expect(affinity?.affinityLevel1 == 0x22, "Aff1 decode")
        expect(affinity?.affinityLevel2 == 0x33, "Aff2 decode")
        expect(affinity?.affinityLevel3 == 0x44, "Aff3 decode")
        expect(ProcessorAffinity(deviceTreeValue: raw | (1 << 31)) == nil,
               "non-affinity MPIDR flag was accepted")
        expect(ProcessorAffinity.fromMPIDR(raw | (1 << 24)) == affinity,
               "MPIDR flags were not normalized")
    }

    private static func preservesCompactProcessorDescriptions() {
        let capabilities = ProcessorCapabilities.floatingPoint
            .union(.advancedSIMD)
            .union(.genericTimer)
        let description = ProcessorDescription(
            affinity: ProcessorAffinity(deviceTreeValue: 0x103)!,
            processorClass: .performance,
            capabilities: capabilities,
            proximity: ProcessorProximity(domain: 7),
            startupEligibility: .bootProcessorOnly
        )
        expect(MemoryLayout<ProcessorDescription>.stride == 8,
               "processor description exceeded early storage word")
        expect(description.affinity.rawValue == 0x103, "packed affinity")
        expect(description.processorClass == .performance, "packed class")
        expect(description.capabilities.contains(.floatingPoint),
               "packed floating-point capability")
        expect(description.capabilities.contains(.advancedSIMD),
               "packed SIMD capability")
        expect(description.capabilities.contains(.genericTimer),
               "packed timer capability")
        expect(description.proximity.domain == 7, "packed proximity")
        expect(description.startupEligibility == .bootProcessorOnly,
               "packed startup eligibility")
    }

    private static func rejectsConflictingDescriptionsAndBoundsTopologyStorage() {
        withTopology(capacity: 2) { topology in
            let boot = ProcessorDescription(
                affinity: ProcessorAffinity(deviceTreeValue: 0)!,
                processorClass: .performance
            )
            let conflictingBoot = ProcessorDescription(
                affinity: ProcessorAffinity(deviceTreeValue: 0)!,
                processorClass: .efficiency
            )
            expect(topology.register(boot)
                    == .inserted(index: 0), "boot CPU insert")
            expect(topology.register(boot)
                    == .duplicate(existingIndex: 0), "duplicate CPU")
            expect(topology.register(conflictingBoot)
                    == .conflictingDescription(existingIndex: 0),
                   "conflicting CPU description")
            expect(topology.register(deviceTreeAffinity: 0x100)
                    == .inserted(index: 1), "second CPU insert")
            expect(topology.register(deviceTreeAffinity: 0x200)
                    == .capacityExhausted, "topology overflow")
            expect(topology.register(deviceTreeAffinity: 1 << 40)
                    == .invalidAffinity, "invalid CPU affinity")
            expect(topology.count == 2, "invalid registration changed count")
        }

        let oversized = UnsafeMutableBufferPointer<ProcessorDescription>.allocate(
            capacity: 65
        )
        defer { oversized.deallocate() }
        expect(ProcessorTopology(storage: oversized) == nil,
               "topology accepted more than 64 entries")
    }

    private static func identifiesTheBootProcessorUsingAff3() {
        withTopology(capacity: 3) { topology in
            _ = topology.register(deviceTreeAffinity: 0x0000_0001_0000_0000)
            _ = topology.register(deviceTreeAffinity: 0x0000_0002_0000_0000)
            _ = topology.register(deviceTreeAffinity: 0)
            let mpidr: UInt64 = 0x8000_0002_0100_0000
            let identity = topology.identifyBootProcessor(mpidr: mpidr)
            expect(identity?.topologyIndex == 1,
                   "boot CPU match ignored Aff3")
            expect(identity?.affinity.rawValue == 0x0000_0002_0000_0000,
                   "boot CPU affinity was not normalized")
        }
    }

    private static func validatesLinkedBootResourceConfigurations() {
        let fourCoreResources = ProcessorBootResourceCapacity(
            topologyDescriptions: 4,
            secondaryTargets: 3,
            bootStates: 4,
            startupReports: 3
        )
        expect(ProcessorBootConfiguration(
            requestedProcessorLimit: 4,
            resources: fourCoreResources
        ) != nil, "valid four-core resources")
        expect(ProcessorBootConfiguration(
            requestedProcessorLimit: 5,
            resources: ProcessorBootResourceCapacity(
                topologyDescriptions: 64,
                secondaryTargets: 63,
                bootStates: 64,
                startupReports: 63
            )
        ) == nil, "configuration exceeded the bootable four-core ceiling")
        expect(ProcessorBootConfiguration(
            requestedProcessorLimit: 4,
            resources: ProcessorBootResourceCapacity(
                topologyDescriptions: 4,
                secondaryTargets: 2,
                bootStates: 4,
                startupReports: 3
            )
        ) == nil, "configuration accepted insufficient target storage")
        expect(ProcessorBootConfiguration(
            requestedProcessorLimit: 4,
            resources: ProcessorBootResourceCapacity(
                topologyDescriptions: 4,
                secondaryTargets: 3,
                bootStates: 3,
                startupReports: 3
            )
        ) == nil, "configuration accepted insufficient state storage")
    }

    private static func buildsRequestedPlansWithDenseIdentifiers() {
        withTopology(capacity: 6) { topology in
            _ = topology.register(description(
                affinity: 0x200,
                processorClass: .efficiency,
                proximityDomain: 1
            ))
            _ = topology.register(description(
                affinity: 0x0000_0001_0000_0000,
                processorClass: .performance,
                proximityDomain: 0,
                eligibility: .bootProcessorOnly
            ))
            _ = topology.register(description(
                affinity: 0,
                processorClass: .performance,
                proximityDomain: 0
            ))
            _ = topology.register(description(
                affinity: 0x100,
                processorClass: .efficiency,
                proximityDomain: 1
            ))
            _ = topology.register(description(
                affinity: 0x300,
                processorClass: .generalPurpose,
                proximityDomain: 2,
                eligibility: .disabled
            ))
            _ = topology.register(description(
                affinity: 0x400,
                processorClass: .generalPurpose,
                proximityDomain: 2
            ))

            let targets = UnsafeMutableBufferPointer<SecondaryProcessorTarget>
                .allocate(capacity: 3)
            defer { targets.deallocate() }
            let resources = ProcessorBootResourceCapacity(
                topologyDescriptions: topology.capacity,
                secondaryTargets: targets.count,
                bootStates: 4,
                startupReports: 3
            )
            let oneCore = ProcessorStartupPlan(
                topology: topology,
                bootMPIDR: 0,
                configuration: ProcessorBootConfiguration(
                    requestedProcessorLimit: 1,
                    resources: resources
                )!,
                targetStorage: targets
            )
            let twoCore = ProcessorStartupPlan(
                topology: topology,
                bootMPIDR: 0,
                configuration: ProcessorBootConfiguration(
                    requestedProcessorLimit: 2,
                    resources: resources
                )!,
                targetStorage: targets
            )
            let plan = ProcessorStartupPlan(
                topology: topology,
                bootMPIDR: 0,
                configuration: ProcessorBootConfiguration(
                    requestedProcessorLimit: 4,
                    resources: resources
                )!,
                targetStorage: targets
            )
            expect(oneCore?.processorCount == 1, "one-core requested limit")
            expect(twoCore?.processorCount == 2, "two-core requested limit")
            expect(plan?.processorCount == 4, "four-core cap")
            expect(plan?.bootProcessor.topologyIndex == 2, "boot topology ID")
            expect(plan?.secondaryProcessor(at: 0)?.affinity.rawValue == 0x200,
                   "first startup target")
            expect(plan?.secondaryProcessor(at: 1)?.affinity.rawValue == 0x100,
                   "ineligible target was not skipped")
            expect(plan?.secondaryProcessor(at: 2)?.affinity.rawValue == 0x400,
                   "disabled target was not skipped")
            expect(plan?.secondaryProcessor(at: 0)?.description.processorClass
                    == .efficiency, "mixed CPU class was not preserved")
            expect(plan?.secondaryProcessor(at: 2)?.description.proximity.domain
                    == 2, "target proximity was not preserved")
            expect(plan?.secondaryProcessor(at: 0)?.logicalProcessorID == 1,
                   "dense logical CPU 1")
            expect(plan?.secondaryProcessor(at: 2)?.contextID == 3,
                   "per-core context ID")
        }
    }

    private static func decodesPSCIResultsAndTracksBootState() {
        expect(PSCIFunctionID.cpuOn64 == 0xc400_0003, "CPU_ON function ID")
        expect(PSCIFunctionID.affinityInfo64 == 0xc400_0004,
               "AFFINITY_INFO function ID")
        expect(PSCIReturnValue(rawRegisterValue: 0) == .success, "success")
        expect(PSCIReturnValue(rawRegisterValue: UInt64.max - 3) == .alreadyOn,
               "ALREADY_ON")
        expect(PSCIReturnValue(rawRegisterValue: UInt64.max - 4) == .onPending,
               "ON_PENDING")
        expect(PSCIReturnValue(rawRegisterValue: UInt64.max - 8)
                == .invalidAddress, "INVALID_ADDRESS")
        expect(PSCIReturnValue(rawRegisterValue: 7) == .unknown(7), "unknown")
        expect(PSCIAffinityInfoResult(rawRegisterValue: 0) == .on,
               "affinity ON")
        expect(PSCIAffinityInfoResult(rawRegisterValue: 1) == .off,
               "affinity OFF")
        expect(PSCIAffinityInfoResult(rawRegisterValue: 2) == .onPending,
               "affinity ON_PENDING")
        expect(
            PSCIAffinityInfoResult(rawRegisterValue: UInt64.max)
                == .failure(.notSupported),
            "affinity PSCI failure"
        )

        let states = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 4)
        defer { states.deallocate() }
        var table = ProcessorBootStateTable(
            storage: states,
            processorCount: 4
        )!
        expect(table.state(of: 0) == .online, "boot CPU starts online")
        expect(table.state(of: 3) == .offline, "secondary starts offline")
        expect(table.transition(logicalProcessorID: 3,
                                from: .offline, to: .starting), "start")
        expect(table.transition(logicalProcessorID: 3,
                                from: .starting, to: .online), "publish")
        expect(!table.transition(logicalProcessorID: 3,
                                 from: .starting, to: .failed),
               "stale transition was accepted")
    }
}

private func withTopology(
    capacity: Int,
    body: (inout ProcessorTopology) -> Void
) {
    let storage = UnsafeMutableBufferPointer<ProcessorDescription>.allocate(
        capacity: capacity
    )
    defer { storage.deallocate() }
    var topology = ProcessorTopology(storage: storage)!
    body(&topology)
}

private func description(
    affinity: UInt64,
    processorClass: ProcessorClass,
    proximityDomain: UInt8,
    eligibility: ProcessorStartupEligibility = .eligible
) -> ProcessorDescription {
    ProcessorDescription(
        affinity: ProcessorAffinity(deviceTreeValue: affinity)!,
        processorClass: processorClass,
        capabilities: .genericTimer,
        proximity: ProcessorProximity(domain: proximityDomain),
        startupEligibility: eligibility
    )
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
