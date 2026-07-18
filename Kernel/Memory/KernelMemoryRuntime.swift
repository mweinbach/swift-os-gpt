struct KernelMemoryActivation {
    let userMappings: KernelEL0AddressSpaceMappings
    let usablePageCount: UInt64
    let translationTablePageCount: Int
}

/// Converts firmware discovery into owned RAM and replaces the permissive
/// bootstrap map with exact kernel/user/device mappings. Every metadata buffer
/// is linker-owned, so this path has no dependency on a heap allocator.
enum KernelMemoryRuntime {
    static let memoryReadyMarker: StaticString = "SWIFTOS:MEMORY_READY\n"
    static let pagingReadyMarker: StaticString = "SWIFTOS:PAGING_READY\n"
    static let defaultSystemMemoryDomain = PhysicalMemoryAllocationDomain(1)
    /// Boot-discovered system DRAM is CPU/device accessible and coherent as an
    /// allocation class. Per-device DMA addressability and coherency remain
    /// separate contracts supplied by device discovery and `DMAMapping`.
    static let defaultSystemMemoryClassification =
        PhysicalMemoryClassification(
            allocationDomain: defaultSystemMemoryDomain,
            capabilities: PhysicalMemoryCapabilities.cpuAccessible
                .union(.deviceAccessible)
                .union(.cacheCoherent),
            proximityDomain: PhysicalMemoryProximityDomain(0)
        )

    private static let memoryMapCapacity = 256
    private static let bootstrapAllocatorCapacity = 512
    private static let classifiedFreeRunCapacity = 512
    private static let classifiedActiveAllocationCapacity = 512
    private static let kernelReadOnlyCapacity = 2
    private static let kernelDataCapacity = 6
        + BootDriverResourceSet.maximumMemoryResourceCount
    private static let userStackCapacity = 2
    private static let mmioCapacity = 5
        + BootDriverResourceSet.maximumMMIOResourceCount
    private static let guardCapacity = 6
    private static let explicitReservationCapacity = 1
        + BootDriverResourceSet.maximumMemoryResourceCount

    private enum LayoutOffset {
        static let kernelReadOnly = 0
        static let kernelData = 128
        static let userStacks = 640
        static let mmio = 768
        static let guards = 1280
        static let explicitReservations = 1536
    }

    private nonisolated(unsafe) static var ownedMemoryMap:
        PhysicalMemoryMap?
    private nonisolated(unsafe) static var ownedClassifiedPageAllocator:
        ClassifiedPhysicalMemoryAllocator?
    private nonisolated(unsafe) static var activeTables:
        FinalTranslationTables?
    private nonisolated(unsafe) static var allocatorLockWord: UInt32 = 0

    static var isReady: Bool {
        ownedMemoryMap != nil && ownedClassifiedPageAllocator != nil
            && activeTables != nil
    }

    static func activate(
        platform: Platform,
        console: EarlyConsole,
        driverResources: BootDriverResourceSet = BootDriverResourceSet()
    ) -> KernelMemoryActivation? {
        guard !isReady,
              storageBoundsAreValid(),
              let driverPlan = BootDriverResourcePlan(
                  resources: driverResources,
                  platform: platform,
                  kernelImage: DeviceResource(
                      baseAddress: KernelLinkerLayout.kernelImage.start,
                      length: KernelLinkerLayout.kernelImage.length
                  )
              ),
              let mapStorage: UnsafeMutableBufferPointer<PhysicalPageRange>
                = fixedBuffer(
                    at: KernelLinkerLayout.memoryMapStorage,
                    count: memoryMapCapacity
                ),
              let allocatorStorage:
                UnsafeMutableBufferPointer<PhysicalPageRange> = fixedBuffer(
                    at: KernelLinkerLayout.pageAllocatorStorage,
                    count: bootstrapAllocatorCapacity
                ),
              let classifiedFreeStorage:
                UnsafeMutableBufferPointer<ClassifiedPhysicalPageRange>
                = fixedBuffer(
                    at: KernelLinkerLayout.classifiedFreeRunStorage.start,
                    count: classifiedFreeRunCapacity
                ),
              let classifiedAllocationStorage:
                UnsafeMutableBufferPointer<ClassifiedPageAllocationToken>
                = fixedBuffer(
                    at: KernelLinkerLayout
                        .classifiedAllocationLedgerStorage.start,
                    count: classifiedActiveAllocationCapacity
                ),
              let tablePoolRange = translationTablePoolRange(),
              let explicitReservations = explicitReservationStorage(),
              let kernelReservation = PhysicalByteSpan(
                  startAddress: KernelLinkerLayout.kernelImage.start,
                  endAddress: KernelLinkerLayout.kernelImage.end
              )
        else {
            return nil
        }

        explicitReservations[0] = kernelReservation
        var explicitReservationCount = 1
        var driverMemoryIndex = 0
        while driverMemoryIndex < driverPlan.memoryResourceCount {
            if let span = driverPlan.systemMemoryReservation(
                at: driverMemoryIndex
            ) {
                guard explicitReservationCount
                        < explicitReservations.count
                else {
                    return nil
                }
                explicitReservations[explicitReservationCount] = span
                explicitReservationCount += 1
            }
            driverMemoryIndex += 1
        }
        let immutableReservations = UnsafeBufferPointer(
            start: explicitReservations.baseAddress,
            count: explicitReservationCount
        )
        var memoryMap = PhysicalMemoryMap(storage: mapStorage)
        var bootstrapAllocator = PhysicalPageAllocator(
            storage: allocatorStorage
        )
        var classifiedAllocator = ClassifiedPhysicalMemoryAllocator(
            freeStorage: classifiedFreeStorage,
            allocationStorage: classifiedAllocationStorage
        )
        let bootstrap = RuntimePhysicalMemoryBootstrap.initialize(
            platform: platform,
            layout: RuntimeMemoryBootstrapLayout(
                explicitReservations: immutableReservations,
                translationTablePool: tablePoolRange
            ),
            memoryMap: &memoryMap,
            allocator: &bootstrapAllocator
        )
        guard case let .ready(memorySummary) = bootstrap,
              classifiedAllocator.load(
                  from: memoryMap,
                  classification: defaultSystemMemoryClassification
              ),
              classifiedAllocator.totalFreePageCount
                == memorySummary.usablePageCount,
              let userMappings = KernelEL0Runtime.addressSpaceMappings(),
              driverVirtualAddressesAreValid(
                  driverPlan,
                  userMappings: userMappings
              ),
              scrubUserStackBacking(),
              let layout = finalLayout(
                  platform: platform,
                  userMappings: userMappings,
                  driverPlan: driverPlan
              ),
              let tableStorage: UnsafeMutableBufferPointer<UInt64>
                = fixedBuffer(
                    at: tablePoolRange.baseAddress,
                    count: Int(tablePoolRange.pageCount)
                        * TranslationTableGeometry.entriesPerTable
                ),
              var tablePool = FinalTranslationTablePagePool(
                  physicalBaseAddress: tablePoolRange.baseAddress,
                  pageCount: Int(tablePoolRange.pageCount),
                  mappedEntries: tableStorage
              )
        else {
            return nil
        }

        let build = FinalTranslationTableBuilder.build(
            availablePhysicalMemory: memoryMap,
            layout: layout,
            pool: &tablePool
        )
        guard case let .built(tables) = build else {
            return nil
        }

        // Publish allocator ownership before changing tables. The metadata and
        // every page it describes are retained by the final identity map.
        ownedMemoryMap = memoryMap
        ownedClassifiedPageAllocator = classifiedAllocator
        activeTables = tables
        console.write(memoryReadyMarker)
        console.write("SWIFTOS:USABLE_PAGES=")
        console.writeHex(memorySummary.usablePageCount)
        console.write("\n")

        AArch64.installTranslationTable(
            rootPhysicalAddress: tables.addressSpace.rootTablePhysicalAddress,
            addressSpaceIdentifier: tables.addressSpace.identifier.value
        )
        guard AArch64.translationTableBase
                == tables.addressSpace.translationTableBaseRegisterValue
        else {
            return nil
        }
        console.write(pagingReadyMarker)
        console.write("SWIFTOS:TABLE_PAGES=")
        console.writeHex(UInt64(tables.summary.tablePageCount))
        console.write("\n")

        return KernelMemoryActivation(
            userMappings: userMappings,
            usablePageCount: memorySummary.usablePageCount,
            translationTablePageCount: tables.summary.tablePageCount
        )
    }

    static func allocatePages(
        pageCount: UInt64,
        alignmentInPages: UInt64 = 1
    ) -> PageAllocationResult {
        let result = allocateClassifiedPages(
            ClassifiedPageAllocationConstraints(
                pageCount: pageCount,
                alignmentInPages: alignmentInPages,
                requiredCapabilities: .cpuAccessible,
                domainSelection: .preferred(
                    defaultSystemMemoryDomain,
                    fallback: .disallowed
                )
            )
        )
        switch result {
        case let .allocated(token):
            // The classified allocator retains the token in its ownership
            // ledger. `releasePages` resolves that token from this range.
            return .allocated(token.range)
        case .invalidRequest:
            return .invalidRequest
        case .outOfMemory:
            return .outOfMemory
        case .metadataExhausted:
            return .metadataExhausted
        }
    }

    static func allocateClassifiedPages(
        _ constraints: ClassifiedPageAllocationConstraints
    ) -> ClassifiedPageAllocationResult {
        let interruptState = lockAllocator()
        guard var allocator = ownedClassifiedPageAllocator else {
            unlockAllocator(restoring: interruptState)
            return .outOfMemory
        }
        let result = allocator.allocate(constraints)
        ownedClassifiedPageAllocator = allocator
        unlockAllocator(restoring: interruptState)
        return result
    }

    static func releaseClassifiedPages(
        _ token: ClassifiedPageAllocationToken
    ) -> ClassifiedPageReleaseResult {
        let interruptState = lockAllocator()
        guard var allocator = ownedClassifiedPageAllocator else {
            unlockAllocator(restoring: interruptState)
            return .unknownAllocation
        }
        let result = allocator.release(token)
        ownedClassifiedPageAllocator = allocator
        unlockAllocator(restoring: interruptState)
        return result
    }

    /// Compatibility release for ranges returned by `allocatePages`. Token
    /// lookup and release occur under the same lock, so another CPU cannot
    /// change ownership between those operations.
    @discardableResult
    static func releasePages(_ range: PhysicalPageRange) -> Bool {
        let interruptState = lockAllocator()
        guard var allocator = ownedClassifiedPageAllocator,
              let token = allocator.activeAllocation(
                  matching: range,
                  classification: defaultSystemMemoryClassification
              )
        else {
            unlockAllocator(restoring: interruptState)
            return false
        }
        let result = allocator.release(token)
        ownedClassifiedPageAllocator = allocator
        unlockAllocator(restoring: interruptState)
        return result == .released
    }

    private static func lockAllocator() -> UInt64 {
        withUnsafeMutablePointer(to: &allocatorLockWord) { lockWord in
            archMemoryAllocatorLock(lockWord)
        }
    }

    private static func unlockAllocator(restoring interruptState: UInt64) {
        withUnsafeMutablePointer(to: &allocatorLockWord) { lockWord in
            archMemoryAllocatorUnlock(lockWord, interruptState)
        }
    }

    /// Runs while the bootstrap identity map still exposes the physical
    /// NOLOAD spans and before the final EL0 aliases are constructed.
    private static func scrubUserStackBacking() -> Bool {
        let first = KernelLinkerLayout.userStack0
        let second = KernelLinkerLayout.userStack1
        guard let firstSpan = PhysicalByteSpan(
                  startAddress: first.start,
                  endAddress: first.end
              ),
              let secondSpan = PhysicalByteSpan(
                  startAddress: second.start,
                  endAddress: second.end
              )
        else {
            return false
        }
        return EL0StackMemoryScrubber.scrub(
            first: firstSpan,
            second: secondSpan
        )
    }

    private static func pageAlignedInterval(
        baseAddress: UInt64,
        length: UInt64
    ) -> (base: UInt64, end: UInt64)? {
        guard length > 0,
              length <= UInt64.max - baseAddress,
              let end = MemoryPageGeometry.alignUp(baseAddress + length)
        else {
            return nil
        }
        let base = MemoryPageGeometry.alignDown(baseAddress)
        guard end > base else { return nil }
        return (base: base, end: end)
    }

    private static func driverVirtualAddressesAreValid(
        _ plan: BootDriverResourcePlan,
        userMappings: KernelEL0AddressSpaceMappings
    ) -> Bool {
        var memoryIndex = 0
        while memoryIndex < plan.memoryResourceCount {
            guard let mapping = plan.memoryMapping(at: memoryIndex),
                  !overlapsUserMappings(
                      baseAddress: mapping.virtualBaseAddress,
                      length: mapping.byteCount,
                      userMappings: userMappings
                  )
            else {
                return false
            }
            memoryIndex += 1
        }

        var mmioIndex = 0
        while mmioIndex < plan.mmioResourceCount {
            guard let mapping = plan.mmioMapping(at: mmioIndex),
                  !overlapsUserMappings(
                      baseAddress: mapping.virtualBaseAddress,
                      length: mapping.byteCount,
                      userMappings: userMappings
                  )
            else {
                return false
            }
            mmioIndex += 1
        }
        return true
    }

    private static func overlapsUserMappings(
        baseAddress: UInt64,
        length: UInt64,
        userMappings: KernelEL0AddressSpaceMappings
    ) -> Bool {
        guard let interval = pageAlignedInterval(
                  baseAddress: baseAddress,
                  length: length
              )
        else {
            return true
        }
        if overlaps(interval, userMappings.userText) {
            return true
        }
        if let readOnly = userMappings.userReadOnlyData,
           overlaps(interval, readOnly) {
            return true
        }
        return overlaps(interval, userMappings.firstUserStack)
            || overlaps(interval, userMappings.secondUserStack)
            || overlaps(interval, userMappings.firstUserStackGuard)
            || overlaps(interval, userMappings.secondUserStackGuard)
    }

    private static func overlaps(
        _ interval: (base: UInt64, end: UInt64),
        _ mapping: FinalMappingRegion
    ) -> Bool {
        interval.base < mapping.virtualEndAddress
            && mapping.virtualBaseAddress < interval.end
    }

    private static func overlaps(
        _ interval: (base: UInt64, end: UInt64),
        _ guardRegion: FinalGuardRegion
    ) -> Bool {
        guard let byteCount = MemoryPageGeometry.byteCount(
                  forPageCount: guardRegion.pageCount
              )
        else {
            return true
        }
        return interval.base < guardRegion.virtualBaseAddress + byteCount
            && guardRegion.virtualBaseAddress < interval.end
    }

    private static func finalLayout(
        platform: Platform,
        userMappings: KernelEL0AddressSpaceMappings,
        driverPlan: BootDriverResourcePlan
    ) -> FinalAddressSpaceLayout? {
        guard let kernelReadOnly:
                UnsafeMutableBufferPointer<FinalMappingRegion> = layoutBuffer(
                    offset: LayoutOffset.kernelReadOnly,
                    count: kernelReadOnlyCapacity
                ),
              let kernelData:
                UnsafeMutableBufferPointer<FinalMappingRegion> = layoutBuffer(
                    offset: LayoutOffset.kernelData,
                    count: kernelDataCapacity
                ),
              let userStacks:
                UnsafeMutableBufferPointer<FinalMappingRegion> = layoutBuffer(
                    offset: LayoutOffset.userStacks,
                    count: userStackCapacity
                ),
              let mmio: UnsafeMutableBufferPointer<FinalMappingRegion>
                = layoutBuffer(
                    offset: LayoutOffset.mmio,
                    count: mmioCapacity
                ),
              let guards: UnsafeMutableBufferPointer<FinalGuardRegion>
                = layoutBuffer(
                    offset: LayoutOffset.guards,
                    count: guardCapacity
                ),
              let kernelText = identityMapping(
                  KernelLinkerLayout.kernelText,
                  role: .kernelText
              ),
              let kernelRO = identityMapping(
                  KernelLinkerLayout.kernelReadOnlyData,
                  role: .kernelReadOnlyData
              ),
              let deviceTreeRO = byteSpanIdentityMapping(
                  baseAddress: platform.deviceTreeAddress,
                  length: platform.deviceTreeSize,
                  role: .kernelReadOnlyData
              )
        else {
            return nil
        }

        var readOnlyCount = 0
        guard append(kernelRO, to: kernelReadOnly, count: &readOnlyCount),
              append(
                  deviceTreeRO,
                  to: kernelReadOnly,
                  count: &readOnlyCount
              )
        else {
            return nil
        }

        var dataCount = 0
        var guardCount = 0
        let data = KernelLinkerLayout.kernelData
        let bootStack = KernelLinkerLayout.bootStack
        let secondaryStacks = KernelLinkerLayout.secondaryStacks
        guard appendIdentityData(
                  start: data.start,
                  end: bootStack.start,
                  to: kernelData,
                  count: &dataCount
              ),
              append(
                  FinalGuardRegion(
                      virtualBaseAddress: bootStack.start,
                      pageCount: 1
                  ),
                  to: guards,
                  count: &guardCount
              ),
              appendIdentityData(
                  start: bootStack.start + MemoryPageGeometry.pageSize,
                  end: secondaryStacks.start,
                  to: kernelData,
                  count: &dataCount
              ),
              secondaryStacks.length % 3 == 0
        else {
            return nil
        }

        let secondaryStackSize = secondaryStacks.length / 3
        guard secondaryStackSize > MemoryPageGeometry.pageSize,
              MemoryPageGeometry.isPageAligned(secondaryStackSize)
        else {
            return nil
        }
        var secondaryIndex: UInt64 = 0
        while secondaryIndex < 3 {
            let stackBase = secondaryStacks.start
                + secondaryIndex * secondaryStackSize
            guard append(
                      FinalGuardRegion(
                          virtualBaseAddress: stackBase,
                          pageCount: 1
                      ),
                      to: guards,
                      count: &guardCount
                  ),
                  appendIdentityData(
                      start: stackBase + MemoryPageGeometry.pageSize,
                      end: stackBase + secondaryStackSize,
                      to: kernelData,
                      count: &dataCount
                  )
            else {
                return nil
            }
            secondaryIndex += 1
        }
        guard appendIdentityData(
                  start: secondaryStacks.end,
                  end: data.end,
                  to: kernelData,
                  count: &dataCount
              )
        else {
            return nil
        }

        var driverMemoryIndex = 0
        while driverMemoryIndex < driverPlan.memoryResourceCount {
            guard let mapping = driverPlan.memoryMapping(
                      at: driverMemoryIndex
                  ),
                  append(
                      mapping,
                      to: kernelData,
                      count: &dataCount
                  )
            else {
                return nil
            }
            driverMemoryIndex += 1
        }

        // User stack count is separate from the privileged data count.
        userStacks[0] = userMappings.firstUserStack
        userStacks[1] = userMappings.secondUserStack
        guard append(
                  userMappings.firstUserStackGuard,
                  to: guards,
                  count: &guardCount
              ),
              append(
                  userMappings.secondUserStackGuard,
                  to: guards,
                  count: &guardCount
              )
        else {
            return nil
        }

        var mmioCount = 0
        guard appendDevice(
                  platform.serial,
                  to: mmio,
                  count: &mmioCount
              )
        else {
            return nil
        }
        switch platform.interruptController {
        case let .gicV2(distributor, cpuInterface):
            guard appendDevice(
                      distributor,
                      to: mmio,
                      count: &mmioCount
                  ),
                  appendDevice(
                      cpuInterface,
                      to: mmio,
                      count: &mmioCount
                  )
            else {
                return nil
            }
        case let .gicV3(distributor, redistributor):
            guard appendDevice(
                      distributor,
                      to: mmio,
                      count: &mmioCount
                  ),
                  appendDevice(
                      redistributor,
                      to: mmio,
                      count: &mmioCount
                  )
            else {
                return nil
            }
        }
        if let firmware = platform.firmwareConfiguration,
           !appendDevice(firmware, to: mmio, count: &mmioCount) {
            return nil
        }
        if let virtio = platform.virtioTransportWindow,
           !appendDevice(virtio, to: mmio, count: &mmioCount) {
            return nil
        }
        var driverMMIOIndex = 0
        while driverMMIOIndex < driverPlan.mmioResourceCount {
            guard let mapping = driverPlan.mmioMapping(
                      at: driverMMIOIndex
                  ),
                  append(mapping, to: mmio, count: &mmioCount)
            else {
                return nil
            }
            driverMMIOIndex += 1
        }

        return FinalAddressSpaceLayout(
            kind: .user,
            identifier: AddressSpaceIdentifier(value: 1, generation: 0),
            kernelText: kernelText,
            kernelReadOnlyDataRegions: immutable(
                kernelReadOnly,
                count: readOnlyCount
            ),
            kernelDataRegions: immutable(kernelData, count: dataCount),
            userText: userMappings.userText,
            userReadOnlyData: userMappings.userReadOnlyData,
            userStacks: immutable(userStacks, count: userStackCapacity),
            mmioRegions: immutable(mmio, count: mmioCount),
            guardRegions: immutable(guards, count: guardCount)
        )
    }

    private static func translationTablePoolRange() -> PhysicalPageRange? {
        let start = KernelLinkerLayout.finalLevel1Table.start
        let end = KernelLinkerLayout.finalLevel3Tables.end
        guard end > start,
              MemoryPageGeometry.isPageAligned(start),
              MemoryPageGeometry.isPageAligned(end)
        else {
            return nil
        }
        return PhysicalPageRange(
            baseAddress: start,
            pageCount: (end - start) / MemoryPageGeometry.pageSize
        )
    }

    private static func storageBoundsAreValid() -> Bool {
        let mapStart = KernelLinkerLayout.memoryMapStorage
        let allocatorStart = KernelLinkerLayout.pageAllocatorStorage
        let classifiedFree = KernelLinkerLayout.classifiedFreeRunStorage
        let allocationLedger = KernelLinkerLayout
            .classifiedAllocationLedgerStorage
        let following = AArch64.dmaScratchAddress
        guard allocatorStart >= mapStart,
              classifiedFree.start >= allocatorStart,
              classifiedFree.end >= classifiedFree.start,
              allocationLedger.start >= classifiedFree.end,
              allocationLedger.end >= allocationLedger.start,
              following >= allocationLedger.end
        else {
            return false
        }
        return pagingLayoutStorageIsValid()
            && allocatorStart - mapStart >= requiredBytes(
                PhysicalPageRange.self,
                count: memoryMapCapacity
            )
            && classifiedFree.start - allocatorStart >= requiredBytes(
                PhysicalPageRange.self,
                count: bootstrapAllocatorCapacity
            )
            && classifiedFree.length >= requiredBytes(
                ClassifiedPhysicalPageRange.self,
                count: classifiedFreeRunCapacity
            )
            && allocationLedger.length >= requiredBytes(
                ClassifiedPageAllocationToken.self,
                count: classifiedActiveAllocationCapacity
            )
    }

    private static func pagingLayoutStorageIsValid() -> Bool {
        let region = KernelLinkerLayout.pagingLayoutStorage
        let readOnlyEnd = UInt64(LayoutOffset.kernelReadOnly)
            + requiredBytes(
                FinalMappingRegion.self,
                count: kernelReadOnlyCapacity
            )
        let dataEnd = UInt64(LayoutOffset.kernelData)
            + requiredBytes(
                FinalMappingRegion.self,
                count: kernelDataCapacity
            )
        let userStackEnd = UInt64(LayoutOffset.userStacks)
            + requiredBytes(
                FinalMappingRegion.self,
                count: userStackCapacity
            )
        let mmioEnd = UInt64(LayoutOffset.mmio)
            + requiredBytes(
                FinalMappingRegion.self,
                count: mmioCapacity
            )
        let guardEnd = UInt64(LayoutOffset.guards)
            + requiredBytes(FinalGuardRegion.self, count: guardCapacity)
        let reservationEnd = UInt64(LayoutOffset.explicitReservations)
            + requiredBytes(
                PhysicalByteSpan.self,
                count: explicitReservationCapacity
            )

        return UInt64(LayoutOffset.kernelReadOnly)
                % UInt64(MemoryLayout<FinalMappingRegion>.alignment) == 0
            && UInt64(LayoutOffset.kernelData)
                % UInt64(MemoryLayout<FinalMappingRegion>.alignment) == 0
            && UInt64(LayoutOffset.userStacks)
                % UInt64(MemoryLayout<FinalMappingRegion>.alignment) == 0
            && UInt64(LayoutOffset.mmio)
                % UInt64(MemoryLayout<FinalMappingRegion>.alignment) == 0
            && UInt64(LayoutOffset.guards)
                % UInt64(MemoryLayout<FinalGuardRegion>.alignment) == 0
            && UInt64(LayoutOffset.explicitReservations)
                % UInt64(MemoryLayout<PhysicalByteSpan>.alignment) == 0
            && readOnlyEnd <= UInt64(LayoutOffset.kernelData)
            && dataEnd <= UInt64(LayoutOffset.userStacks)
            && userStackEnd <= UInt64(LayoutOffset.mmio)
            && mmioEnd <= UInt64(LayoutOffset.guards)
            && guardEnd <= UInt64(LayoutOffset.explicitReservations)
            && reservationEnd <= region.length
    }

    private static func explicitReservationStorage()
        -> UnsafeMutableBufferPointer<PhysicalByteSpan>? {
        layoutBuffer(
            offset: LayoutOffset.explicitReservations,
            count: explicitReservationCapacity
        )
    }

    private static func identityMapping(
        _ region: LinkerRegion,
        role: MemoryRegionRole
    ) -> FinalMappingRegion? {
        guard region.length > 0,
              MemoryPageGeometry.isPageAligned(region.start),
              let end = MemoryPageGeometry.alignUp(region.end),
              end > region.start
        else {
            return nil
        }
        return FinalMappingRegion(
            virtualBaseAddress: region.start,
            physicalBaseAddress: region.start,
            byteCount: end - region.start,
            role: role
        )
    }

    private static func byteSpanIdentityMapping(
        baseAddress: UInt64,
        length: UInt64,
        role: MemoryRegionRole
    ) -> FinalMappingRegion? {
        guard length > 0,
              length <= UInt64.max - baseAddress,
              let end = MemoryPageGeometry.alignUp(baseAddress + length)
        else {
            return nil
        }
        let start = MemoryPageGeometry.alignDown(baseAddress)
        return FinalMappingRegion(
            virtualBaseAddress: start,
            physicalBaseAddress: start,
            byteCount: end - start,
            role: role
        )
    }

    private static func appendIdentityData(
        start: UInt64,
        end: UInt64,
        to storage: UnsafeMutableBufferPointer<FinalMappingRegion>,
        count: inout Int
    ) -> Bool {
        guard end >= start else { return false }
        if end == start { return true }
        guard let region = FinalMappingRegion(
            virtualBaseAddress: start,
            physicalBaseAddress: start,
            byteCount: end - start,
            role: .kernelData
        ) else {
            return false
        }
        return append(region, to: storage, count: &count)
    }

    private static func appendDevice(
        _ resource: DeviceResource,
        to storage: UnsafeMutableBufferPointer<FinalMappingRegion>,
        count: inout Int
    ) -> Bool {
        guard let mapping = byteSpanIdentityMapping(
            baseAddress: resource.baseAddress,
            length: resource.length,
            role: .device
        ) else {
            return false
        }
        return append(mapping, to: storage, count: &count)
    }

    private static func append<T>(
        _ value: T?,
        to storage: UnsafeMutableBufferPointer<T>,
        count: inout Int
    ) -> Bool {
        guard let value else { return false }
        guard count < storage.count else { return false }
        storage[count] = value
        count += 1
        return true
    }

    private static func immutable<T>(
        _ storage: UnsafeMutableBufferPointer<T>,
        count: Int
    ) -> UnsafeBufferPointer<T> {
        UnsafeBufferPointer(start: storage.baseAddress, count: count)
    }

    private static func layoutBuffer<T>(
        offset: Int,
        count: Int
    ) -> UnsafeMutableBufferPointer<T>? {
        let region = KernelLinkerLayout.pagingLayoutStorage
        guard offset >= 0,
              count > 0,
              let bytes = byteCount(T.self, count: count),
              UInt64(offset) <= region.length,
              bytes <= region.length - UInt64(offset),
              region.start <= UInt64(UInt.max) - UInt64(offset)
        else {
            return nil
        }
        return fixedBuffer(at: region.start + UInt64(offset), count: count)
    }

    private static func fixedBuffer<T>(
        at address: UInt64,
        count: Int
    ) -> UnsafeMutableBufferPointer<T>? {
        guard address != 0,
              address <= UInt64(UInt.max),
              count > 0,
              address % UInt64(MemoryLayout<T>.alignment) == 0,
              let pointer = UnsafeMutablePointer<T>(
                  bitPattern: UInt(address)
              )
        else {
            return nil
        }
        return UnsafeMutableBufferPointer(start: pointer, count: count)
    }

    private static func requiredBytes<T>(
        _ type: T.Type,
        count: Int
    ) -> UInt64 {
        UInt64(MemoryLayout<T>.stride) * UInt64(count)
    }

    private static func byteCount<T>(
        _ type: T.Type,
        count: Int
    ) -> UInt64? {
        guard count > 0,
              UInt64(count) <= UInt64.max / UInt64(MemoryLayout<T>.stride)
        else {
            return nil
        }
        return UInt64(MemoryLayout<T>.stride) * UInt64(count)
    }
}

@_silgen_name("arch_memory_allocator_lock")
private func archMemoryAllocatorLock(
    _ lockWord: UnsafeMutablePointer<UInt32>
) -> UInt64

@_silgen_name("arch_memory_allocator_unlock")
private func archMemoryAllocatorUnlock(
    _ lockWord: UnsafeMutablePointer<UInt32>,
    _ interruptState: UInt64
)
