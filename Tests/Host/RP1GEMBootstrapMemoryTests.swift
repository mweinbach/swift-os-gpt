// The production definition is supplied by LinkerLayout.swift. This host-only
// stand-in keeps the partitioner test independent of bare-metal linker symbols.
struct LinkerRegion: Equatable {
    let start: UInt64
    let end: UInt64

    var length: UInt64 {
        end >= start ? end - start : 0
    }
}

private final class AlignedWorkspace {
    let pointer: UnsafeMutableRawPointer

    init() {
        pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(RP1GEMBootstrapMemory.workspaceByteCount),
            alignment: Int(MemoryPageGeometry.pageSize)
        )
        pointer.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: Int(RP1GEMBootstrapMemory.workspaceByteCount)
        )
    }

    deinit {
        pointer.deallocate()
    }

    var address: UInt64 {
        UInt64(UInt(bitPattern: pointer))
    }
}

@main
struct RP1GEMBootstrapMemoryTests {
    static func main() {
        partitionsOneNonCacheableAndThreeWriteBackPages()
        rejectsInvalidCPUToDeviceTranslations()
        encodesNormalNonCacheablePageAttributes()
        rejectsPhysicalCacheabilityAliases()
        print("RP1 GEM bootstrap memory: 4 groups passed")
    }

    private static func partitionsOneNonCacheableAndThreeWriteBackPages() {
        let allocation = AlignedWorkspace()
        let deviceBase: UInt64 = 0x4000_0000
        guard let workspace = RP1GEMBootstrapMemory(
                  cpuBaseAddress: allocation.address,
                  byteCount: RP1GEMBootstrapMemory.workspaceByteCount,
                  deviceBaseAddress: deviceBase,
                  deviceAddressWidth: .bits32
              )
        else {
            fail("valid translated RP1 workspace rejected")
        }

        expect(
            workspace.descriptorPage.start == allocation.address
                && workspace.descriptorPage.length == 0x1000,
            "descriptor page boundary changed"
        )
        expect(
            workspace.cacheablePages.start == allocation.address + 0x1000
                && workspace.cacheablePages.length == 0x3000,
            "cacheable page boundary changed"
        )
        let storage = workspace.storage
        expect(
            storage.receiveDescriptorCount == 2
                && storage.transmitDescriptorCount == 2
                && storage.receiveDescriptors.cpuCacheMode == .uncached
                && storage.receiveDescriptors.mapping.cpuPhysicalAddress
                    == allocation.address
                && storage.receiveDescriptors.mapping.deviceAddress
                    == deviceBase
                && storage.receiveDescriptors.mapping.byteCount == 64,
            "receive descriptor partition mismatch"
        )
        expect(
            storage.transmitDescriptors.cpuCacheMode == .uncached
                && storage.transmitDescriptors.mapping.cpuPhysicalAddress
                    == allocation.address + 64
                && storage.transmitDescriptors.mapping.deviceAddress
                    == deviceBase + 64,
            "transmit descriptor partition mismatch"
        )
        expect(
            storage.receiveBuffers.cpuCacheMode == .writeBack
                && storage.receiveBuffers.mapping.cpuPhysicalAddress
                    == allocation.address + 0x1000
                && storage.receiveBuffers.mapping.deviceAddress
                    == deviceBase + 0x1000
                && storage.receiveBuffers.mapping.byteCount == 0x0c00,
            "receive packet-buffer partition mismatch"
        )
        expect(
            storage.transmitBuffers.cpuCacheMode == .writeBack
                && storage.transmitBuffers.mapping.cpuPhysicalAddress
                    == allocation.address + 0x1c00
                && storage.transmitBuffers.mapping.deviceAddress
                    == deviceBase + 0x1c00
                && storage.transmitBuffers.mapping.byteCount == 0x0c00,
            "transmit packet-buffer partition mismatch"
        )
        expect(
            storage.receiveDescriptors.mapping.coherency == .softwareManaged
                && storage.receiveBuffers.mapping.coherency == .softwareManaged,
            "RP1 DMA memory claimed hardware coherency"
        )
        expect(
            workspace.receiveScratchAddress == allocation.address + 0x2800
                && workspace.transmitScratchAddress
                    == allocation.address + 0x2e00
                && RP1GEMBootstrapMemory.scratchByteCount == 1_536,
            "disjoint IPv4 scratch partition mismatch"
        )
        expect(
            workspace.receiveScratchAddress
                    + RP1GEMBootstrapMemory.scratchByteCount
                <= workspace.transmitScratchAddress,
            "IPv4 scratch aliases"
        )
    }

    private static func rejectsInvalidCPUToDeviceTranslations() {
        let allocation = AlignedWorkspace()
        expect(
            makeWorkspace(
                allocation,
                byteCount: RP1GEMBootstrapMemory.workspaceByteCount - 0x1000
            ) == nil,
            "short workspace accepted"
        )
        expect(
            RP1GEMBootstrapMemory(
                cpuBaseAddress: allocation.address + 1,
                byteCount: RP1GEMBootstrapMemory.workspaceByteCount,
                deviceBaseAddress: 0x4000_0000,
                deviceAddressWidth: .bits32
            ) == nil,
            "unaligned CPU base accepted"
        )
        expect(
            makeWorkspace(allocation, deviceBaseAddress: 0x4000_0001) == nil,
            "unaligned device translation accepted"
        )
        expect(
            makeWorkspace(allocation, deviceBaseAddress: 0xffff_f000) == nil,
            "32-bit-crossing device translation accepted"
        )
    }

    private static func encodesNormalNonCacheablePageAttributes() {
        let attributes = MemoryRegionRole.kernelNonCacheableData.attributes
        expect(
            attributes.memoryType == .normalNonCacheable,
            "non-cacheable role used the wrong MAIR index"
        )
        expect(
            attributes.writable
                && !attributes.userAccessible
                && !attributes.privilegedExecutable
                && !attributes.userExecutable,
            "non-cacheable role is not privileged RW/NX"
        )
        guard let descriptor = PageTableDescriptor.leaf(
                  level: .level3,
                  physicalAddress: 0x0020_0000,
                  attributes: attributes
              )
        else {
            fail("valid non-cacheable descriptor rejected")
        }
        expect(
            descriptor.rawValue >> 2 & 7 == 2,
            "descriptor did not select MAIR Attr2"
        )
        expect(
            descriptor.rawValue >> 8 & 3 == 3,
            "normal non-cacheable page is not inner-shareable"
        )
        expect(
            descriptor.rawValue & (1 << 6) == 0
                && descriptor.rawValue & (1 << 7) == 0
                && descriptor.rawValue & (1 << 53) != 0
                && descriptor.rawValue & (1 << 54) != 0,
            "descriptor permission bits are not privileged RW/NX"
        )
    }

    private static func rejectsPhysicalCacheabilityAliases() {
        let nonCacheable = FinalMappingRegion(
            virtualBaseAddress: 0x0020_0000,
            physicalBaseAddress: 0x0020_0000,
            pageCount: 1,
            role: .kernelNonCacheableData
        )!
        expect(
            build(dataRegions: [nonCacheable], freeRange: nil).isBuilt,
            "unique non-cacheable mapping was rejected"
        )

        let writeBackAlias = FinalMappingRegion(
            virtualBaseAddress: 0x0040_0000,
            physicalBaseAddress: 0x0020_0000,
            pageCount: 1,
            role: .kernelData
        )!
        expect(
            build(
                dataRegions: [nonCacheable, writeBackAlias],
                freeRange: nil
            ) == .failed(.invalidLayout),
            "write-back alias of descriptor physical page was accepted"
        )
        expect(
            build(
                dataRegions: [nonCacheable],
                freeRange: PhysicalPageRange(
                    baseAddress: 0x0020_0000,
                    pageCount: 1
                )!
            ) == .failed(.invalidLayout),
            "descriptor physical page remained in the direct-map free list"
        )
    }

    private static func makeWorkspace(
        _ allocation: AlignedWorkspace,
        byteCount: UInt64 = RP1GEMBootstrapMemory.workspaceByteCount,
        deviceBaseAddress: UInt64 = 0x4000_0000
    ) -> RP1GEMBootstrapMemory? {
        RP1GEMBootstrapMemory(
            cpuBaseAddress: allocation.address,
            byteCount: byteCount,
            deviceBaseAddress: deviceBaseAddress,
            deviceAddressWidth: .bits32
        )
    }

    private static func build(
        dataRegions: [FinalMappingRegion],
        freeRange: PhysicalPageRange?
    ) -> FinalTranslationTableBuildResult {
        let tablePageCount = 8
        let tableBytes = tablePageCount * Int(MemoryPageGeometry.pageSize)
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: tableBytes,
            alignment: Int(MemoryPageGeometry.pageSize)
        )
        defer { pointer.deallocate() }
        let entries = UnsafeMutableBufferPointer(
            start: pointer.bindMemory(
                to: UInt64.self,
                capacity: tableBytes / MemoryLayout<UInt64>.stride
            ),
            count: tableBytes / MemoryLayout<UInt64>.stride
        )
        var pool = FinalTranslationTablePagePool(
            physicalBaseAddress: 0x0100_0000,
            pageCount: tablePageCount,
            mappedEntries: entries
        )!

        var freeStorage = Array(repeating: PhysicalPageRange.empty, count: 2)
        return freeStorage.withUnsafeMutableBufferPointer { freeBuffer in
            var freeMemory = PhysicalMemoryMap(storage: freeBuffer)
            if let freeRange {
                guard freeMemory.addDeviceTreeMemory(
                    baseAddress: freeRange.baseAddress,
                    length: freeRange.byteCount
                ) else {
                    fail("free-range fixture rejected")
                }
            }
            let emptyMappings: [FinalMappingRegion] = []
            let emptyGuards: [FinalGuardRegion] = []
            return dataRegions.withUnsafeBufferPointer { dataBuffer in
                emptyMappings.withUnsafeBufferPointer { emptyBuffer in
                    emptyGuards.withUnsafeBufferPointer { guardBuffer in
                        let layout = FinalAddressSpaceLayout(
                            kind: .kernel,
                            identifier: .kernel,
                            kernelText: nil,
                            kernelReadOnlyDataRegions: emptyBuffer,
                            kernelDataRegions: dataBuffer,
                            userText: nil,
                            userReadOnlyData: nil,
                            userStacks: emptyBuffer,
                            mmioRegions: emptyBuffer,
                            guardRegions: guardBuffer
                        )
                        return FinalTranslationTableBuilder.build(
                            availablePhysicalMemory: freeMemory,
                            layout: layout,
                            pool: &pool
                        )
                    }
                }
            }
        }
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

private extension FinalTranslationTableBuildResult {
    var isBuilt: Bool {
        if case .built = self { return true }
        return false
    }
}
