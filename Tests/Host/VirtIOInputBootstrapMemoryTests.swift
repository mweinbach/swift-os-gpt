@main
struct VirtIOInputBootstrapMemoryTests {
    static func main() {
        validatesSplitQueueGeometry()
        partitionsOneTranslatedPage()
        rejectsWrongAllocationShape()
        enforcesCoherentDeviceMemory()
        rejectsInvalidDeviceWindow()
        print("VirtIO input bootstrap memory: 5 groups passed")
    }

    private static func validatesSplitQueueGeometry() {
        guard let one = VirtIOSplitQueueLayout(size: 1),
              let input = VirtIOSplitQueueLayout(size: 64),
              let maximum = VirtIOSplitQueueLayout(size: 1_024)
        else { fail("valid split queue geometry was rejected") }
        expect(
            one.descriptorOffset == 0
                && one.availableOffset == 16
                && one.usedOffset == 24
                && one.requiredByteCount == 38,
            "single-entry split queue geometry changed"
        )
        expect(
            input.descriptorOffset == 0
                && input.availableOffset == 1_024
                && input.usedOffset == 1_160
                && input.requiredByteCount == 1_678,
            "64-entry input queue geometry changed"
        )
        expect(
            maximum.size == VirtIOSplitQueueLayout.maximumSize,
            "maximum split queue size changed"
        )
        expect(
            VirtIOSplitQueueLayout(size: 0) == nil
                && VirtIOSplitQueueLayout(size: 3) == nil,
            "invalid split queue size was accepted"
        )
    }

    private static func partitionsOneTranslatedPage() {
        let token = makeToken(
            pageCount: VirtIOInputBootstrapMemory.pageCount,
            capabilities: coherentCapabilities
        )
        guard let workspace = VirtIOInputBootstrapMemory(
                  allocation: token,
                  deviceBaseAddress: 0x4000_0000,
                  deviceAddressWidth: .bits32,
                  coherency: .hardwareCoherent
              )
        else { fail("valid input workspace was rejected") }

        expect(workspace.allocation == token, "allocation ownership changed")
        expect(
            workspace.storage.eventQueue.cpuPhysicalAddress == 0x1000_0000
                && workspace.storage.eventQueue.deviceAddress == 0x4000_0000
                && workspace.storage.eventQueue.byteCount == 2_048,
            "event queue partition changed"
        )
        expect(
            workspace.storage.eventBuffers.cpuPhysicalAddress == 0x1000_0800
                && workspace.storage.eventBuffers.deviceAddress == 0x4000_0800
                && workspace.storage.eventBuffers.byteCount == 512,
            "event buffer partition changed"
        )
        expect(
            workspace.storage.eventQueueLayout.requiredByteCount <= 2_048,
            "event queue no longer fits its partition"
        )
    }

    private static func rejectsWrongAllocationShape() {
        expect(
            makeWorkspace(
                makeToken(
                    pageCount: 2,
                    capabilities: coherentCapabilities
                )
            ) == nil,
            "oversized allocation was accepted"
        )
        expect(
            makeWorkspace(
                makeToken(
                    identifier: 0,
                    pageCount: 1,
                    capabilities: coherentCapabilities
                )
            ) == nil,
            "unowned allocation was accepted"
        )
    }

    private static func enforcesCoherentDeviceMemory() {
        let cpuOnly = makeToken(
            pageCount: 1,
            capabilities: .cpuAccessible.union(.cacheCoherent)
        )
        expect(makeWorkspace(cpuOnly) == nil, "CPU-only memory was accepted")

        let deviceButNotCoherent = makeToken(
            pageCount: 1,
            capabilities: .cpuAccessible.union(.deviceAccessible)
        )
        expect(
            makeWorkspace(deviceButNotCoherent) == nil,
            "memory without cache-coherency capability was accepted"
        )
        expect(
            VirtIOInputBootstrapMemory(
                allocation: makeToken(
                    pageCount: 1,
                    capabilities: coherentCapabilities
                ),
                deviceBaseAddress: 0x4000_0000,
                deviceAddressWidth: .bits32,
                coherency: .softwareManaged
            ) == nil,
            "software-managed DMA was accepted without cache maintenance"
        )
    }

    private static func rejectsInvalidDeviceWindow() {
        let token = makeToken(
            pageCount: 1,
            capabilities: coherentCapabilities
        )
        expect(
            VirtIOInputBootstrapMemory(
                allocation: token,
                deviceBaseAddress: 0x4000_0001,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "unaligned device base was accepted"
        )
        expect(
            VirtIOInputBootstrapMemory(
                allocation: token,
                deviceBaseAddress: 0xffff_ffff_ffff_f000,
                deviceAddressWidth: .bits32,
                coherency: .hardwareCoherent
            ) == nil,
            "out-of-width device partition was accepted"
        )
    }

    private static var coherentCapabilities: PhysicalMemoryCapabilities {
        .cpuAccessible.union(.deviceAccessible).union(.cacheCoherent)
    }

    private static func makeWorkspace(
        _ token: ClassifiedPageAllocationToken
    ) -> VirtIOInputBootstrapMemory? {
        VirtIOInputBootstrapMemory(
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
