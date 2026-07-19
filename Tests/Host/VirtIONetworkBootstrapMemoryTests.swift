@main
struct VirtIONetworkBootstrapMemoryTests {
    static func main() {
        partitionsTranslatedCoherentMemory()
        rejectsWrongAllocationShape()
        enforcesCoherencyCapabilities()
        rejectsInvalidDeviceWindow()
        print("VirtIO network bootstrap memory: 4 groups passed")
    }

    private static func partitionsTranslatedCoherentMemory() {
        let token = makeToken(
            pageCount: VirtIONetworkBootstrapMemory.pageCount,
            capabilities: .cpuAccessible
                .union(.deviceAccessible)
                .union(.cacheCoherent)
        )
        guard let workspace = VirtIONetworkBootstrapMemory(
                  allocation: token,
                  deviceBaseAddress: 0x4000_0000,
                  deviceAddressWidth: .bits32,
                  coherency: .hardwareCoherent
              )
        else { fail("valid network workspace was rejected") }

        let storage = workspace.storage
        expect(workspace.allocation == token, "allocation ownership changed")
        expect(
            storage.receiveQueue.cpuPhysicalAddress == 0x1000_0000
                && storage.receiveQueue.deviceAddress == 0x4000_0000,
            "receive queue partition changed"
        )
        expect(
            storage.transmitQueue.cpuPhysicalAddress == 0x1000_1000
                && storage.transmitQueue.deviceAddress == 0x4000_1000,
            "transmit queue partition changed"
        )
        expect(
            storage.receiveBuffers.cpuPhysicalAddress == 0x1000_2000
                && storage.receiveBuffers.deviceAddress == 0x4000_2000
                && storage.receiveBuffers.byteCount == 0x3000,
            "receive buffer partition changed"
        )
        expect(
            storage.transmitBuffer.cpuPhysicalAddress == 0x1000_5000
                && storage.transmitBuffer.deviceAddress == 0x4000_5000,
            "transmit buffer partition changed"
        )
        expect(
            workspace.receiveScratchAddress == 0x1000_6000
                && workspace.transmitScratchAddress == 0x1000_7000
                && workspace.scratchByteCount == 0x1000,
            "network stack scratch partition changed"
        )
        expect(
            storage.receiveQueueLayout.size
                == VirtIONetworkBootstrapMemory.receiveQueueSize
                && storage.transmitQueueLayout.size
                    == VirtIONetworkBootstrapMemory.transmitQueueSize,
            "queue sizes changed"
        )
    }

    private static func rejectsWrongAllocationShape() {
        let capabilities = PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceAccessible)
            .union(.cacheCoherent)
        expect(
            makeWorkspace(
                makeToken(pageCount: 7, capabilities: capabilities)
            ) == nil,
            "short allocation was accepted"
        )
        expect(
            makeWorkspace(
                makeToken(pageCount: 9, capabilities: capabilities)
            ) == nil,
            "oversized allocation was accepted"
        )
        expect(
            makeWorkspace(
                makeToken(
                    identifier: 0,
                    pageCount: VirtIONetworkBootstrapMemory.pageCount,
                    capabilities: capabilities
                )
            ) == nil,
            "unowned allocation was accepted"
        )
    }

    private static func enforcesCoherencyCapabilities() {
        let cpuOnly = makeToken(
            pageCount: VirtIONetworkBootstrapMemory.pageCount,
            capabilities: .cpuAccessible.union(.cacheCoherent)
        )
        expect(makeWorkspace(cpuOnly) == nil, "CPU-only memory was accepted")

        let softwareManaged = makeToken(
            pageCount: VirtIONetworkBootstrapMemory.pageCount,
            capabilities: .cpuAccessible.union(.deviceAccessible)
        )
        expect(
            makeWorkspace(softwareManaged) == nil,
            "noncoherent memory claimed hardware coherency"
        )
        expect(
            VirtIONetworkBootstrapMemory(
                allocation: softwareManaged,
                deviceBaseAddress: 0x4000_0000,
                deviceAddressWidth: .bits32,
                coherency: .softwareManaged
            ) == nil,
            "VirtIO backend accepted software-managed DMA it cannot maintain"
        )
    }

    private static func rejectsInvalidDeviceWindow() {
        let token = makeToken(
            pageCount: VirtIONetworkBootstrapMemory.pageCount,
            capabilities: .cpuAccessible
                .union(.deviceAccessible)
                .union(.cacheCoherent)
        )
        expect(
            VirtIONetworkBootstrapMemory(
                allocation: token,
                deviceBaseAddress: 0x4000_0001,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "unaligned device base was accepted"
        )
        expect(
            VirtIONetworkBootstrapMemory(
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
    ) -> VirtIONetworkBootstrapMemory? {
        VirtIONetworkBootstrapMemory(
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
