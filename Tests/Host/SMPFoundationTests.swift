@main
struct SMPFoundationTests {
    static func main() {
        validatesAndDecodesAllAffinityLevels()
        deduplicatesAndBoundsTopologyStorage()
        identifiesTheBootProcessorUsingAff3()
        buildsDenseFourCoreStartupPlan()
        decodesPSCIResultsAndTracksBootState()
        print("SMP foundation host tests: 5 passed")
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

    private static func deduplicatesAndBoundsTopologyStorage() {
        withTopology(capacity: 2) { topology in
            expect(topology.register(deviceTreeAffinity: 0)
                    == .inserted(index: 0), "boot CPU insert")
            expect(topology.register(deviceTreeAffinity: 0)
                    == .duplicate(existingIndex: 0), "duplicate CPU")
            expect(topology.register(deviceTreeAffinity: 0x100)
                    == .inserted(index: 1), "second CPU insert")
            expect(topology.register(deviceTreeAffinity: 0x200)
                    == .capacityExhausted, "topology overflow")
            expect(topology.register(deviceTreeAffinity: 1 << 40)
                    == .invalidAffinity, "invalid CPU affinity")
            expect(topology.count == 2, "invalid registration changed count")
        }

        let oversized = UnsafeMutableBufferPointer<ProcessorAffinity>.allocate(
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

    private static func buildsDenseFourCoreStartupPlan() {
        withTopology(capacity: 6) { topology in
            _ = topology.register(deviceTreeAffinity: 0x200)
            _ = topology.register(deviceTreeAffinity: 0x0000_0001_0000_0000)
            _ = topology.register(deviceTreeAffinity: 0)
            _ = topology.register(deviceTreeAffinity: 0x100)
            _ = topology.register(deviceTreeAffinity: 0x300)

            let targets = UnsafeMutableBufferPointer<SecondaryProcessorTarget>
                .allocate(capacity: 3)
            defer { targets.deallocate() }
            let plan = ProcessorStartupPlan(
                topology: topology,
                bootMPIDR: 0,
                maximumProcessorCount: 4,
                targetStorage: targets
            )
            expect(plan?.processorCount == 4, "four-core cap")
            expect(plan?.bootProcessor.topologyIndex == 2, "boot topology ID")
            expect(plan?.secondaryProcessor(at: 0)?.affinity.rawValue == 0x200,
                   "first startup target")
            expect(plan?.secondaryProcessor(at: 1)?.affinity.rawValue
                    == 0x0000_0001_0000_0000, "second startup target")
            expect(plan?.secondaryProcessor(at: 2)?.affinity.rawValue == 0x100,
                   "third startup target")
            expect(plan?.secondaryProcessor(at: 0)?.logicalProcessorID == 1,
                   "dense logical CPU 1")
            expect(plan?.secondaryProcessor(at: 2)?.contextID == 3,
                   "per-core context ID")
        }
    }

    private static func decodesPSCIResultsAndTracksBootState() {
        expect(PSCIFunctionID.cpuOn64 == 0xc400_0003, "CPU_ON function ID")
        expect(PSCIReturnValue(rawRegisterValue: 0) == .success, "success")
        expect(PSCIReturnValue(rawRegisterValue: UInt64.max - 3) == .alreadyOn,
               "ALREADY_ON")
        expect(PSCIReturnValue(rawRegisterValue: UInt64.max - 4) == .onPending,
               "ON_PENDING")
        expect(PSCIReturnValue(rawRegisterValue: UInt64.max - 8)
                == .invalidAddress, "INVALID_ADDRESS")
        expect(PSCIReturnValue(rawRegisterValue: 7) == .unknown(7), "unknown")

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
    let storage = UnsafeMutableBufferPointer<ProcessorAffinity>.allocate(
        capacity: capacity
    )
    defer { storage.deallocate() }
    var topology = ProcessorTopology(storage: storage)!
    body(&topology)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
