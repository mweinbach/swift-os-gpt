enum FinalTranslationTableGeometry {
    /// TCR_EL1.T0SZ = 25 gives TTBR0 a 39-bit lower virtual address space.
    /// With a 4 KiB granule, the first walked table is level 1.
    static let t0sz: UInt8 = 25
    static let inputAddressBits: UInt8 = 39
    static let virtualAddressLimit: UInt64 = 1 << 39
    static let outputAddressLimit: UInt64 = 1 << 48
    static let startLevel = PageTableLevel.level1
    static let pagesPerLevel2Block: UInt64 = 512
}

/// One exact virtual-to-physical mapping request. All requested bytes occupy
/// complete pages; linker-symbol callers should round section ends upward.
struct FinalMappingRegion: Equatable {
    let virtualBaseAddress: UInt64
    let physicalBaseAddress: UInt64
    let pageCount: UInt64
    let role: MemoryRegionRole

    init?(
        virtualBaseAddress: UInt64,
        physicalBaseAddress: UInt64,
        pageCount: UInt64,
        role: MemoryRegionRole
    ) {
        guard MemoryPageGeometry.isPageAligned(virtualBaseAddress),
              let physicalRange = PhysicalPageRange(
                  baseAddress: physicalBaseAddress,
                  pageCount: pageCount
              ),
              physicalRange.endAddress
                  <= FinalTranslationTableGeometry.outputAddressLimit,
              let byteCount = MemoryPageGeometry.byteCount(
                  forPageCount: pageCount
              ),
              virtualBaseAddress
                  < FinalTranslationTableGeometry.virtualAddressLimit,
              byteCount
                  <= FinalTranslationTableGeometry.virtualAddressLimit
                    - virtualBaseAddress
        else {
            return nil
        }
        self.virtualBaseAddress = virtualBaseAddress
        self.physicalBaseAddress = physicalBaseAddress
        self.pageCount = pageCount
        self.role = role
    }

    init?(
        virtualBaseAddress: UInt64,
        physicalBaseAddress: UInt64,
        byteCount: UInt64,
        role: MemoryRegionRole
    ) {
        guard byteCount > 0,
              byteCount & MemoryPageGeometry.pageMask == 0
        else {
            return nil
        }
        self.init(
            virtualBaseAddress: virtualBaseAddress,
            physicalBaseAddress: physicalBaseAddress,
            pageCount: byteCount / MemoryPageGeometry.pageSize,
            role: role
        )
    }

    var byteCount: UInt64 {
        pageCount * MemoryPageGeometry.pageSize
    }

    var virtualEndAddress: UInt64 {
        virtualBaseAddress + byteCount
    }
}

struct FinalGuardRegion: Equatable {
    let virtualBaseAddress: UInt64
    let pageCount: UInt64

    init?(virtualBaseAddress: UInt64, pageCount: UInt64) {
        guard MemoryPageGeometry.isPageAligned(virtualBaseAddress),
              pageCount > 0,
              let byteCount = MemoryPageGeometry.byteCount(
                  forPageCount: pageCount
              ),
              virtualBaseAddress
                  < FinalTranslationTableGeometry.virtualAddressLimit,
              byteCount
                  <= FinalTranslationTableGeometry.virtualAddressLimit
                    - virtualBaseAddress
        else {
            return nil
        }
        self.virtualBaseAddress = virtualBaseAddress
        self.pageCount = pageCount
    }
}

/// Exact protection domains plus caller-owned variable-length lists. Buffers
/// must remain alive for the duration of `build`; the builder does not retain
/// them. `availablePhysicalMemory` passed to `build` supplies the block-mapped
/// kernel direct map and must already exclude every exact physical allocation.
struct FinalAddressSpaceLayout {
    let kind: AddressSpaceKind
    let identifier: AddressSpaceIdentifier
    let kernelText: FinalMappingRegion?
    let kernelReadOnlyDataRegions: UnsafeBufferPointer<FinalMappingRegion>
    let kernelDataRegions: UnsafeBufferPointer<FinalMappingRegion>
    let userText: FinalMappingRegion?
    let userReadOnlyData: FinalMappingRegion?
    let userStacks: UnsafeBufferPointer<FinalMappingRegion>
    let mmioRegions: UnsafeBufferPointer<FinalMappingRegion>
    let guardRegions: UnsafeBufferPointer<FinalGuardRegion>
}

enum FinalTranslationLookup: Equatable {
    case unmapped
    case guardPage
    case mapped(
        physicalAddress: UInt64,
        level: PageTableLevel,
        descriptor: UInt64
    )
    case corrupt
}

/// Caller-provided, physically contiguous translation-table storage. The
/// physical and mapped addresses are deliberately distinct so host tests can
/// use an aligned allocation while bare metal can pass its identity mapping.
struct FinalTranslationTablePagePool {
    private static let outputAddressMask: UInt64 = 0x0000_ffff_ffff_f000

    let physicalBaseAddress: UInt64
    let pageCount: Int
    private var storage: UnsafeMutableBufferPointer<UInt64>
    private(set) var usedPageCount: Int = 0

    init?(
        physicalBaseAddress: UInt64,
        pageCount: Int,
        mappedEntries: UnsafeMutableBufferPointer<UInt64>
    ) {
        guard physicalBaseAddress != 0,
              MemoryPageGeometry.isPageAligned(physicalBaseAddress),
              pageCount > 0,
              pageCount <= Int.max / TranslationTableGeometry.entriesPerTable
        else {
            return nil
        }
        let requiredEntries = pageCount
            * TranslationTableGeometry.entriesPerTable
        guard mappedEntries.count >= requiredEntries,
              let byteCount = MemoryPageGeometry.byteCount(
                  forPageCount: UInt64(pageCount)
              ),
              physicalBaseAddress
                  < FinalTranslationTableGeometry.outputAddressLimit,
              byteCount
                  <= FinalTranslationTableGeometry.outputAddressLimit
                    - physicalBaseAddress
        else {
            return nil
        }
        self.physicalBaseAddress = physicalBaseAddress
        self.pageCount = pageCount
        storage = mappedEntries
    }

    var physicalRange: PhysicalPageRange {
        // Construction proves these values valid.
        PhysicalPageRange(
            baseAddress: physicalBaseAddress,
            pageCount: UInt64(pageCount)
        )!
    }

    mutating func reset() {
        var index = 0
        let entryCount = pageCount * TranslationTableGeometry.entriesPerTable
        while index < entryCount {
            storage[index] = PageTableDescriptor.unmapped.rawValue
            index += 1
        }
        usedPageCount = 0
    }

    func lookup(
        rootTablePhysicalAddress: UInt64,
        virtualAddress: UInt64
    ) -> FinalTranslationLookup {
        guard virtualAddress
                < FinalTranslationTableGeometry.virtualAddressLimit,
              containsTable(at: rootTablePhysicalAddress),
              let level1 = rawDescriptor(
                  tablePhysicalAddress: rootTablePhysicalAddress,
                  virtualAddress: virtualAddress,
                  level: .level1
              )
        else {
            return .corrupt
        }

        switch classify(level1) {
        case .unmapped: return .unmapped
        case .guardEntry: return .guardPage
        case .block:
            return mappedLookup(
                descriptor: level1,
                virtualAddress: virtualAddress,
                level: .level1
            )
        case .table:
            break
        case .invalid:
            return .corrupt
        }

        let level2Table = level1 & Self.outputAddressMask
        guard containsTable(at: level2Table),
              let level2 = rawDescriptor(
                  tablePhysicalAddress: level2Table,
                  virtualAddress: virtualAddress,
                  level: .level2
              )
        else {
            return .corrupt
        }
        switch classify(level2) {
        case .unmapped: return .unmapped
        case .guardEntry: return .guardPage
        case .block:
            return mappedLookup(
                descriptor: level2,
                virtualAddress: virtualAddress,
                level: .level2
            )
        case .table:
            break
        case .invalid:
            return .corrupt
        }

        let level3Table = level2 & Self.outputAddressMask
        guard containsTable(at: level3Table),
              let level3 = rawDescriptor(
                  tablePhysicalAddress: level3Table,
                  virtualAddress: virtualAddress,
                  level: .level3
              )
        else {
            return .corrupt
        }
        switch classify(level3) {
        case .unmapped: return .unmapped
        case .guardEntry: return .guardPage
        case .table:
            return mappedLookup(
                descriptor: level3,
                virtualAddress: virtualAddress,
                level: .level3
            )
        default:
            return .corrupt
        }
    }

    fileprivate mutating func allocatePage() -> UInt64? {
        guard usedPageCount < pageCount else {
            return nil
        }
        let pageIndex = usedPageCount
        usedPageCount += 1
        guard var builder = builderForPage(at: pageIndex) else {
            return nil
        }
        builder.clear()
        return physicalBaseAddress
            + UInt64(pageIndex) * MemoryPageGeometry.pageSize
    }

    fileprivate func builder(
        forPhysicalAddress physicalAddress: UInt64
    ) -> PageTablePageBuilder? {
        guard let pageIndex = pageIndex(for: physicalAddress) else {
            return nil
        }
        return builderForPage(at: pageIndex)
    }

    fileprivate func containsTable(at physicalAddress: UInt64) -> Bool {
        pageIndex(for: physicalAddress) != nil
    }

    private func pageIndex(for physicalAddress: UInt64) -> Int? {
        guard physicalAddress >= physicalBaseAddress else {
            return nil
        }
        let offset = physicalAddress - physicalBaseAddress
        guard MemoryPageGeometry.isPageAligned(offset) else {
            return nil
        }
        let index = offset / MemoryPageGeometry.pageSize
        guard index < UInt64(pageCount) else {
            return nil
        }
        return Int(index)
    }

    private func builderForPage(at pageIndex: Int) -> PageTablePageBuilder? {
        guard pageIndex >= 0, pageIndex < pageCount else {
            return nil
        }
        let first = pageIndex * TranslationTableGeometry.entriesPerTable
        let end = first + TranslationTableGeometry.entriesPerTable
        let entries = UnsafeMutableBufferPointer(
            rebasing: storage[first..<end]
        )
        return PageTablePageBuilder(entries: entries)
    }

    private func rawDescriptor(
        tablePhysicalAddress: UInt64,
        virtualAddress: UInt64,
        level: PageTableLevel
    ) -> UInt64? {
        guard let builder = builder(
            forPhysicalAddress: tablePhysicalAddress
        ) else {
            return nil
        }
        return builder.descriptor(
            for: virtualAddress,
            level: level
        )?.rawValue
    }

    private enum DescriptorKind {
        case unmapped
        case guardEntry
        case block
        case table
        case invalid
    }

    private func classify(_ descriptor: UInt64) -> DescriptorKind {
        let parsed = PageTableDescriptor(rawValue: descriptor)
        if parsed.isGuard { return .guardEntry }
        if !parsed.isValid { return descriptor == 0 ? .unmapped : .invalid }
        switch descriptor & 0b11 {
        case 0b01: return .block
        case 0b11: return .table
        default: return .invalid
        }
    }

    private func mappedLookup(
        descriptor: UInt64,
        virtualAddress: UInt64,
        level: PageTableLevel
    ) -> FinalTranslationLookup {
        let physicalBase = descriptor & Self.outputAddressMask
        let offset = virtualAddress & (level.entrySpan - 1)
        return .mapped(
            physicalAddress: physicalBase + offset,
            level: level,
            descriptor: descriptor
        )
    }
}

struct FinalTranslationTableSummary: Equatable {
    let tablePageCount: Int
    let level2TableCount: Int
    let level3TableCount: Int
    let level2BlockCount: UInt64
    let level3PageCount: UInt64
    let guardPageCount: UInt64
    let normalMappedPageCount: UInt64
    let deviceMappedPageCount: UInt64
    let userMappedPageCount: UInt64
}

struct FinalTranslationTables: Equatable {
    let addressSpace: AddressSpaceMetadata
    let t0sz: UInt8
    let startLevel: PageTableLevel
    let summary: FinalTranslationTableSummary
}

enum FinalTranslationTableBuildError: Equatable {
    case invalidLayout
    case invalidAddressSpace
    case tablePoolExhausted
    case mappingConflict
    case tablePoolCorrupt
}

enum FinalTranslationTableBuildResult: Equatable {
    case built(FinalTranslationTables)
    case failed(FinalTranslationTableBuildError)
}

enum FinalTranslationTableBuilder {
    private static let outputAddressMask: UInt64 = 0x0000_ffff_ffff_f000

    static func build(
        availablePhysicalMemory: PhysicalMemoryMap,
        layout: FinalAddressSpaceLayout,
        pool: inout FinalTranslationTablePagePool
    ) -> FinalTranslationTableBuildResult {
        pool.reset()
        guard validate(layout: layout) else {
            return .failed(.invalidLayout)
        }
        guard let rootTable = pool.allocatePage() else {
            return .failed(.tablePoolExhausted)
        }
        guard let addressSpace = AddressSpaceMetadata(
            kind: layout.kind,
            rootTablePhysicalAddress: rootTable,
            identifier: layout.identifier
        ) else {
            pool.reset()
            return .failed(.invalidAddressSpace)
        }

        var state = BuildState(rootTablePhysicalAddress: rootTable)
        if let error = mapExact(layout.kernelText, pool: &pool, state: &state)
            ?? mapExact(layout.userText, pool: &pool, state: &state)
            ?? mapExact(
                layout.userReadOnlyData,
                pool: &pool,
                state: &state
            ) {
            pool.reset()
            return .failed(error)
        }

        var index = 0
        while index < layout.kernelReadOnlyDataRegions.count {
            if let error = mapExact(
                layout.kernelReadOnlyDataRegions[index],
                pool: &pool,
                state: &state
            ) {
                pool.reset()
                return .failed(error)
            }
            index += 1
        }

        index = 0
        while index < layout.kernelDataRegions.count {
            if let error = mapExact(
                layout.kernelDataRegions[index],
                pool: &pool,
                state: &state
            ) {
                pool.reset()
                return .failed(error)
            }
            index += 1
        }

        index = 0
        while index < layout.userStacks.count {
            if let error = mapExact(
                layout.userStacks[index],
                pool: &pool,
                state: &state
            ) {
                pool.reset()
                return .failed(error)
            }
            index += 1
        }

        index = 0
        while index < layout.mmioRegions.count {
            if let error = mapExact(
                layout.mmioRegions[index],
                pool: &pool,
                state: &state
            ) {
                pool.reset()
                return .failed(error)
            }
            index += 1
        }

        // Free RAM has already had all exact allocations removed. Identity map
        // it RW/NX, choosing a 2 MiB block only when both ends are aligned and
        // the complete block belongs to the same normalized free run.
        index = 0
        while index < availablePhysicalMemory.count {
            guard let range = availablePhysicalMemory.range(at: index) else {
                pool.reset()
                return .failed(.invalidLayout)
            }
            if let error = mapPreferredBlocks(
                range: range,
                role: .kernelHeap,
                pool: &pool,
                state: &state
            ) {
                pool.reset()
                return .failed(error)
            }
            index += 1
        }

        index = 0
        while index < layout.guardRegions.count {
            if let error = mapGuards(
                layout.guardRegions[index],
                pool: &pool,
                state: &state
            ) {
                pool.reset()
                return .failed(error)
            }
            index += 1
        }

        let summary = FinalTranslationTableSummary(
            tablePageCount: pool.usedPageCount,
            level2TableCount: state.level2TableCount,
            level3TableCount: state.level3TableCount,
            level2BlockCount: state.level2BlockCount,
            level3PageCount: state.level3PageCount,
            guardPageCount: state.guardPageCount,
            normalMappedPageCount: state.normalMappedPageCount,
            deviceMappedPageCount: state.deviceMappedPageCount,
            userMappedPageCount: state.userMappedPageCount
        )
        return .built(
            FinalTranslationTables(
                addressSpace: addressSpace,
                t0sz: FinalTranslationTableGeometry.t0sz,
                startLevel: FinalTranslationTableGeometry.startLevel,
                summary: summary
            )
        )
    }

    private struct BuildState {
        let rootTablePhysicalAddress: UInt64
        var level2TableCount = 0
        var level3TableCount = 0
        var level2BlockCount: UInt64 = 0
        var level3PageCount: UInt64 = 0
        var guardPageCount: UInt64 = 0
        var normalMappedPageCount: UInt64 = 0
        var deviceMappedPageCount: UInt64 = 0
        var userMappedPageCount: UInt64 = 0
    }

    private static func validate(layout: FinalAddressSpaceLayout) -> Bool {
        guard valid(layout.kernelText, role: .kernelText),
              valid(layout.userText, role: .userText),
              valid(
                  layout.userReadOnlyData,
                  role: .userReadOnlyData
              )
        else {
            return false
        }
        var index = 0
        while index < layout.kernelReadOnlyDataRegions.count {
            guard layout.kernelReadOnlyDataRegions[index].role
                    == .kernelReadOnlyData else {
                return false
            }
            index += 1
        }
        index = 0
        while index < layout.kernelDataRegions.count {
            guard layout.kernelDataRegions[index].role == .kernelData else {
                return false
            }
            index += 1
        }
        index = 0
        while index < layout.userStacks.count {
            guard layout.userStacks[index].role == .userData else {
                return false
            }
            index += 1
        }
        index = 0
        while index < layout.mmioRegions.count {
            guard layout.mmioRegions[index].role == .device else {
                return false
            }
            index += 1
        }
        return true
    }

    private static func valid(
        _ region: FinalMappingRegion?,
        role: MemoryRegionRole
    ) -> Bool {
        region == nil || region?.role == role
    }

    private static func mapExact(
        _ region: FinalMappingRegion?,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> FinalTranslationTableBuildError? {
        guard let region else { return nil }
        return mapExact(region, pool: &pool, state: &state)
    }

    private static func mapExact(
        _ region: FinalMappingRegion,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> FinalTranslationTableBuildError? {
        var page = 0 as UInt64
        while page < region.pageCount {
            let offset = page * MemoryPageGeometry.pageSize
            if let error = installMapping(
                virtualAddress: region.virtualBaseAddress + offset,
                physicalAddress: region.physicalBaseAddress + offset,
                level: .level3,
                role: region.role,
                pool: &pool,
                state: &state
            ) {
                return error
            }
            page += 1
        }
        return nil
    }

    private static func mapPreferredBlocks(
        range: PhysicalPageRange,
        role: MemoryRegionRole,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> FinalTranslationTableBuildError? {
        guard range.endAddress
                <= FinalTranslationTableGeometry.virtualAddressLimit,
              range.endAddress
                <= FinalTranslationTableGeometry.outputAddressLimit
        else {
            return .invalidLayout
        }
        var address = range.baseAddress
        var remainingPages = range.pageCount
        while remainingPages > 0 {
            let usesBlock = address & (PageTableLevel.level2.entrySpan - 1) == 0
                && remainingPages
                    >= FinalTranslationTableGeometry.pagesPerLevel2Block
            let level = usesBlock
                ? PageTableLevel.level2
                : PageTableLevel.level3
            if let error = installMapping(
                virtualAddress: address,
                physicalAddress: address,
                level: level,
                role: role,
                pool: &pool,
                state: &state
            ) {
                return error
            }
            let mappedPages = usesBlock
                ? FinalTranslationTableGeometry.pagesPerLevel2Block
                : 1
            address += mappedPages * MemoryPageGeometry.pageSize
            remainingPages -= mappedPages
        }
        return nil
    }

    private static func mapGuards(
        _ region: FinalGuardRegion,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> FinalTranslationTableBuildError? {
        var page = 0 as UInt64
        while page < region.pageCount {
            let address = region.virtualBaseAddress
                + page * MemoryPageGeometry.pageSize
            guard let level3Table = ensureLevel3Table(
                for: address,
                pool: &pool,
                state: &state
            ) else {
                return pool.usedPageCount == pool.pageCount
                    ? .tablePoolExhausted
                    : .mappingConflict
            }
            guard var builder = pool.builder(
                forPhysicalAddress: level3Table
            ) else {
                return .tablePoolCorrupt
            }
            guard builder.installGuard(for: address, level: .level3) else {
                return .mappingConflict
            }
            state.guardPageCount += 1
            page += 1
        }
        return nil
    }

    private static func installMapping(
        virtualAddress: UInt64,
        physicalAddress: UInt64,
        level: PageTableLevel,
        role: MemoryRegionRole,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> FinalTranslationTableBuildError? {
        guard let level2Table = ensureLevel2Table(
            for: virtualAddress,
            pool: &pool,
            state: &state
        ) else {
            return pool.usedPageCount == pool.pageCount
                ? .tablePoolExhausted
                : .mappingConflict
        }

        let leafTable: UInt64
        if level == .level2 {
            leafTable = level2Table
        } else if level == .level3 {
            guard let level3Table = ensureLevel3Table(
                for: virtualAddress,
                level2Table: level2Table,
                pool: &pool,
                state: &state
            ) else {
                return pool.usedPageCount == pool.pageCount
                    ? .tablePoolExhausted
                    : .mappingConflict
            }
            leafTable = level3Table
        } else {
            return .invalidLayout
        }

        guard var builder = pool.builder(
            forPhysicalAddress: leafTable
        ) else {
            return .tablePoolCorrupt
        }
        guard builder.installMapping(
            for: virtualAddress,
            level: level,
            physicalAddress: physicalAddress,
            role: role
        ) else {
            return .mappingConflict
        }

        let mappedPages = level == .level2
            ? FinalTranslationTableGeometry.pagesPerLevel2Block
            : 1
        if level == .level2 {
            state.level2BlockCount += 1
        } else {
            state.level3PageCount += 1
        }
        if role.attributes.memoryType == .device {
            state.deviceMappedPageCount += mappedPages
        } else {
            state.normalMappedPageCount += mappedPages
        }
        if role.attributes.userAccessible {
            state.userMappedPageCount += mappedPages
        }
        return nil
    }

    private static func ensureLevel2Table(
        for virtualAddress: UInt64,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> UInt64? {
        guard var root = pool.builder(
            forPhysicalAddress: state.rootTablePhysicalAddress
        ), let descriptor = root.descriptor(
            for: virtualAddress,
            level: .level1
        ) else {
            return nil
        }
        if descriptor.rawValue == 0 {
            guard let child = pool.allocatePage() else {
                return nil
            }
            guard root.installNextLevelTable(
                for: virtualAddress,
                level: .level1,
                at: child
            ) else {
                return nil
            }
            state.level2TableCount += 1
            return child
        }
        guard descriptor.isValid,
              descriptor.rawValue & 0b11 == 0b11
        else {
            return nil
        }
        let child = descriptor.rawValue & outputAddressMask
        return pool.containsTable(at: child) ? child : nil
    }

    private static func ensureLevel3Table(
        for virtualAddress: UInt64,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> UInt64? {
        guard let level2Table = ensureLevel2Table(
            for: virtualAddress,
            pool: &pool,
            state: &state
        ) else {
            return nil
        }
        return ensureLevel3Table(
            for: virtualAddress,
            level2Table: level2Table,
            pool: &pool,
            state: &state
        )
    }

    private static func ensureLevel3Table(
        for virtualAddress: UInt64,
        level2Table: UInt64,
        pool: inout FinalTranslationTablePagePool,
        state: inout BuildState
    ) -> UInt64? {
        guard var level2 = pool.builder(
            forPhysicalAddress: level2Table
        ), let descriptor = level2.descriptor(
            for: virtualAddress,
            level: .level2
        ) else {
            return nil
        }
        if descriptor.rawValue == 0 {
            guard let child = pool.allocatePage() else {
                return nil
            }
            guard level2.installNextLevelTable(
                for: virtualAddress,
                level: .level2,
                at: child
            ) else {
                return nil
            }
            state.level3TableCount += 1
            return child
        }
        guard descriptor.isValid,
              descriptor.rawValue & 0b11 == 0b11
        else {
            return nil
        }
        let child = descriptor.rawValue & outputAddressMask
        return pool.containsTable(at: child) ? child : nil
    }
}
