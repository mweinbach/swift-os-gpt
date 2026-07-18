@main
struct VirtIOGPU3DBootstrapMemoryTests {
    static func main() {
        testPartitionsTranslatedCoherentMemory()
        testRejectsWrongAllocationShape()
        testRejectsMissingAccessCapabilities()
        testRejectsInvalidDeviceWindow()
        print("VirtIO-GPU 3D bootstrap memory host tests: 4 groups passed")
    }

    private static func testPartitionsTranslatedCoherentMemory() {
        let token = makeToken(
            pageCount: 3,
            capabilities: .cpuAccessible
                .union(.deviceAccessible)
                .union(.cacheCoherent)
        )
        guard let workspace = VirtIOGPU3DBootstrapMemory(
                  allocation: token,
                  deviceBaseAddress: 0x4000_0000,
                  deviceAddressWidth: .bits32,
                  coherency: .hardwareCoherent
              )
        else {
            fail("valid translated workspace was rejected")
        }
        expect(workspace.allocation == token, "allocation ownership")
        expect(
            workspace.commandArena.cpuPhysicalAddress == 0x1000_0000,
            "command CPU address"
        )
        expect(
            workspace.request.cpuPhysicalAddress == 0x1000_1000,
            "request CPU address"
        )
        expect(
            workspace.response.cpuPhysicalAddress == 0x1000_2000,
            "response CPU address"
        )
        expect(
            workspace.commandArena.deviceAddress == 0x4000_0000
                && workspace.request.deviceAddress == 0x4000_1000
                && workspace.response.deviceAddress == 0x4000_2000,
            "translated device partitions"
        )
        expect(
            workspace.response.byteCount == MemoryPageGeometry.pageSize,
            "response page extent"
        )
    }

    private static func testRejectsWrongAllocationShape() {
        let capabilities = PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceAccessible)
            .union(.cacheCoherent)
        expect(
            makeWorkspace(makeToken(pageCount: 2, capabilities: capabilities))
                == nil,
            "short allocation was accepted"
        )
        expect(
            makeWorkspace(makeToken(pageCount: 4, capabilities: capabilities))
                == nil,
            "ambiguous oversized allocation was accepted"
        )
        let zeroIdentifier = makeToken(
            identifier: 0,
            pageCount: 3,
            capabilities: capabilities
        )
        expect(makeWorkspace(zeroIdentifier) == nil, "unowned range was accepted")
    }

    private static func testRejectsMissingAccessCapabilities() {
        let cpuOnly = makeToken(
            pageCount: 3,
            capabilities: .cpuAccessible.union(.cacheCoherent)
        )
        expect(makeWorkspace(cpuOnly) == nil, "CPU-only memory was accepted")

        let noncoherent = makeToken(
            pageCount: 3,
            capabilities: .cpuAccessible.union(.deviceAccessible)
        )
        expect(
            makeWorkspace(noncoherent) == nil,
            "noncoherent memory claimed hardware coherency"
        )
        expect(
            VirtIOGPU3DBootstrapMemory(
                allocation: noncoherent,
                deviceBaseAddress: 0x4000_0000,
                deviceAddressWidth: .bits32,
                coherency: .softwareManaged
            ) != nil,
            "software-managed DMA memory was rejected"
        )
    }

    private static func testRejectsInvalidDeviceWindow() {
        let token = makeToken(
            pageCount: 3,
            capabilities: .cpuAccessible
                .union(.deviceAccessible)
                .union(.cacheCoherent)
        )
        expect(
            VirtIOGPU3DBootstrapMemory(
                allocation: token,
                deviceBaseAddress: 0x4000_0001,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "unaligned device base was accepted"
        )
        expect(
            VirtIOGPU3DBootstrapMemory(
                allocation: token,
                deviceBaseAddress: 0xffff_f000,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "out-of-width device partitions were accepted"
        )
    }

    private static func makeWorkspace(
        _ token: ClassifiedPageAllocationToken
    ) -> VirtIOGPU3DBootstrapMemory? {
        VirtIOGPU3DBootstrapMemory(
            allocation: token,
            deviceBaseAddress: 0x4000_0000,
            deviceAddressWidth: .bits32,
            coherency: .hardwareCoherent
        )
    }

    private static func makeToken(
        identifier: UInt64 = 1,
        pageCount: UInt64,
        capabilities: PhysicalMemoryCapabilities
    ) -> ClassifiedPageAllocationToken {
        guard let range = PhysicalPageRange(
                  baseAddress: 0x1000_0000,
                  pageCount: pageCount
              )
        else {
            fail("test range was invalid")
        }
        return ClassifiedPageAllocationToken(
            identifier: identifier,
            range: range,
            classification: PhysicalMemoryClassification(
                allocationDomain: PhysicalMemoryAllocationDomain(7),
                capabilities: capabilities,
                proximityDomain: PhysicalMemoryProximityDomain(3)
            )
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        print("FAIL:", message)
        fatalError()
    }
}
