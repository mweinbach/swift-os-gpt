@main
struct VirtIOBlockBootstrapMemoryTests {
    static func main() {
        partitionsOneTranslatedPage()
        rejectsWrongAllocationShape()
        enforcesCoherentDeviceMemory()
        rejectsInvalidDeviceWindow()
        print("VirtIO block bootstrap memory: 4 groups passed")
    }

    private static func partitionsOneTranslatedPage() {
        let token = makeToken(
            pageCount: VirtIOBlockBootstrapMemory.pageCount,
            capabilities: coherentCapabilities
        )
        guard let workspace = VirtIOBlockBootstrapMemory(
                  allocation: token,
                  deviceBaseAddress: 0x4000_0000,
                  deviceAddressWidth: .bits32,
                  coherency: .hardwareCoherent
              )
        else { fail("valid block workspace was rejected") }
        expect(workspace.allocation == token, "allocation ownership changed")
        expect(
            workspace.storage.requestQueue.cpuPhysicalAddress == 0x1000_0000
                && workspace.storage.requestQueue.deviceAddress == 0x4000_0000
                && workspace.storage.requestQueue.byteCount == 256,
            "queue partition"
        )
        expect(
            workspace.storage.requestHeader.cpuPhysicalAddress == 0x1000_0100
                && workspace.storage.requestHeader.deviceAddress == 0x4000_0100,
            "header partition"
        )
        expect(
            workspace.storage.data.cpuPhysicalAddress == 0x1000_0200
                && workspace.storage.data.deviceAddress == 0x4000_0200
                && workspace.storage.data.byteCount == 512,
            "data partition"
        )
        expect(
            workspace.storage.status.cpuPhysicalAddress == 0x1000_0400
                && workspace.storage.status.deviceAddress == 0x4000_0400,
            "status partition"
        )
        expect(
            workspace.storage.requestQueueLayout.requiredByteCount <= 256,
            "queue no longer fits partition"
        )
    }

    private static func rejectsWrongAllocationShape() {
        expect(
            makeWorkspace(makeToken(
                pageCount: 2,
                capabilities: coherentCapabilities
            )) == nil,
            "oversized allocation accepted"
        )
        expect(
            makeWorkspace(makeToken(
                identifier: 0,
                pageCount: 1,
                capabilities: coherentCapabilities
            )) == nil,
            "unowned allocation accepted"
        )
    }

    private static func enforcesCoherentDeviceMemory() {
        expect(
            makeWorkspace(makeToken(
                pageCount: 1,
                capabilities: .cpuAccessible.union(.cacheCoherent)
            )) == nil,
            "CPU-only allocation accepted"
        )
        expect(
            makeWorkspace(makeToken(
                pageCount: 1,
                capabilities: .cpuAccessible.union(.deviceAccessible)
            )) == nil,
            "noncoherent allocation accepted"
        )
        expect(
            VirtIOBlockBootstrapMemory(
                allocation: makeToken(
                    pageCount: 1,
                    capabilities: coherentCapabilities
                ),
                deviceBaseAddress: 0x4000_0000,
                deviceAddressWidth: .bits32,
                coherency: .softwareManaged
            ) == nil,
            "software-managed DMA accepted"
        )
    }

    private static func rejectsInvalidDeviceWindow() {
        let token = makeToken(
            pageCount: 1,
            capabilities: coherentCapabilities
        )
        expect(
            VirtIOBlockBootstrapMemory(
                allocation: token,
                deviceBaseAddress: 0x4000_0001,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "unaligned device base accepted"
        )
        expect(
            VirtIOBlockBootstrapMemory(
                allocation: token,
                deviceBaseAddress: 0xffff_ffff_ffff_f000,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "out-of-width device range accepted"
        )
    }

    private static var coherentCapabilities: PhysicalMemoryCapabilities {
        .cpuAccessible.union(.deviceAccessible).union(.cacheCoherent)
    }

    private static func makeWorkspace(
        _ token: ClassifiedPageAllocationToken
    ) -> VirtIOBlockBootstrapMemory? {
        VirtIOBlockBootstrapMemory(
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
        else { fail("invalid test range") }
        return ClassifiedPageAllocationToken(
            identifier: identifier,
            range: range,
            classification: PhysicalMemoryClassification(
                allocationDomain: PhysicalMemoryAllocationDomain(9),
                capabilities: capabilities,
                proximityDomain: PhysicalMemoryProximityDomain(2)
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
