@main
struct ClassifiedPhysicalMemoryTests {
    static func main() {
        testCapabilitiesModelCPUInaccessibleMemory()
        testNormalizedMapLoadIsAtomicAndClassified()
        testClassificationControlsMergingAndOverlapValidation()
        testReservationsPreserveClassificationAndAreAtomic()
        testConstrainedAllocationAndExplicitDomainFallback()
        testMaximumAddressAndMetadataFailuresAreAtomic()
        testOwnershipTokensValidateRelease()
        print("classified physical memory host tests: 7 groups passed")
    }

    private static let systemDomain = PhysicalMemoryAllocationDomain(1)
    private static let graphicsDomain = PhysicalMemoryAllocationDomain(2)
    private static let acceleratorDomain = PhysicalMemoryAllocationDomain(3)

    private static let cpuProximity = PhysicalMemoryProximityDomain(0)
    private static let graphicsProximity = PhysicalMemoryProximityDomain(1)

    private static let systemMemory = PhysicalMemoryClassification(
        allocationDomain: systemDomain,
        capabilities: PhysicalMemoryCapabilities.cpuAccessible
            .union(.deviceReadable)
            .union(.deviceWritable)
            .union(.cacheCoherent),
        proximityDomain: cpuProximity
    )
    private static let graphicsMemory = PhysicalMemoryClassification(
        allocationDomain: graphicsDomain,
        capabilities: .deviceAccessible,
        proximityDomain: graphicsProximity
    )
    private static let acceleratorMemory = PhysicalMemoryClassification(
        allocationDomain: acceleratorDomain,
        capabilities: .cpuAccessible,
        proximityDomain: PhysicalMemoryProximityDomain(2)
    )
    private static let remoteSystemMemory = PhysicalMemoryClassification(
        allocationDomain: systemDomain,
        capabilities: systemMemory.capabilities,
        proximityDomain: PhysicalMemoryProximityDomain(42)
    )

    private static func testCapabilitiesModelCPUInaccessibleMemory() {
        expect(
            systemMemory.capabilities.contains(.cpuReadable),
            "system memory lost CPU read capability"
        )
        expect(
            graphicsMemory.capabilities.contains(.deviceAccessible),
            "device-local memory lost device access"
        )
        expect(
            !graphicsMemory.capabilities.contains(.cpuReadable),
            "device-local memory unexpectedly became CPU-readable"
        )
        expect(
            graphicsMemory.allocationDomain != systemMemory.allocationDomain,
            "allocation domains collapsed"
        )
        expect(
            graphicsMemory.proximityDomain == graphicsProximity,
            "proximity metadata was not retained"
        )
    }

    private static func testNormalizedMapLoadIsAtomicAndClassified() {
        var mapStorage = Array(
            repeating: PhysicalPageRange.empty,
            count: 4
        )
        mapStorage.withUnsafeMutableBufferPointer { mapBuffer in
            var map = PhysicalMemoryMap(storage: mapBuffer)
            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x1000,
                    length: 0x4000
                ),
                "classified map low fixture"
            )
            expect(
                map.addDeviceTreeMemory(
                    baseAddress: 0x1_0000,
                    length: 0x2000
                ),
                "classified map high fixture"
            )

            withAllocator(freeCapacity: 4, allocationCapacity: 2) {
                allocator, _, _ in
                expect(
                    allocator.load(
                        from: map,
                        classification: systemMemory
                    ),
                    "normalized map load"
                )
                expect(allocator.freeRunCount == 2, "loaded map run count")
                expect(
                    allocator.totalFreePageCount == 6,
                    "loaded map page accounting"
                )
                expect(
                    allocator.freeRun(at: 0)?.classification == systemMemory,
                    "loaded map classification"
                )

                _ = expectAllocation(
                    allocator.allocate(
                        ClassifiedPageAllocationConstraints(pageCount: 1)
                    ),
                    "loaded map allocation"
                )
                let runsBeforeRejectedLoad = snapshot(allocator)
                let activeBeforeRejectedLoad = allocator.activeAllocation(at: 0)
                expect(
                    !allocator.load(
                        from: map,
                        classification: graphicsMemory
                    ),
                    "map reload revoked active allocation"
                )
                expect(
                    snapshot(allocator) == runsBeforeRejectedLoad,
                    "rejected map reload changed free runs"
                )
                expect(
                    allocator.activeAllocation(at: 0)
                        == activeBeforeRejectedLoad,
                    "rejected map reload changed ownership"
                )
            }
        }
    }

    private static func testClassificationControlsMergingAndOverlapValidation() {
        withAllocator(freeCapacity: 8, allocationCapacity: 4) {
            allocator, _, _ in
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 2),
                    classification: systemMemory
                ) == .inserted,
                "system range insertion"
            )
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x3000, pages: 2),
                    classification: graphicsMemory
                ) == .inserted,
                "device-local range insertion"
            )
            expect(
                allocator.freeRunCount == 2,
                "differently classified adjacent ranges merged"
            )
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x5000, pages: 1),
                    classification: remoteSystemMemory
                ) == .inserted,
                "remote-proximity range insertion"
            )
            expect(
                allocator.freeRunCount == 3,
                "proximity-only classification difference was merged"
            )

            expect(
                allocator.addFreeRange(
                    pageRange(base: 0, pages: 1),
                    classification: systemMemory
                ) == .inserted,
                "same-class adjacency insertion"
            )
            expect(
                allocator.freeRun(at: 0)
                    == classifiedRange(
                        base: 0,
                        pages: 3,
                        classification: systemMemory
                    ),
                "same-class adjacent ranges did not normalize"
            )

            let before = snapshot(allocator)
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x2000, pages: 2),
                    classification: acceleratorMemory
                ) == .conflictingClassification,
                "conflicting overlap was accepted"
            )
            expect(
                snapshot(allocator) == before,
                "conflicting overlap partially mutated free runs"
            )

            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 1),
                    classification: systemMemory
                ) == .inserted,
                "same-class duplicate range was rejected"
            )
            expect(
                snapshot(allocator) == before,
                "same-class duplicate changed normalized runs"
            )
        }
    }

    private static func testReservationsPreserveClassificationAndAreAtomic() {
        withAllocator(freeCapacity: 5, allocationCapacity: 2) {
            allocator, _, _ in
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 8),
                    classification: systemMemory
                ) == .inserted,
                "reservation system fixture"
            )
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x9000, pages: 4),
                    classification: graphicsMemory
                ) == .inserted,
                "reservation graphics fixture"
            )
            expect(
                allocator.reserve(
                    baseAddress: 0x3f00,
                    length: 0x2200
                ) == .reserved,
                "unaligned reservation failed"
            )
            expect(allocator.freeRunCount == 3, "reservation split count")
            expect(
                allocator.freeRun(at: 0)
                    == classifiedRange(
                        base: 0x1000,
                        pages: 2,
                        classification: systemMemory
                    ),
                "reservation left classification"
            )
            expect(
                allocator.freeRun(at: 1)
                    == classifiedRange(
                        base: 0x7000,
                        pages: 2,
                        classification: systemMemory
                    ),
                "reservation right classification"
            )
            expect(
                allocator.freeRun(at: 2)?.classification == graphicsMemory,
                "reservation damaged adjacent classification"
            )
        }

        withAllocator(freeCapacity: 1, allocationCapacity: 1) {
            allocator, _, _ in
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 5),
                    classification: systemMemory
                ) == .inserted,
                "atomic reservation fixture"
            )
            let before = snapshot(allocator)
            expect(
                allocator.reserve(baseAddress: 0x3000, length: 0x1000)
                    == .metadataExhausted,
                "unrepresentable reservation did not exhaust metadata"
            )
            expect(
                snapshot(allocator) == before,
                "failed reservation partially mutated free runs"
            )
        }
    }

    private static func testConstrainedAllocationAndExplicitDomainFallback() {
        withAllocator(freeCapacity: 12, allocationCapacity: 8) {
            allocator, _, _ in
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 15),
                    classification: systemMemory
                ) == .inserted,
                "constraint system fixture"
            )
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1_0000, pages: 16),
                    classification: acceleratorMemory
                ) == .inserted,
                "constraint accelerator fixture"
            )
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x2_0000, pages: 16),
                    classification: graphicsMemory
                ) == .inserted,
                "constraint device fixture"
            )

            let preferred = expectAllocation(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(
                        pageCount: 2,
                        alignmentInPages: 4,
                        requiredCapabilities: .cpuWritable,
                        domainSelection: .preferred(
                            acceleratorDomain,
                            fallback: .disallowed
                        )
                    )
                ),
                "preferred accelerator allocation"
            )
            expect(
                preferred.range.baseAddress == 0x1_0000,
                "preferred domain alignment"
            )
            expect(
                preferred.owningDomain == acceleratorDomain,
                "preferred allocation used another domain"
            )
            expect(
                preferred.classification.proximityDomain
                    == PhysicalMemoryProximityDomain(2),
                "allocation token lost proximity"
            )

            let beforeNoFallback = allocator.totalFreePageCount
            expect(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(
                        pageCount: 1,
                        requiredCapabilities: .cpuReadable,
                        domainSelection: .preferred(
                            graphicsDomain,
                            fallback: .disallowed
                        )
                    )
                ) == .outOfMemory,
                "forbidden domain fallback occurred"
            )
            expect(
                allocator.totalFreePageCount == beforeNoFallback,
                "failed preferred allocation consumed pages"
            )

            let fallback = expectAllocation(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(
                        pageCount: 1,
                        requiredCapabilities: .cpuReadable,
                        domainSelection: .preferred(
                            graphicsDomain,
                            fallback: .allowed
                        )
                    )
                ),
                "explicit domain fallback"
            )
            expect(
                fallback.owningDomain == systemDomain,
                "fallback did not use deterministic lowest CPU domain"
            )

            let deviceLocal = expectAllocation(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(
                        pageCount: 3,
                        requiredCapabilities: .deviceAccessible,
                        domainSelection: .preferred(
                            graphicsDomain,
                            fallback: .disallowed
                        )
                    )
                ),
                "device-local allocation"
            )
            expect(
                deviceLocal.owningDomain == graphicsDomain,
                "device-local request escaped its domain"
            )
            expect(
                !deviceLocal.classification.capabilities.contains(.cpuReadable),
                "device-local token fabricated CPU access"
            )
        }
    }

    private static func testMaximumAddressAndMetadataFailuresAreAtomic() {
        withAllocator(freeCapacity: 3, allocationCapacity: 2) {
            allocator, _, _ in
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 8),
                    classification: systemMemory
                ) == .inserted,
                "maximum-address fixture"
            )
            let before = snapshot(allocator)
            expect(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(
                        pageCount: 2,
                        alignmentInPages: 4,
                        maximumAddress: 0x4fff,
                        requiredCapabilities: .cpuReadable
                    )
                ) == .outOfMemory,
                "allocation crossed maximum address"
            )
            expect(
                snapshot(allocator) == before,
                "maximum-address failure changed runs"
            )

            let bounded = expectAllocation(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(
                        pageCount: 2,
                        alignmentInPages: 4,
                        maximumAddress: 0x5fff,
                        requiredCapabilities: .cpuReadable
                    )
                ),
                "bounded aligned allocation"
            )
            expect(
                bounded.range.baseAddress == 0x4000,
                "bounded allocation start"
            )
            expect(
                bounded.range.endAddress - 1 == 0x5fff,
                "bounded allocation end"
            )
        }

        withAllocator(freeCapacity: 1, allocationCapacity: 1) {
            allocator, _, _ in
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 3),
                    classification: systemMemory
                ) == .inserted,
                "split metadata fixture"
            )
            let before = snapshot(allocator)
            expect(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(
                        pageCount: 1,
                        alignmentInPages: 2
                    )
                ) == .metadataExhausted,
                "unrepresentable allocation split was not reported"
            )
            expect(
                snapshot(allocator) == before,
                "failed allocation split changed free runs"
            )
            expect(
                allocator.activeAllocationCount == 0,
                "failed allocation minted ownership"
            )
        }
    }

    private static func testOwnershipTokensValidateRelease() {
        withAllocator(freeCapacity: 6, allocationCapacity: 4) {
            allocator, freeStorage, _ in
            expect(
                allocator.addFreeRange(
                    pageRange(base: 0x1000, pages: 8),
                    classification: systemMemory
                ) == .inserted,
                "ownership fixture"
            )
            let originalPageCount = allocator.totalFreePageCount
            let token = expectAllocation(
                allocator.allocate(
                    ClassifiedPageAllocationConstraints(pageCount: 2)
                ),
                "owned allocation"
            )
            expect(
                token.classification == systemMemory,
                "allocation token lost classification"
            )

            let wrongClass = ClassifiedPageAllocationToken(
                identifier: token.identifier,
                range: token.range,
                classification: graphicsMemory
            )
            expect(
                allocator.release(wrongClass) == .tokenMismatch,
                "wrong-class release succeeded"
            )
            expect(
                allocator.activeAllocationCount == 1,
                "wrong-class release dropped ownership"
            )
            expect(
                allocator.addFreeRange(
                    token.range,
                    classification: token.classification
                ) == .overlapsActiveAllocation,
                "active allocation was reintroduced as free"
            )
            expect(
                allocator.reserve(
                    baseAddress: token.range.baseAddress,
                    length: token.range.byteCount
                ) == .overlapsActiveAllocation,
                "reservation revoked active ownership"
            )

            let validSuffix = freeStorage[0]
            freeStorage[0] = classifiedRange(
                base: token.range.baseAddress,
                pages: 3,
                classification: systemMemory
            )
            expect(
                allocator.release(token) == .freeRangeOverlap,
                "overlapping release corrupted the free list"
            )
            expect(
                allocator.activeAllocationCount == 1,
                "overlapping release dropped ownership"
            )
            freeStorage[0] = validSuffix

            expect(
                allocator.release(token) == .released,
                "valid ownership release"
            )
            expect(
                allocator.activeAllocationCount == 0,
                "released allocation remained active"
            )
            expect(
                allocator.totalFreePageCount == originalPageCount,
                "release accounting"
            )
            expect(
                allocator.freeRunCount == 1,
                "same-class release did not coalesce"
            )
            expect(
                allocator.release(token) == .unknownAllocation,
                "double release succeeded"
            )
        }
    }

    private static func withAllocator(
        freeCapacity: Int,
        allocationCapacity: Int,
        _ body: (
            inout ClassifiedPhysicalMemoryAllocator,
            UnsafeMutableBufferPointer<ClassifiedPhysicalPageRange>,
            UnsafeMutableBufferPointer<ClassifiedPageAllocationToken>
        ) -> Void
    ) {
        var freeStorage = Array(
            repeating: ClassifiedPhysicalPageRange.empty,
            count: freeCapacity
        )
        var allocationStorage = Array(
            repeating: ClassifiedPageAllocationToken.empty,
            count: allocationCapacity
        )
        freeStorage.withUnsafeMutableBufferPointer { freeBuffer in
            allocationStorage.withUnsafeMutableBufferPointer {
                allocationBuffer in
                var allocator = ClassifiedPhysicalMemoryAllocator(
                    freeStorage: freeBuffer,
                    allocationStorage: allocationBuffer
                )
                body(&allocator, freeBuffer, allocationBuffer)
            }
        }
    }

    private static func snapshot(
        _ allocator: ClassifiedPhysicalMemoryAllocator
    ) -> [ClassifiedPhysicalPageRange] {
        var ranges: [ClassifiedPhysicalPageRange] = []
        var index = 0
        while let range = allocator.freeRun(at: index) {
            ranges.append(range)
            index += 1
        }
        return ranges
    }

    private static func classifiedRange(
        base: UInt64,
        pages: UInt64,
        classification: PhysicalMemoryClassification
    ) -> ClassifiedPhysicalPageRange {
        ClassifiedPhysicalPageRange(
            range: pageRange(base: base, pages: pages),
            classification: classification
        )
    }

    private static func pageRange(
        base: UInt64,
        pages: UInt64
    ) -> PhysicalPageRange {
        guard let range = PhysicalPageRange(
            baseAddress: base,
            pageCount: pages
        ) else {
            fatalError("invalid test page range")
        }
        return range
    }

    private static func expectAllocation(
        _ result: ClassifiedPageAllocationResult,
        _ message: StaticString
    ) -> ClassifiedPageAllocationToken {
        guard case let .allocated(token) = result else {
            fatalError("\(message): \(result)")
        }
        return token
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("\(message)")
        }
    }
}
