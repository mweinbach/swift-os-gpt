@main
struct MemoryFoundationTests {
    static func main() {
        testPhysicalRangeNormalizationAndReservation()
        testReservationCapacityIsAtomic()
        testRunAllocatorAtEightGiBScale()
        testAllocatorMetadataExhaustion()
        testPageTableDescriptorPermissions()
        testPageTablePageBuilderAndGuards()
        testAddressSpaceRegionsAndASIDs()
        print("memory foundation host tests: 7 groups passed")
    }

    private static func testPhysicalRangeNormalizationAndReservation() {
        var storage = Array(repeating: PhysicalPageRange.empty, count: 8)
        storage.withUnsafeMutableBufferPointer { buffer in
            var map = PhysicalMemoryMap(storage: buffer)
            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x4000_4000,
                    length: 0x2000
                ),
                "first DT range"
            )
            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x4000_0123,
                    length: 0x3f00
                ),
                "unaligned DT range"
            )
            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x4000_0000,
                    length: 0x1000
                ),
                "adjacent DT range"
            )
            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x8000_0000,
                    length: 0x3000
                ),
                "disjoint DT range"
            )
            expect(map.count == 2, "normalized region count")
            expect(
                map.range(at: 0)
                    == pageRange(base: 0x4000_0000, pages: 6),
                "merged low range"
            )
            expect(
                map.range(at: 1)
                    == pageRange(base: 0x8000_0000, pages: 3),
                "sorted high range"
            )
            expect(map.totalPageCount == 9, "normalized page total")

            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x9000_0001,
                    length: 100
                ),
                "sub-page DT tuple should be safely ignored"
            )
            expect(map.count == 2, "sub-page tuple changed map")
            expect(
                !map.addDeviceTreeMemory(
                    baseAddress: UInt64.max - 10,
                    length: 20
                ),
                "overflowing DT tuple accepted"
            )

            expect(
                map.reserve(baseAddress: 0x4000_1f00, length: 0x2100),
                "reserve middle pages"
            )
            expect(map.count == 3, "reservation split count")
            expect(
                map.range(at: 0)
                    == pageRange(base: 0x4000_0000, pages: 1),
                "reservation left fragment"
            )
            expect(
                map.range(at: 1)
                    == pageRange(base: 0x4000_4000, pages: 2),
                "reservation right fragment"
            )
            expect(
                map.range(at: 2)
                    == pageRange(base: 0x8000_0000, pages: 3),
                "reservation damaged disjoint region"
            )
            expect(map.totalPageCount == 6, "reserved page total")
            expect(
                map.reserve(baseAddress: 0x7000_0001, length: 7),
                "out-of-map reservation"
            )
            expect(map.count == 3, "out-of-map reservation changed map")
        }
    }

    private static func testReservationCapacityIsAtomic() {
        var storage = Array(repeating: PhysicalPageRange.empty, count: 1)
        storage.withUnsafeMutableBufferPointer { buffer in
            var map = PhysicalMemoryMap(storage: buffer)
            expect(
                map.addDeviceTreeMemory(baseAddress: 0x1000, length: 0xa000),
                "single-capacity map load"
            )
            let before = map.range(at: 0)
            expect(
                !map.reserve(baseAddress: 0x4000, length: 0x1000),
                "split exceeded metadata without error"
            )
            expect(map.count == 1, "failed split changed count")
            expect(map.range(at: 0) == before, "failed split changed range")
        }
    }

    private static func testRunAllocatorAtEightGiBScale() {
        let eightGiB: UInt64 = 8 * 1024 * 1024 * 1024
        var mapStorage = Array(repeating: PhysicalPageRange.empty, count: 4)
        var allocatorStorage = Array(repeating: PhysicalPageRange.empty, count: 8)
        mapStorage.withUnsafeMutableBufferPointer { mapBuffer in
            var map = PhysicalMemoryMap(storage: mapBuffer)
            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x4000_0000,
                    length: eightGiB
                ),
                "8 GiB DT range"
            )
            expect(map.count == 1, "8 GiB should use one metadata range")
            expect(
                map.totalPageCount == eightGiB / MemoryPageGeometry.pageSize,
                "8 GiB page count"
            )

            allocatorStorage.withUnsafeMutableBufferPointer { allocatorBuffer in
                var allocator = PhysicalPageAllocator(storage: allocatorBuffer)
                expect(allocator.load(from: map), "allocator load")
                let originalPageCount = allocator.totalFreePageCount

                let first = expectAllocation(
                    allocator.allocate(pageCount: 1),
                    "first page allocation"
                )
                expect(first.baseAddress == 0x4000_0000, "first-fit base")

                let aligned = expectAllocation(
                    allocator.allocate(
                        pageCount: 2,
                        alignmentInPages: 512
                    ),
                    "2 MiB-aligned allocation"
                )
                expect(aligned.baseAddress == 0x4020_0000, "aligned base")
                expect(allocator.freeRunCount == 2, "aligned split count")
                expect(
                    allocator.totalFreePageCount == originalPageCount - 3,
                    "allocation accounting"
                )

                expect(allocator.release(first), "release first page")
                expect(allocator.release(aligned), "release aligned pages")
                expect(allocator.freeRunCount == 1, "release did not coalesce")
                expect(
                    allocator.totalFreePageCount == originalPageCount,
                    "release accounting"
                )
                expect(!allocator.release(first), "double free accepted")
                expect(
                    allocator.allocate(pageCount: 0) == .invalidRequest,
                    "zero-page request"
                )
                expect(
                    allocator.allocate(pageCount: originalPageCount + 1)
                        == .outOfMemory,
                    "oversized request"
                )
            }
        }
    }

    private static func testAllocatorMetadataExhaustion() {
        var mapStorage = Array(repeating: PhysicalPageRange.empty, count: 1)
        var allocatorStorage = Array(repeating: PhysicalPageRange.empty, count: 1)
        mapStorage.withUnsafeMutableBufferPointer { mapBuffer in
            var map = PhysicalMemoryMap(storage: mapBuffer)
            expect(
                map.addDeviceTreeMemory(baseAddress: 0x1000, length: 0x3000),
                "metadata fixture"
            )
            allocatorStorage.withUnsafeMutableBufferPointer { allocatorBuffer in
                var allocator = PhysicalPageAllocator(storage: allocatorBuffer)
                expect(allocator.load(from: map), "metadata allocator load")
                expect(
                    allocator.allocate(pageCount: 1, alignmentInPages: 2)
                        == .metadataExhausted,
                    "unrepresentable split did not report metadata exhaustion"
                )
                expect(
                    allocator.totalFreePageCount == 3,
                    "metadata failure mutated allocator"
                )
            }
        }
    }

    private static func testPageTableDescriptorPermissions() {
        let text = descriptor(
            level: .level3,
            physical: 0x4008_0000,
            attributes: .kernelText
        )
        expect(attributeIndex(text) == 1, "kernel text memory type")
        expect(accessPermissions(text) == 0b10, "kernel text must be EL1 RO")
        expect(!bit(text, 53), "kernel text unexpectedly privileged-XN")
        expect(bit(text, 54), "kernel text must be user-XN")
        expect(!bit(text, 11), "kernel text must be global")

        let rodata = descriptor(
            level: .level3,
            physical: 0x4010_0000,
            attributes: .kernelReadOnlyData
        )
        expect(accessPermissions(rodata) == 0b10, "rodata write permission")
        expect(bit(rodata, 53) && bit(rodata, 54), "rodata must be NX")

        for attributes in [PageMappingAttributes.kernelData, .kernelHeap] {
            let data = descriptor(
                level: .level3,
                physical: 0x4020_0000,
                attributes: attributes
            )
            expect(accessPermissions(data) == 0, "kernel RW AP bits")
            expect(bit(data, 53) && bit(data, 54), "kernel RW must be NX")
        }

        let device = descriptor(
            level: .level3,
            physical: 0x0900_0000,
            attributes: .kernelDevice
        )
        expect(attributeIndex(device) == 0, "device AttrIndx")
        expect((device >> 8) & 0b11 == 0b10, "device shareability")
        expect(bit(device, 53) && bit(device, 54), "device mapping must be NX")

        let userText = descriptor(
            level: .level3,
            physical: 0x5000_0000,
            attributes: .userText
        )
        expect(accessPermissions(userText) == 0b11, "user text AP bits")
        expect(bit(userText, 11), "user text must be non-global")
        expect(bit(userText, 53) && !bit(userText, 54), "user text XN bits")

        let userData = descriptor(
            level: .level3,
            physical: 0x5000_1000,
            attributes: .userData
        )
        expect(accessPermissions(userData) == 0b01, "user data AP bits")
        expect(bit(userData, 53) && bit(userData, 54), "user data must be NX")

        let block = descriptor(
            level: .level2,
            physical: 0x6000_0000,
            attributes: .kernelData
        )
        expect(block & 0b11 == 0b01, "L2 block descriptor type")
        expect(
            PageTableDescriptor.leaf(
                level: .level0,
                physicalAddress: 0,
                attributes: .kernelData
            ) == nil,
            "L0 block accepted"
        )
        expect(
            PageTableDescriptor.leaf(
                level: .level2,
                physicalAddress: 0x6000_1000,
                attributes: .kernelData
            ) == nil,
            "misaligned L2 block accepted"
        )

        let writableExecutable = PageMappingAttributes(
            memoryType: .normal,
            writable: true,
            userAccessible: false,
            privilegedExecutable: true,
            userExecutable: false,
            global: true
        )
        expect(
            PageTableDescriptor.leaf(
                level: .level3,
                physicalAddress: 0x7000_0000,
                attributes: writableExecutable
            ) == nil,
            "W+X mapping accepted"
        )

        let table = PageTableDescriptor.nextLevelTable(at: 0x1234_5000)
        expect(table?.rawValue == 0x1234_5003, "table descriptor encoding")
        expect(!PageTableDescriptor.guardPage.isValid, "guard is valid")
        expect(PageTableDescriptor.guardPage.isGuard, "guard marker lost")
        expect(!PageTableDescriptor.unmapped.isGuard, "unmapped is guard")
    }

    private static func testPageTablePageBuilderAndGuards() {
        var entries = Array(repeating: UInt64.max, count: 512)
        entries.withUnsafeMutableBufferPointer { buffer in
            guard var builder = PageTablePageBuilder(entries: buffer) else {
                fatalError("valid table buffer rejected")
            }
            builder.clear()
            expect(buffer.allSatisfy { $0 == 0 }, "table clear")

            let highAddress: UInt64 = 0xffff_8000_0000_0000
            expect(
                builder.installNextLevelTable(
                    for: highAddress,
                    level: .level0,
                    at: 0x4100_0000
                ),
                "high-half table link"
            )
            expect(
                builder.descriptor(for: highAddress, level: .level0)?.rawValue
                    == 0x4100_0003,
                "linked table descriptor"
            )

            expect(
                builder.installMapping(
                    for: 0x4000,
                    level: .level3,
                    physicalAddress: 0x5000_0000,
                    role: .userData
                ),
                "user page mapping"
            )
            expect(
                builder.descriptor(for: 0x4000, level: .level3)?.isValid == true,
                "mapped descriptor missing"
            )
            expect(
                !builder.installGuard(for: 0x4000, level: .level3),
                "valid mapping overwritten by guard"
            )
            expect(
                builder.installGuard(for: 0x5000, level: .level3),
                "guard install"
            )
            expect(
                builder.descriptor(for: 0x5000, level: .level3)?.isGuard == true,
                "guard descriptor missing"
            )
            expect(
                !builder.installMapping(
                    for: 0x5000,
                    level: .level3,
                    physicalAddress: 0x5000_1000,
                    role: .userData
                ),
                "guard overwritten without explicit unmap"
            )
            expect(
                builder.unmap(virtualAddress: 0x5000, level: .level3),
                "guard unmap"
            )
            expect(
                builder.descriptor(for: 0x5000, level: .level3)
                    == .unmapped,
                "unmapped descriptor retained state"
            )
            expect(
                !builder.installMapping(
                    for: 0x0000_8000_0000_0000,
                    level: .level3,
                    physicalAddress: 0x5000_0000,
                    role: .userData
                ),
                "noncanonical virtual address accepted"
            )

            let region = VirtualMemoryRegion.mapping(
                virtualBaseAddress: 0x8000,
                physicalBaseAddress: 0x6000_0000,
                pageCount: 2,
                role: .userText
            )!
            expect(
                builder.install(region: region, at: 0x9000, level: .level3),
                "region-backed mapping"
            )
            let expected = PageTableDescriptor.leaf(
                level: .level3,
                physicalAddress: 0x6000_1000,
                attributes: .userText
            )
            expect(
                builder.descriptor(for: 0x9000, level: .level3) == expected,
                "region physical offset"
            )

            let guardRegion = VirtualMemoryRegion.guardPages(
                virtualBaseAddress: 0xa000,
                pageCount: 1
            )!
            expect(
                builder.install(
                    region: guardRegion,
                    at: 0xa000,
                    level: .level3
                ),
                "region-backed guard"
            )
        }
    }

    private static func testAddressSpaceRegionsAndASIDs() {
        expect(
            AddressSpaceIdentifierAllocator(bitWidth: 7) == nil,
            "invalid ASID width"
        )
        var allocator = AddressSpaceIdentifierAllocator(bitWidth: 8)!
        let first = allocator.allocate()
        expect(first.identifier.value == 1, "first ASID")
        expect(!first.requiresGlobalTLBFlush, "first ASID flush")
        var allocation = first
        var issued = 1
        while issued < 255 {
            allocation = allocator.allocate()
            expect(!allocation.requiresGlobalTLBFlush, "early ASID flush")
            issued += 1
        }
        expect(allocation.identifier.value == 255, "last generation-zero ASID")
        expect(allocator.isCurrent(first.identifier), "current ASID rejected")
        let wrapped = allocator.allocate()
        expect(wrapped.identifier.value == 1, "wrapped ASID value")
        expect(wrapped.identifier.generation == 1, "wrapped ASID generation")
        expect(wrapped.requiresGlobalTLBFlush, "ASID wrap omitted flush")
        expect(!allocator.isCurrent(first.identifier), "stale ASID is current")
        expect(allocator.isCurrent(wrapped.identifier), "new ASID is stale")

        let kernel = AddressSpaceMetadata(
            kind: .kernel,
            rootTablePhysicalAddress: 0x4100_0000,
            identifier: .kernel
        )
        expect(kernel != nil, "kernel address-space metadata")
        expect(
            AddressSpaceMetadata(
                kind: .user,
                rootTablePhysicalAddress: 0x4200_0000,
                identifier: wrapped.identifier
            )?.translationTableBaseRegisterValue
                == (UInt64(1) << 48 | 0x4200_0000),
            "user TTBR encoding"
        )
        expect(
            AddressSpaceMetadata(
                kind: .user,
                rootTablePhysicalAddress: 0x4200_0001,
                identifier: wrapped.identifier
            ) == nil,
            "misaligned root table accepted"
        )

        expect(
            VirtualMemoryRegion.mapping(
                virtualBaseAddress: 0x0000_7fff_ffff_f000,
                physicalBaseAddress: 0x5000_0000,
                pageCount: 2,
                role: .userData
            ) == nil,
            "mapping crossed canonical-address hole"
        )
        expect(
            VirtualMemoryRegion.mapping(
                virtualBaseAddress: 0x4000,
                physicalBaseAddress: 0x5000_0001,
                pageCount: 1,
                role: .userData
            ) == nil,
            "unaligned physical mapping"
        )

        var regionStorage = Array(repeating: VirtualMemoryRegion.empty, count: 4)
        regionStorage.withUnsafeMutableBufferPointer { buffer in
            var table = AddressSpaceRegionTable(storage: buffer)
            let data = VirtualMemoryRegion.mapping(
                virtualBaseAddress: 0x4000,
                physicalBaseAddress: 0x5000_0000,
                pageCount: 2,
                role: .userData
            )!
            let text = VirtualMemoryRegion.mapping(
                virtualBaseAddress: 0x1000,
                physicalBaseAddress: 0x6000_0000,
                pageCount: 1,
                role: .userText
            )!
            let guardPage = VirtualMemoryRegion.guardPages(
                virtualBaseAddress: 0x3000,
                pageCount: 1
            )!
            expect(table.insert(data), "insert data metadata")
            expect(table.insert(text), "insert text metadata")
            expect(table.insert(guardPage), "insert guard metadata")
            expect(table.count == 3, "region metadata count")
            expect(table.region(at: 0) == text, "region sort order")
            expect(
                table.region(containing: 0x5000)?.physicalAddress(for: 0x5000)
                    == 0x5000_1000,
                "region lookup and physical translation"
            )
            let overlap = VirtualMemoryRegion.guardPages(
                virtualBaseAddress: 0x5000,
                pageCount: 2
            )!
            expect(!table.insert(overlap), "overlapping region accepted")
            expect(
                table.unmap(virtualBaseAddress: 0x3000, pageCount: 1),
                "exact unmap"
            )
            expect(
                table.region(containing: 0x3000) == nil,
                "unmapped region still present"
            )
        }
    }
}

private func pageRange(base: UInt64, pages: UInt64) -> PhysicalPageRange {
    guard let range = PhysicalPageRange(baseAddress: base, pageCount: pages) else {
        fatalError("invalid test page range")
    }
    return range
}

private func expectAllocation(
    _ result: PageAllocationResult,
    _ message: String
) -> PhysicalPageRange {
    guard case let .allocated(range) = result else {
        fatalError("\(message): \(result)")
    }
    return range
}

private func descriptor(
    level: PageTableLevel,
    physical: UInt64,
    attributes: PageMappingAttributes
) -> UInt64 {
    guard let descriptor = PageTableDescriptor.leaf(
        level: level,
        physicalAddress: physical,
        attributes: attributes
    ) else {
        fatalError("descriptor fixture rejected")
    }
    return descriptor.rawValue
}

private func attributeIndex(_ descriptor: UInt64) -> UInt64 {
    (descriptor >> 2) & 0b111
}

private func accessPermissions(_ descriptor: UInt64) -> UInt64 {
    (descriptor >> 6) & 0b11
}

private func bit(_ value: UInt64, _ index: UInt64) -> Bool {
    value & (1 << index) != 0
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}
