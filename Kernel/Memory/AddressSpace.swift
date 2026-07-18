struct AddressSpaceIdentifier: Equatable {
    let value: UInt16
    let generation: UInt64

    static let kernel = AddressSpaceIdentifier(value: 0, generation: 0)
}

struct ASIDAllocation: Equatable {
    let identifier: AddressSpaceIdentifier
    let requiresGlobalTLBFlush: Bool
}

/// Allocates nonzero ASIDs deterministically. Reuse is generation-tagged and
/// explicitly tells the caller when a global TLB invalidation is required.
struct AddressSpaceIdentifierAllocator {
    let bitWidth: UInt8
    private let maximumValue: UInt32
    private var nextValue: UInt32 = 1
    private(set) var generation: UInt64 = 0

    init?(bitWidth: UInt8) {
        guard bitWidth == 8 || bitWidth == 16 else {
            return nil
        }
        self.bitWidth = bitWidth
        maximumValue = bitWidth == 8 ? 0xff : 0xffff
    }

    mutating func allocate() -> ASIDAllocation {
        var requiresFlush = false
        if nextValue > maximumValue {
            nextValue = 1
            generation &+= 1
            requiresFlush = true
        }
        let identifier = AddressSpaceIdentifier(
            value: UInt16(nextValue),
            generation: generation
        )
        nextValue += 1
        return ASIDAllocation(
            identifier: identifier,
            requiresGlobalTLBFlush: requiresFlush
        )
    }

    func isCurrent(_ identifier: AddressSpaceIdentifier) -> Bool {
        identifier.value != 0
            && UInt32(identifier.value) <= maximumValue
            && identifier.generation == generation
    }
}

struct AddressSpaceKind: Equatable {
    private let value: UInt8

    static let kernel = AddressSpaceKind(value: 0)
    static let user = AddressSpaceKind(value: 1)
}

struct AddressSpaceMetadata: Equatable {
    private static let tableAddressMask: UInt64 = 0x0000_ffff_ffff_f000

    let kind: AddressSpaceKind
    let rootTablePhysicalAddress: UInt64
    let identifier: AddressSpaceIdentifier

    init?(
        kind: AddressSpaceKind,
        rootTablePhysicalAddress: UInt64,
        identifier: AddressSpaceIdentifier
    ) {
        guard rootTablePhysicalAddress != 0,
              rootTablePhysicalAddress & ~Self.tableAddressMask == 0,
              MemoryPageGeometry.isPageAligned(rootTablePhysicalAddress)
        else {
            return nil
        }
        if kind == .kernel {
            guard identifier.value == 0 else {
                return nil
            }
        } else {
            // TCR_EL1.AS remains zero, so TTBR0 uses its 8-bit ASID field.
            guard identifier.value != 0, identifier.value <= 0xff else {
                return nil
            }
        }
        self.kind = kind
        self.rootTablePhysicalAddress = rootTablePhysicalAddress
        self.identifier = identifier
    }

    /// TTBR value for a 48-bit output address and an 8-bit ASID in [63:56].
    var translationTableBaseRegisterValue: UInt64 {
        rootTablePhysicalAddress | UInt64(identifier.value) << 56
    }
}

enum VirtualRegionBacking: Equatable {
    case physical(baseAddress: UInt64, role: MemoryRegionRole)
    case guardPages
}

struct VirtualMemoryRegion: Equatable {
    let virtualBaseAddress: UInt64
    let pageCount: UInt64
    let backing: VirtualRegionBacking

    static let empty = VirtualMemoryRegion(
        uncheckedVirtualBaseAddress: 0,
        pageCount: 0,
        backing: .guardPages
    )

    static func mapping(
        virtualBaseAddress: UInt64,
        physicalBaseAddress: UInt64,
        pageCount: UInt64,
        role: MemoryRegionRole
    ) -> VirtualMemoryRegion? {
        guard validVirtualRange(
            baseAddress: virtualBaseAddress,
            pageCount: pageCount
        ),
        PhysicalPageRange(
            baseAddress: physicalBaseAddress,
            pageCount: pageCount
        ) != nil else {
            return nil
        }
        return VirtualMemoryRegion(
            uncheckedVirtualBaseAddress: virtualBaseAddress,
            pageCount: pageCount,
            backing: .physical(baseAddress: physicalBaseAddress, role: role)
        )
    }

    static func guardPages(
        virtualBaseAddress: UInt64,
        pageCount: UInt64
    ) -> VirtualMemoryRegion? {
        guard validVirtualRange(
            baseAddress: virtualBaseAddress,
            pageCount: pageCount
        ) else {
            return nil
        }
        return VirtualMemoryRegion(
            uncheckedVirtualBaseAddress: virtualBaseAddress,
            pageCount: pageCount,
            backing: .guardPages
        )
    }

    private init(
        uncheckedVirtualBaseAddress: UInt64,
        pageCount: UInt64,
        backing: VirtualRegionBacking
    ) {
        virtualBaseAddress = uncheckedVirtualBaseAddress
        self.pageCount = pageCount
        self.backing = backing
    }

    var byteCount: UInt64 {
        pageCount * MemoryPageGeometry.pageSize
    }

    var endAddress: UInt64 {
        virtualBaseAddress + byteCount
    }

    func contains(address: UInt64) -> Bool {
        address >= virtualBaseAddress && address < endAddress
    }

    func contains(baseAddress: UInt64, length: UInt64) -> Bool {
        guard let end = MemoryPageGeometry.adding(baseAddress, length) else {
            return false
        }
        return baseAddress >= virtualBaseAddress && end <= endAddress
    }

    func physicalAddress(for virtualAddress: UInt64) -> UInt64? {
        guard contains(address: virtualAddress) else {
            return nil
        }
        switch backing {
        case let .physical(baseAddress, _):
            return baseAddress + (virtualAddress - virtualBaseAddress)
        case .guardPages:
            return nil
        }
    }

    private static func validVirtualRange(
        baseAddress: UInt64,
        pageCount: UInt64
    ) -> Bool {
        guard MemoryPageGeometry.isPageAligned(baseAddress),
              pageCount > 0,
              let byteCount = MemoryPageGeometry.byteCount(forPageCount: pageCount),
              byteCount <= UInt64.max - baseAddress
        else {
            return false
        }
        let lastAddress = baseAddress + byteCount - 1
        guard TranslationTableGeometry.isCanonical48BitAddress(baseAddress),
              TranslationTableGeometry.isCanonical48BitAddress(lastAddress)
        else {
            return false
        }
        return baseAddress >> 48 == lastAddress >> 48
    }
}

/// Sorted, non-overlapping virtual-region metadata. An absent entry is unmapped;
/// guard regions remain explicit so translation faults can be diagnosed.
struct AddressSpaceRegionTable {
    private var storage: UnsafeMutableBufferPointer<VirtualMemoryRegion>
    private(set) var count: Int = 0

    init(storage: UnsafeMutableBufferPointer<VirtualMemoryRegion>) {
        self.storage = storage
        var index = 0
        while index < storage.count {
            storage[index] = .empty
            index += 1
        }
    }

    var capacity: Int {
        storage.count
    }

    func region(at index: Int) -> VirtualMemoryRegion? {
        guard index >= 0, index < count else {
            return nil
        }
        return storage[index]
    }

    func region(containing virtualAddress: UInt64) -> VirtualMemoryRegion? {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            let candidate = storage[middle]
            if virtualAddress < candidate.virtualBaseAddress {
                high = middle
            } else if virtualAddress >= candidate.endAddress {
                low = middle + 1
            } else {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    mutating func insert(_ region: VirtualMemoryRegion) -> Bool {
        guard region.pageCount > 0, count < storage.count else {
            return false
        }
        var insertion = 0
        while insertion < count,
              storage[insertion].virtualBaseAddress < region.virtualBaseAddress {
            insertion += 1
        }
        if insertion > 0,
           storage[insertion - 1].endAddress > region.virtualBaseAddress {
            return false
        }
        if insertion < count,
           storage[insertion].virtualBaseAddress < region.endAddress {
            return false
        }

        var move = count
        while move > insertion {
            storage[move] = storage[move - 1]
            move -= 1
        }
        storage[insertion] = region
        count += 1
        return true
    }

    /// Removes an exact metadata region, making the range unmapped.
    @discardableResult
    mutating func unmap(
        virtualBaseAddress: UInt64,
        pageCount: UInt64
    ) -> Bool {
        var index = 0
        while index < count {
            let candidate = storage[index]
            if candidate.virtualBaseAddress == virtualBaseAddress,
               candidate.pageCount == pageCount {
                var move = index
                while move + 1 < count {
                    storage[move] = storage[move + 1]
                    move += 1
                }
                count -= 1
                storage[count] = .empty
                return true
            }
            if candidate.virtualBaseAddress > virtualBaseAddress {
                return false
            }
            index += 1
        }
        return false
    }
}

extension PageTablePageBuilder {
    /// Installs one leaf-sized portion of region metadata into this table page.
    @discardableResult
    mutating func install(
        region: VirtualMemoryRegion,
        at virtualAddress: UInt64,
        level: PageTableLevel
    ) -> Bool {
        guard region.contains(
            baseAddress: virtualAddress,
            length: level.entrySpan
        ) else {
            return false
        }
        switch region.backing {
        case let .physical(physicalBaseAddress, role):
            let offset = virtualAddress - region.virtualBaseAddress
            guard let physicalAddress = MemoryPageGeometry.adding(
                physicalBaseAddress,
                offset
            ) else {
                return false
            }
            return installMapping(
                for: virtualAddress,
                level: level,
                physicalAddress: physicalAddress,
                role: role
            )
        case .guardPages:
            return installGuard(for: virtualAddress, level: level)
        }
    }
}
