@main
struct RuntimeMemoryIntegrationTests {
    static func main() {
        testFirmwareMemorySanitizationAtEightGiBScale()
        testDeviceTreeMustFitInsideDeclaredRAM()
        testExplicitReservationsMustFitInsideDeclaredRAM()
        testEL0StackBackingIsScrubbedExactly()
        testEL0StackScrubRejectsMalformedPairsBeforeWriting()
        testFinalTablesUseBlocksAndExactPermissions()
        testDriverMappingsRequireReservedRAM()
        testFinalTableFailuresAreResettable()
        print("runtime memory integration host tests: 8 groups passed")
    }

    private static func testFirmwareMemorySanitizationAtEightGiBScale() {
        withRuntimeMemoryPlatform(
            deviceTreeMemoryLength: MemoryPageGeometry.pageSize
        ) { platform in
            let reservations = [
                PhysicalByteSpan(
                    baseAddress: 0x4008_0123,
                    length: 0x1f_f000
                )!,
                // Models a RAM-backed scanout retained by a boot driver.
                PhysicalByteSpan(
                    baseAddress: 0x5300_0123,
                    length: 0x2_000
                )!,
            ]
            var mapStorage = Array(
                repeating: PhysicalPageRange.empty,
                count: 16
            )
            var allocatorStorage = Array(
                repeating: PhysicalPageRange.empty,
                count: 32
            )
            reservations.withUnsafeBufferPointer { reserved in
                mapStorage.withUnsafeMutableBufferPointer { mapBuffer in
                    allocatorStorage.withUnsafeMutableBufferPointer {
                        allocatorBuffer in
                        var map = PhysicalMemoryMap(storage: mapBuffer)
                        var allocator = PhysicalPageAllocator(
                            storage: allocatorBuffer
                        )
                        let tablePool = PhysicalPageRange(
                            baseAddress: 0x5200_0000,
                            pageCount: 16
                        )!
                        let result = RuntimePhysicalMemoryBootstrap.initialize(
                            platform: platform,
                            layout: RuntimeMemoryBootstrapLayout(
                                explicitReservations: reserved,
                                translationTablePool: tablePool
                            ),
                            memoryMap: &map,
                            allocator: &allocator
                        )
                        guard case let .ready(summary) = result else {
                            fatalError("physical memory bootstrap failed")
                        }

                        let eightGiBPages: UInt64 = (8 * 1024 * 1024 * 1024)
                            / MemoryPageGeometry.pageSize
                        expect(summary.memoryTupleCount == 2, "memory tuple count")
                        expect(
                            summary.discoveredPageCount == eightGiBPages + 1,
                            "8 GiB discovery used per-page metadata"
                        )
                        expect(
                            summary.firmwareReservationCount == 1,
                            "firmware memreserve count"
                        )
                        expect(
                            summary.reservedMemoryTupleCount == 1,
                            "reserved-memory tuple count"
                        )
                        expect(
                            summary.explicitReservationCount == 2,
                            "explicit reservation count"
                        )
                        expect(map.count <= 8, "8 GiB map metadata exploded")
                        expect(
                            allocator.totalFreePageCount
                                == summary.usablePageCount,
                            "allocator/map accounting"
                        )
                        expect(
                            !mapContains(map, address: 0x4008_1000),
                            "kernel reservation remained free"
                        )
                        expect(
                            !mapContains(map, address: 0x5000_1000),
                            "/reserved-memory remained free"
                        )
                        expect(
                            !mapContains(map, address: 0x5100_1000),
                            "firmware memreserve remained free"
                        )
                        expect(
                            !mapContains(map, address: 0x5200_0000),
                            "translation-table pool remained free"
                        )
                        expect(
                            !mapContains(map, address: 0x5300_1000),
                            "driver-owned scanout remained allocatable"
                        )
                    }
                }
            }
        }
    }

    private static func testDeviceTreeMustFitInsideDeclaredRAM() {
        withRuntimeMemoryPlatform(
            deviceTreeMemoryLength: UInt64(runtimeMemoryDeviceTreeSize() - 1)
        ) { platform in
            let reservations: [PhysicalByteSpan] = []
            var mapStorage = Array(
                repeating: PhysicalPageRange.empty,
                count: 16
            )
            var allocatorStorage = Array(
                repeating: PhysicalPageRange.empty,
                count: 32
            )
            reservations.withUnsafeBufferPointer { reserved in
                mapStorage.withUnsafeMutableBufferPointer { mapBuffer in
                    allocatorStorage.withUnsafeMutableBufferPointer {
                        allocatorBuffer in
                        var map = PhysicalMemoryMap(storage: mapBuffer)
                        var allocator = PhysicalPageAllocator(
                            storage: allocatorBuffer
                        )
                        let tablePool = PhysicalPageRange(
                            baseAddress: 0x5200_0000,
                            pageCount: 16
                        )!
                        expect(
                            RuntimePhysicalMemoryBootstrap.initialize(
                                platform: platform,
                                layout: RuntimeMemoryBootstrapLayout(
                                    explicitReservations: reserved,
                                    translationTablePool: tablePool
                                ),
                                memoryMap: &map,
                                allocator: &allocator
                            ) == .failed(.deviceTreeOutsideRAM),
                            "partially out-of-RAM DTB was accepted"
                        )
                    }
                }
            }
        }
    }

    private static func testExplicitReservationsMustFitInsideDeclaredRAM() {
        withRuntimeMemoryPlatform(
            deviceTreeMemoryLength: MemoryPageGeometry.pageSize
        ) { platform in
            let reservations = [PhysicalByteSpan(
                baseAddress: 0x3_0000_0000,
                length: MemoryPageGeometry.pageSize
            )!]
            var mapStorage = Array(
                repeating: PhysicalPageRange.empty,
                count: 16
            )
            var allocatorStorage = Array(
                repeating: PhysicalPageRange.empty,
                count: 32
            )
            reservations.withUnsafeBufferPointer { reserved in
                mapStorage.withUnsafeMutableBufferPointer { mapBuffer in
                    allocatorStorage.withUnsafeMutableBufferPointer {
                        allocatorBuffer in
                        var map = PhysicalMemoryMap(storage: mapBuffer)
                        var allocator = PhysicalPageAllocator(
                            storage: allocatorBuffer
                        )
                        let tablePool = PhysicalPageRange(
                            baseAddress: 0x5200_0000,
                            pageCount: 16
                        )!
                        expect(
                            RuntimePhysicalMemoryBootstrap.initialize(
                                platform: platform,
                                layout: RuntimeMemoryBootstrapLayout(
                                    explicitReservations: reserved,
                                    translationTablePool: tablePool
                                ),
                                memoryMap: &map,
                                allocator: &allocator
                            ) == .failed(.explicitReservationOutsideRAM),
                            "out-of-RAM kernel reservation was accepted"
                        )
                    }
                }
            }
        }
    }

    private static func testEL0StackBackingIsScrubbedExactly() {
        let pageSize = Int(MemoryPageGeometry.pageSize)
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: pageSize * 6,
            alignment: pageSize
        )
        defer { allocation.deallocate() }
        fill(allocation, byteCount: pageSize * 6, with: 0xa5)

        let base = UInt64(UInt(bitPattern: allocation))
        let first = PhysicalByteSpan(
            baseAddress: base + UInt64(pageSize),
            length: UInt64(pageSize * 2)
        )!
        let second = PhysicalByteSpan(
            baseAddress: base + UInt64(pageSize * 3),
            length: UInt64(pageSize * 2)
        )!
        expect(
            EL0StackMemoryScrubber.scrub(first: first, second: second),
            "valid EL0 stack pair was rejected"
        )
        expect(
            bytes(in: allocation, offset: 0, count: pageSize)
                .allSatisfy { $0 == 0xa5 },
            "scrub wrote before the first stack"
        )
        expect(
            bytes(in: allocation, offset: pageSize, count: pageSize * 4)
                .allSatisfy { $0 == 0 },
            "EL0 stack backing retained stale bytes"
        )
        expect(
            bytes(
                in: allocation,
                offset: pageSize * 5,
                count: pageSize
            ).allSatisfy { $0 == 0xa5 },
            "scrub wrote after the second stack"
        )
    }

    private static func testEL0StackScrubRejectsMalformedPairsBeforeWriting() {
        let pageSize = Int(MemoryPageGeometry.pageSize)
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: pageSize * 4,
            alignment: pageSize
        )
        defer { allocation.deallocate() }
        let base = UInt64(UInt(bitPattern: allocation))
        let first = PhysicalByteSpan(
            baseAddress: base,
            length: UInt64(pageSize * 2)
        )!
        let overlappingSecond = PhysicalByteSpan(
            baseAddress: base + UInt64(pageSize),
            length: UInt64(pageSize * 2)
        )!
        let misalignedSecond = PhysicalByteSpan(
            baseAddress: base + UInt64(pageSize * 2 + 1),
            length: UInt64(pageSize)
        )!

        fill(allocation, byteCount: pageSize * 4, with: 0x5a)
        expect(
            !EL0StackMemoryScrubber.scrub(
                first: first,
                second: overlappingSecond
            ),
            "overlapping EL0 stack pair was accepted"
        )
        expect(
            bytes(in: allocation, offset: 0, count: pageSize * 4)
                .allSatisfy { $0 == 0x5a },
            "rejected overlapping pair was partially scrubbed"
        )

        expect(
            !EL0StackMemoryScrubber.scrub(
                first: first,
                second: misalignedSecond
            ),
            "misaligned EL0 stack pair was accepted"
        )
        expect(
            bytes(in: allocation, offset: 0, count: pageSize * 4)
                .allSatisfy { $0 == 0x5a },
            "rejected misaligned pair was partially scrubbed"
        )
    }

    private static func testFinalTablesUseBlocksAndExactPermissions() {
        var freeStorage = Array(
            repeating: PhysicalPageRange.empty,
            count: 4
        )
        freeStorage.withUnsafeMutableBufferPointer { freeBuffer in
            var freeMemory = PhysicalMemoryMap(storage: freeBuffer)
            expect(
                freeMemory.addDeviceTreeMemory(
                    baseAddress: 0x1_0000_0000,
                    length: 8 * 1024 * 1024 * 1024
                ),
                "8 GiB direct-map fixture"
            )

            let kernelText = FinalMappingRegion(
                virtualBaseAddress: 0x4008_0000,
                physicalBaseAddress: 0x4008_0000,
                pageCount: 2,
                role: .kernelText
            )!
            let userText = FinalMappingRegion(
                virtualBaseAddress: 0x0040_0000,
                physicalBaseAddress: 0x4010_0000,
                pageCount: 2,
                role: .userText
            )!
            let userReadOnlyData = FinalMappingRegion(
                virtualBaseAddress: 0x0060_0000,
                physicalBaseAddress: 0x4012_0000,
                pageCount: 1,
                role: .userReadOnlyData
            )!
            let kernelReadOnly = [
                FinalMappingRegion(
                    virtualBaseAddress: 0x400a_0000,
                    physicalBaseAddress: 0x400a_0000,
                    pageCount: 2,
                    role: .kernelReadOnlyData
                )!,
                // A separately retained DTB-like page.
                FinalMappingRegion(
                    virtualBaseAddress: 0x4100_0000,
                    physicalBaseAddress: 0x4100_0000,
                    pageCount: 1,
                    role: .kernelReadOnlyData
                )!,
            ]
            let kernelData = [
                FinalMappingRegion(
                    virtualBaseAddress: 0x400c_0000,
                    physicalBaseAddress: 0x400c_0000,
                    pageCount: 4,
                    role: .kernelData
                )!,
                FinalMappingRegion(
                    virtualBaseAddress: 0x4120_1000,
                    physicalBaseAddress: 0x4120_1000,
                    pageCount: 15,
                    role: .kernelData
                )!,
            ]
            let userStacks = [
                FinalMappingRegion(
                    virtualBaseAddress: 0x0080_1000,
                    physicalBaseAddress: 0x4020_0000,
                    pageCount: 4,
                    role: .userData
                )!,
                FinalMappingRegion(
                    virtualBaseAddress: 0x00a0_1000,
                    physicalBaseAddress: 0x4021_0000,
                    pageCount: 4,
                    role: .userData
                )!,
            ]
            let mmio = [
                FinalMappingRegion(
                    virtualBaseAddress: 0x0900_0000,
                    physicalBaseAddress: 0x0900_0000,
                    pageCount: 1,
                    role: .device
                )!,
                FinalMappingRegion(
                    virtualBaseAddress: 0x0800_0000,
                    physicalBaseAddress: 0x0800_0000,
                    pageCount: 16,
                    role: .device
                )!,
            ]
            let guards = [
                FinalGuardRegion(
                    virtualBaseAddress: 0x0080_0000,
                    pageCount: 1
                )!,
                FinalGuardRegion(
                    virtualBaseAddress: 0x0080_5000,
                    pageCount: 1
                )!,
                FinalGuardRegion(
                    virtualBaseAddress: 0x00a0_0000,
                    pageCount: 1
                )!,
                FinalGuardRegion(
                    virtualBaseAddress: 0x00a0_5000,
                    pageCount: 1
                )!,
                // Proves a caller can split privileged data around a guard.
                FinalGuardRegion(
                    virtualBaseAddress: 0x4120_0000,
                    pageCount: 1
                )!,
            ]

            withTableStorage(pageCount: 48) { entries in
                var pool = FinalTranslationTablePagePool(
                    physicalBaseAddress: 0x4200_0000,
                    pageCount: 48,
                    mappedEntries: entries
                )!
                kernelReadOnly.withUnsafeBufferPointer { kernelROBuffer in
                    kernelData.withUnsafeBufferPointer { kernelDataBuffer in
                        userStacks.withUnsafeBufferPointer { stackBuffer in
                            mmio.withUnsafeBufferPointer { mmioBuffer in
                                guards.withUnsafeBufferPointer { guardBuffer in
                                    let layout = FinalAddressSpaceLayout(
                                        kind: .user,
                                        identifier: AddressSpaceIdentifier(
                                            value: 7,
                                            generation: 2
                                        ),
                                        kernelText: kernelText,
                                        kernelReadOnlyDataRegions: kernelROBuffer,
                                        kernelDataRegions: kernelDataBuffer,
                                        userText: userText,
                                        userReadOnlyData: userReadOnlyData,
                                        userStacks: stackBuffer,
                                        mmioRegions: mmioBuffer,
                                        guardRegions: guardBuffer
                                    )
                                    let result = FinalTranslationTableBuilder
                                        .build(
                                            availablePhysicalMemory: freeMemory,
                                            layout: layout,
                                            pool: &pool
                                        )
                                    guard case let .built(tables) = result else {
                                        fatalError("final table build failed")
                                    }
                                    expect(tables.t0sz == 25, "T0SZ metadata")
                                    expect(
                                        tables.startLevel == .level1,
                                        "39-bit walk did not start at L1"
                                    )
                                    expect(
                                        tables.addressSpace
                                            .translationTableBaseRegisterValue
                                            == tables.addressSpace
                                                .rootTablePhysicalAddress
                                                | UInt64(7) << 56,
                                        "TTBR ASID encoding"
                                    )
                                    expect(
                                        tables.summary.level2BlockCount == 4096,
                                        "8 GiB did not use 2 MiB blocks"
                                    )
                                    expect(
                                        tables.summary.deviceMappedPageCount == 17,
                                        "MMIO was not exact-page mapped"
                                    )
                                    expect(
                                        tables.summary.userMappedPageCount == 11,
                                        "EL0 mapped page count"
                                    )
                                    expect(
                                        tables.summary.guardPageCount == 5,
                                        "guard page count"
                                    )

                                    assertKernelText(
                                        pool.lookup(
                                            rootTablePhysicalAddress: tables
                                                .addressSpace
                                                .rootTablePhysicalAddress,
                                            virtualAddress: 0x4008_0123
                                        )
                                    )
                                    assertUserText(
                                        pool.lookup(
                                            rootTablePhysicalAddress: tables
                                                .addressSpace
                                                .rootTablePhysicalAddress,
                                            virtualAddress: 0x0040_0123
                                        )
                                    )
                                    assertDevice(
                                        pool.lookup(
                                            rootTablePhysicalAddress: tables
                                                .addressSpace
                                                .rootTablePhysicalAddress,
                                            virtualAddress: 0x0900_0000
                                        )
                                    )
                                    expect(
                                        pool.lookup(
                                            rootTablePhysicalAddress: tables
                                                .addressSpace
                                                .rootTablePhysicalAddress,
                                            virtualAddress: 0x0080_0000
                                        ) == .guardPage,
                                        "user stack guard became mapped"
                                    )
                                    expect(
                                        pool.lookup(
                                            rootTablePhysicalAddress: tables
                                                .addressSpace
                                                .rootTablePhysicalAddress,
                                            virtualAddress: 0x4120_0000
                                        ) == .guardPage,
                                        "kernel guard became mapped"
                                    )
                                    guard case let .mapped(
                                        directPhysical,
                                        directLevel,
                                        _
                                    ) = pool.lookup(
                                        rootTablePhysicalAddress: tables
                                            .addressSpace
                                            .rootTablePhysicalAddress,
                                        virtualAddress: 0x1_0000_1234
                                    ) else {
                                        fatalError("direct-map lookup failed")
                                    }
                                    expect(
                                        directPhysical == 0x1_0000_1234,
                                        "direct-map physical address"
                                    )
                                    expect(
                                        directLevel == .level2,
                                        "aligned RAM did not use L2 block"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func testFinalTableFailuresAreResettable() {
        var freeStorage = Array(
            repeating: PhysicalPageRange.empty,
            count: 2
        )
        freeStorage.withUnsafeMutableBufferPointer { freeBuffer in
            var freeMemory = PhysicalMemoryMap(storage: freeBuffer)
            expect(
                freeMemory.addDeviceTreeMemory(
                    baseAddress: 0x4000_0000,
                    length: 0x20_0000
                ),
                "pool exhaustion fixture"
            )
            let emptyMappings: [FinalMappingRegion] = []
            let emptyGuards: [FinalGuardRegion] = []
            emptyMappings.withUnsafeBufferPointer { mappings in
                emptyGuards.withUnsafeBufferPointer { guards in
                    let layout = FinalAddressSpaceLayout(
                        kind: .kernel,
                        identifier: .kernel,
                        kernelText: nil,
                        kernelReadOnlyDataRegions: mappings,
                        kernelDataRegions: mappings,
                        userText: nil,
                        userReadOnlyData: nil,
                        userStacks: mappings,
                        mmioRegions: mappings,
                        guardRegions: guards
                    )
                    withTableStorage(pageCount: 1) { entries in
                        var pool = FinalTranslationTablePagePool(
                            physicalBaseAddress: 0x4300_0000,
                            pageCount: 1,
                            mappedEntries: entries
                        )!
                        expect(
                            FinalTranslationTableBuilder.build(
                                availablePhysicalMemory: freeMemory,
                                layout: layout,
                                pool: &pool
                            ) == .failed(.tablePoolExhausted),
                            "table pool exhaustion result"
                        )
                        expect(pool.usedPageCount == 0, "failed build not reset")
                        expect(entries.allSatisfy { $0 == 0 }, "failed tables not cleared")
                    }
                }
            }
        }
    }

    private static func testDriverMappingsRequireReservedRAM() {
        withRuntimeMemoryPlatform(
            deviceTreeMemoryLength: MemoryPageGeometry.pageSize
        ) { platform in
            let kernelImage = DeviceResource(
                baseAddress: 0x4008_0000,
                length: 0x20_0000
            )
            var resources = BootDriverResourceSet()
            expect(
                resources.append(
                    memory: DriverMemoryResource(
                        baseAddress: 0x5300_0123,
                        length: 0x2_000,
                        role: .kernelData,
                        reservesSystemMemory: true
                    )!
                ),
                "framebuffer resource append"
            )
            // Address observed in the Raspberry Pi 5 DT probe. Planning rounds
            // the register window to the exact page mapped as Device memory.
            expect(
                resources.append(
                    mmio: DeviceResource(
                        baseAddress: 0x10_7c01_3880,
                        length: 0x40
                    )
                ),
                "Pi mailbox resource append"
            )
            guard let plan = BootDriverResourcePlan(
                resources: resources,
                platform: platform,
                kernelImage: kernelImage
            ) else {
                fatalError("valid driver resource plan rejected")
            }
            expect(plan.memoryResourceCount == 1, "planned memory count")
            expect(plan.mmioResourceCount == 1, "planned MMIO count")

            guard let framebufferReservation = plan.systemMemoryReservation(
                      at: 0
                  ),
                  let framebufferMapping = plan.memoryMapping(at: 0),
                  let mailboxMapping = plan.mmioMapping(at: 0)
            else {
                fatalError("driver plan omitted a resource")
            }
            expect(
                framebufferReservation == PhysicalByteSpan(
                    baseAddress: 0x5300_0000,
                    length: 0x3_000
                ),
                "framebuffer reservation was not page-normalized"
            )
            expect(
                framebufferMapping == FinalMappingRegion(
                    virtualBaseAddress: 0x5300_0000,
                    physicalBaseAddress: 0x5300_0000,
                    pageCount: 3,
                    role: .kernelData
                ),
                "framebuffer mapping plan"
            )
            expect(
                mailboxMapping == FinalMappingRegion(
                    virtualBaseAddress: 0x10_7c01_3000,
                    physicalBaseAddress: 0x10_7c01_3000,
                    pageCount: 1,
                    role: .device
                ),
                "Pi mailbox mapping plan"
            )

            verifyPlannedDriverMappings(
                framebufferReservation: framebufferReservation,
                framebufferMapping: framebufferMapping,
                mailboxMapping: mailboxMapping
            )
            verifyDriverPlanRejections(
                platform: platform,
                kernelImage: kernelImage
            )
        }
    }
}

private func verifyPlannedDriverMappings(
    framebufferReservation: PhysicalByteSpan,
    framebufferMapping: FinalMappingRegion,
    mailboxMapping: FinalMappingRegion
) {
    var freeStorage = Array(
        repeating: PhysicalPageRange.empty,
        count: 8
    )
    freeStorage.withUnsafeMutableBufferPointer { freeBuffer in
        var freeMemory = PhysicalMemoryMap(storage: freeBuffer)
        expect(
            freeMemory.addDeviceTreeMemory(
                baseAddress: 0x5300_0000,
                length: 0x20_0000
            ),
            "driver RAM fixture"
        )

        let driverMemory = [framebufferMapping]
        let driverMMIO = [mailboxMapping]
        let emptyMappings: [FinalMappingRegion] = []
        let emptyGuards: [FinalGuardRegion] = []
        driverMemory.withUnsafeBufferPointer { memoryBuffer in
            driverMMIO.withUnsafeBufferPointer { mmioBuffer in
                emptyMappings.withUnsafeBufferPointer { emptyBuffer in
                    emptyGuards.withUnsafeBufferPointer { guardBuffer in
                        let layout = FinalAddressSpaceLayout(
                            kind: .kernel,
                            identifier: .kernel,
                            kernelText: nil,
                            kernelReadOnlyDataRegions: emptyBuffer,
                            kernelDataRegions: memoryBuffer,
                            userText: nil,
                            userReadOnlyData: nil,
                            userStacks: emptyBuffer,
                            mmioRegions: mmioBuffer,
                            guardRegions: guardBuffer
                        )

                        withTableStorage(pageCount: 16) { entries in
                            var pool = FinalTranslationTablePagePool(
                                physicalBaseAddress: 0x7200_0000,
                                pageCount: 16,
                                mappedEntries: entries
                            )!
                            expect(
                                FinalTranslationTableBuilder.build(
                                    availablePhysicalMemory: freeMemory,
                                    layout: layout,
                                    pool: &pool
                                ) == .failed(.mappingConflict),
                                "unreserved framebuffer mapped twice"
                            )
                        }

                        expect(
                            freeMemory.reserve(
                                baseAddress: framebufferReservation.baseAddress,
                                length: framebufferReservation.length
                            ),
                            "planned framebuffer reservation failed"
                        )
                        expect(
                            !mapContains(freeMemory, address: 0x5300_1000),
                            "planned framebuffer remained allocatable"
                        )
                        withTableStorage(pageCount: 16) { entries in
                            var pool = FinalTranslationTablePagePool(
                                physicalBaseAddress: 0x7200_0000,
                                pageCount: 16,
                                mappedEntries: entries
                            )!
                            let result = FinalTranslationTableBuilder.build(
                                availablePhysicalMemory: freeMemory,
                                layout: layout,
                                pool: &pool
                            )
                            guard case let .built(tables) = result else {
                                fatalError("planned driver mappings failed")
                            }
                            let root = tables.addressSpace
                                .rootTablePhysicalAddress
                            assertKernelData(
                                pool.lookup(
                                    rootTablePhysicalAddress: root,
                                    virtualAddress: 0x5300_1123
                                ),
                                expectedPhysicalAddress: 0x5300_1123
                            )
                            assertDevice(
                                pool.lookup(
                                    rootTablePhysicalAddress: root,
                                    virtualAddress: 0x10_7c01_3880
                                ),
                                expectedPhysicalAddress: 0x10_7c01_3880
                            )
                        }
                    }
                }
            }
        }
    }
}

private func verifyDriverPlanRejections(
    platform: Platform,
    kernelImage: DeviceResource
) {
    var unreservedRAM = BootDriverResourceSet()
    expect(
        unreservedRAM.append(
            memory: DriverMemoryResource(
                baseAddress: 0x5300_0000,
                length: 0x1000,
                role: .kernelData,
                reservesSystemMemory: false
            )!
        ),
        "unreserved RAM rejection fixture"
    )
    expect(
        BootDriverResourcePlan(
            resources: unreservedRAM,
            platform: platform,
            kernelImage: kernelImage
        ) == nil,
        "unreserved framebuffer RAM was accepted"
    )

    var partialRAM = BootDriverResourceSet()
    expect(
        partialRAM.append(
            memory: DriverMemoryResource(
                baseAddress: 0x2_3fff_f000,
                length: 0x2_000,
                role: .kernelData,
                reservesSystemMemory: true
            )!
        ),
        "partial RAM rejection fixture"
    )
    expect(
        BootDriverResourcePlan(
            resources: partialRAM,
            platform: platform,
            kernelImage: kernelImage
        ) == nil,
        "partially RAM-backed framebuffer was accepted"
    )

    var baseDeviceCollision = BootDriverResourceSet()
    expect(
        baseDeviceCollision.append(
            mmio: DeviceResource(
                baseAddress: platform.serial.baseAddress + 0x20,
                length: 0x40
            )
        ),
        "base MMIO rejection fixture"
    )
    expect(
        BootDriverResourcePlan(
            resources: baseDeviceCollision,
            platform: platform,
            kernelImage: kernelImage
        ) == nil,
        "driver MMIO overlapping the serial page was accepted"
    )

    var kernelCollision = BootDriverResourceSet()
    expect(
        kernelCollision.append(
            memory: DriverMemoryResource(
                baseAddress: kernelImage.baseAddress + 0x1000,
                length: 0x1000,
                role: .kernelData,
                reservesSystemMemory: true
            )!
        ),
        "kernel collision rejection fixture"
    )
    expect(
        BootDriverResourcePlan(
            resources: kernelCollision,
            platform: platform,
            kernelImage: kernelImage
        ) == nil,
        "framebuffer overlapping the kernel image was accepted"
    )
}

private func mapContains(
    _ map: PhysicalMemoryMap,
    address: UInt64
) -> Bool {
    var index = 0
    while index < map.count {
        if map.range(at: index)?.contains(address: address) == true {
            return true
        }
        index += 1
    }
    return false
}

private func assertKernelText(_ lookup: FinalTranslationLookup) {
    guard case let .mapped(physicalAddress, level, descriptor) = lookup else {
        fatalError("kernel text lookup failed")
    }
    expect(physicalAddress == 0x4008_0123, "kernel text physical mapping")
    expect(level == .level3, "kernel text was not exact-page mapped")
    expect((descriptor >> 6) & 0b11 == 0b10, "kernel text AP")
    expect(descriptor & (1 << 53) == 0, "kernel text PXN")
    expect(descriptor & (1 << 54) != 0, "kernel text UXN")
}

private func assertUserText(_ lookup: FinalTranslationLookup) {
    guard case let .mapped(physicalAddress, level, descriptor) = lookup else {
        fatalError("user text lookup failed")
    }
    expect(physicalAddress == 0x4010_0123, "user text physical mapping")
    expect(level == .level3, "user text was not exact-page mapped")
    expect((descriptor >> 6) & 0b11 == 0b11, "user text AP")
    expect(descriptor & (1 << 11) != 0, "user text global")
    expect(descriptor & (1 << 53) != 0, "user text PXN")
    expect(descriptor & (1 << 54) == 0, "user text UXN")
}

private func assertDevice(
    _ lookup: FinalTranslationLookup,
    expectedPhysicalAddress: UInt64? = nil
) {
    guard case let .mapped(physicalAddress, level, descriptor) = lookup else {
        fatalError("device lookup failed")
    }
    if let expectedPhysicalAddress {
        expect(
            physicalAddress == expectedPhysicalAddress,
            "device physical mapping"
        )
    }
    expect(level == .level3, "MMIO was not exact-page mapped")
    expect((descriptor >> 2) & 0b111 == 0, "MMIO AttrIndx")
    expect(descriptor & (1 << 53) != 0, "MMIO PXN")
    expect(descriptor & (1 << 54) != 0, "MMIO UXN")
}

private func assertKernelData(
    _ lookup: FinalTranslationLookup,
    expectedPhysicalAddress: UInt64 = 0x6000_1123
) {
    guard case let .mapped(physicalAddress, level, descriptor) = lookup else {
        fatalError("kernel data lookup failed")
    }
    expect(
        physicalAddress == expectedPhysicalAddress,
        "kernel data physical mapping"
    )
    expect(level == .level3, "driver RAM was not exact-page mapped")
    expect((descriptor >> 2) & 0b111 == 1, "driver RAM AttrIndx")
    expect((descriptor >> 6) & 0b11 == 0, "driver RAM AP")
    expect(descriptor & (1 << 53) != 0, "driver RAM PXN")
    expect(descriptor & (1 << 54) != 0, "driver RAM UXN")
}

private func withTableStorage(
    pageCount: Int,
    _ body: (UnsafeMutableBufferPointer<UInt64>) -> Void
) {
    let byteCount = pageCount * Int(MemoryPageGeometry.pageSize)
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: Int(MemoryPageGeometry.pageSize)
    )
    defer { raw.deallocate() }
    let entries = UnsafeMutableBufferPointer(
        start: raw.assumingMemoryBound(to: UInt64.self),
        count: byteCount / MemoryLayout<UInt64>.stride
    )
    body(entries)
}

private func fill(
    _ destination: UnsafeMutableRawPointer,
    byteCount: Int,
    with byte: UInt8
) {
    var offset = 0
    while offset < byteCount {
        destination.storeBytes(
            of: byte,
            toByteOffset: offset,
            as: UInt8.self
        )
        offset += 1
    }
}

private func bytes(
    in source: UnsafeRawPointer,
    offset: Int,
    count: Int
) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(count)
    var index = 0
    while index < count {
        result.append(
            source.load(fromByteOffset: offset + index, as: UInt8.self)
        )
        index += 1
    }
    return result
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() { fatalError(message) }
}

private func runtimeMemoryDeviceTreeSize() -> Int {
    makeRuntimeMemoryDeviceTree(
        deviceTreeMemory: DeviceResource(baseAddress: 0x1000, length: 0x1000)
    ).count
}

private func withRuntimeMemoryPlatform(
    deviceTreeMemoryLength: UInt64,
    _ body: (Platform) -> Void
) {
    let pageSize = Int(MemoryPageGeometry.pageSize)
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: pageSize,
        alignment: pageSize
    )
    defer { storage.deallocate() }

    let bytes = makeRuntimeMemoryDeviceTree(
        deviceTreeMemory: DeviceResource(
            baseAddress: UInt64(UInt(bitPattern: storage)),
            length: deviceTreeMemoryLength
        )
    )
    expect(bytes.count <= pageSize, "runtime-memory FDT exceeds fixture page")
    bytes.withUnsafeBytes { source in
        storage.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
    }
    guard let platform = Platform.discover(
        deviceTreeAddress: UInt64(UInt(bitPattern: storage))
    ) else {
        fatalError("runtime-memory FDT rejected")
    }
    body(platform)
}

// A purpose-built DT fixture: one 8 GiB bank, a host-backed DTB bank, one
// memreserve tuple, one /reserved-memory tuple, and the minimum QEMU devices.
private func makeRuntimeMemoryDeviceTree(
    deviceTreeMemory: DeviceResource
) -> [UInt8] {
    let propertyNames = [
        "#address-cells", "#size-cells", "compatible", "device_type",
        "ranges", "reg",
    ]
    var strings: [UInt8] = []
    var offsets: [String: UInt32] = [:]
    for name in propertyNames {
        offsets[name] = UInt32(strings.count)
        strings += name.utf8
        strings.append(0)
    }

    var structure: [UInt8] = []
    fdtNode("", to: &structure)
    fdtProperty(offsets["#address-cells"]!, fdtBE32(2), to: &structure)
    fdtProperty(offsets["#size-cells"]!, fdtBE32(2), to: &structure)
    fdtProperty(
        offsets["compatible"]!,
        Array("qemu,virt".utf8) + [0],
        to: &structure
    )

    fdtNode("memory@40000000", to: &structure)
    fdtProperty(
        offsets["device_type"]!,
        Array("memory".utf8) + [0],
        to: &structure
    )
    fdtProperty(
        offsets["reg"]!,
        fdtBE64(0x4000_0000) + fdtBE64(8 * 1024 * 1024 * 1024),
        to: &structure
    )
    fdtWord(2, to: &structure)

    fdtNode("memory@dtb", to: &structure)
    fdtProperty(
        offsets["device_type"]!,
        Array("memory".utf8) + [0],
        to: &structure
    )
    fdtProperty(
        offsets["reg"]!,
        fdtBE64(deviceTreeMemory.baseAddress)
            + fdtBE64(deviceTreeMemory.length),
        to: &structure
    )
    fdtWord(2, to: &structure)

    fdtNode("reserved-memory", to: &structure)
    fdtProperty(offsets["#address-cells"]!, fdtBE32(2), to: &structure)
    fdtProperty(offsets["#size-cells"]!, fdtBE32(2), to: &structure)
    fdtProperty(offsets["ranges"]!, [], to: &structure)
    fdtNode("firmware@50000000", to: &structure)
    fdtProperty(
        offsets["reg"]!,
        fdtBE64(0x5000_0000) + fdtBE64(0x20_0000),
        to: &structure
    )
    fdtWord(2, to: &structure)
    fdtWord(2, to: &structure)

    fdtNode("uart@9000000", to: &structure)
    fdtProperty(
        offsets["compatible"]!,
        Array("arm,pl011".utf8) + [0],
        to: &structure
    )
    fdtProperty(
        offsets["reg"]!,
        fdtBE64(0x0900_0000) + fdtBE64(0x1000),
        to: &structure
    )
    fdtWord(2, to: &structure)

    fdtNode("fw-cfg@9020000", to: &structure)
    fdtProperty(
        offsets["compatible"]!,
        Array("qemu,fw-cfg-mmio".utf8) + [0],
        to: &structure
    )
    fdtProperty(
        offsets["reg"]!,
        fdtBE64(0x0902_0000) + fdtBE64(0x18),
        to: &structure
    )
    fdtWord(2, to: &structure)

    fdtNode("interrupt-controller@8000000", to: &structure)
    fdtProperty(
        offsets["compatible"]!,
        Array("arm,gic-v3".utf8) + [0],
        to: &structure
    )
    fdtProperty(
        offsets["reg"]!,
        fdtBE64(0x0800_0000) + fdtBE64(0x1_0000)
            + fdtBE64(0x080a_0000) + fdtBE64(0x20_0000),
        to: &structure
    )
    fdtWord(2, to: &structure)
    fdtWord(2, to: &structure)
    fdtWord(9, to: &structure)

    let headerSize = 40
    let reservations = fdtBE64(0x5100_0000) + fdtBE64(0x10_0000)
        + Array(repeating: UInt8(0), count: 16)
    let structureOffset = headerSize + reservations.count
    let stringsOffset = structureOffset + structure.count
    let totalSize = stringsOffset + strings.count
    var header: [UInt8] = []
    fdtWord(0xd00d_feed, to: &header)
    fdtWord(UInt32(totalSize), to: &header)
    fdtWord(UInt32(structureOffset), to: &header)
    fdtWord(UInt32(stringsOffset), to: &header)
    fdtWord(UInt32(headerSize), to: &header)
    fdtWord(17, to: &header)
    fdtWord(16, to: &header)
    fdtWord(0, to: &header)
    fdtWord(UInt32(strings.count), to: &header)
    fdtWord(UInt32(structure.count), to: &header)
    return header + reservations + structure + strings
}

private func fdtNode(_ name: String, to bytes: inout [UInt8]) {
    fdtWord(1, to: &bytes)
    bytes += name.utf8
    bytes.append(0)
    fdtPad(&bytes)
}

private func fdtProperty(
    _ nameOffset: UInt32,
    _ value: [UInt8],
    to bytes: inout [UInt8]
) {
    fdtWord(3, to: &bytes)
    fdtWord(UInt32(value.count), to: &bytes)
    fdtWord(nameOffset, to: &bytes)
    bytes += value
    fdtPad(&bytes)
}

private func fdtPad(_ bytes: inout [UInt8]) {
    while bytes.count & 3 != 0 { bytes.append(0) }
}

private func fdtBE32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
    ]
}

private func fdtBE64(_ value: UInt64) -> [UInt8] {
    fdtBE32(UInt32(truncatingIfNeeded: value >> 32))
        + fdtBE32(UInt32(truncatingIfNeeded: value))
}

private func fdtWord(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes += fdtBE32(value)
}
