struct PageTableLevel: Equatable {
    private let value: UInt8

    static let level0 = PageTableLevel(value: 0)
    static let level1 = PageTableLevel(value: 1)
    static let level2 = PageTableLevel(value: 2)
    static let level3 = PageTableLevel(value: 3)

    var addressShift: UInt64 {
        switch value {
        case 0: return 39
        case 1: return 30
        case 2: return 21
        default: return MemoryPageGeometry.pageShift
        }
    }

    var entrySpan: UInt64 {
        1 << addressShift
    }

    var supportsLeafMapping: Bool {
        self != .level0
    }

    var supportsNextLevelTable: Bool {
        self != .level3
    }
}

struct PageMemoryType: Equatable {
    private let value: UInt8

    static let device = PageMemoryType(value: 0)
    static let normal = PageMemoryType(value: 1)

    var attributeIndex: UInt64 {
        UInt64(value)
    }
}

struct PageMappingAttributes: Equatable {
    let memoryType: PageMemoryType
    let writable: Bool
    let userAccessible: Bool
    let privilegedExecutable: Bool
    let userExecutable: Bool
    let global: Bool

    static let kernelText = PageMappingAttributes(
        memoryType: .normal,
        writable: false,
        userAccessible: false,
        privilegedExecutable: true,
        userExecutable: false,
        global: true
    )
    static let kernelReadOnlyData = PageMappingAttributes(
        memoryType: .normal,
        writable: false,
        userAccessible: false,
        privilegedExecutable: false,
        userExecutable: false,
        global: true
    )
    static let kernelData = PageMappingAttributes(
        memoryType: .normal,
        writable: true,
        userAccessible: false,
        privilegedExecutable: false,
        userExecutable: false,
        global: true
    )
    static let kernelHeap = kernelData
    static let kernelDevice = PageMappingAttributes(
        memoryType: .device,
        writable: true,
        userAccessible: false,
        privilegedExecutable: false,
        userExecutable: false,
        global: true
    )
    static let userText = PageMappingAttributes(
        memoryType: .normal,
        writable: false,
        userAccessible: true,
        privilegedExecutable: false,
        userExecutable: true,
        global: false
    )
    static let userReadOnlyData = PageMappingAttributes(
        memoryType: .normal,
        writable: false,
        userAccessible: true,
        privilegedExecutable: false,
        userExecutable: false,
        global: false
    )
    static let userData = PageMappingAttributes(
        memoryType: .normal,
        writable: true,
        userAccessible: true,
        privilegedExecutable: false,
        userExecutable: false,
        global: false
    )

    var isWriteXorExecute: Bool {
        !writable || (!privilegedExecutable && !userExecutable)
    }

    var isArchitecturallyValid: Bool {
        guard isWriteXorExecute else {
            return false
        }
        guard !userExecutable || userAccessible else {
            return false
        }
        guard memoryType != .device
            || (!privilegedExecutable && !userExecutable) else {
            return false
        }
        return true
    }
}

struct MemoryRegionRole: Equatable {
    private let value: UInt8

    static let kernelText = MemoryRegionRole(value: 0)
    static let kernelReadOnlyData = MemoryRegionRole(value: 1)
    static let kernelData = MemoryRegionRole(value: 2)
    static let kernelHeap = MemoryRegionRole(value: 3)
    static let device = MemoryRegionRole(value: 4)
    static let userText = MemoryRegionRole(value: 5)
    static let userReadOnlyData = MemoryRegionRole(value: 6)
    static let userData = MemoryRegionRole(value: 7)

    var attributes: PageMappingAttributes {
        switch value {
        case 0: return .kernelText
        case 1: return .kernelReadOnlyData
        case 2: return .kernelData
        case 3: return .kernelHeap
        case 4: return .kernelDevice
        case 5: return .userText
        case 6: return .userReadOnlyData
        default: return .userData
        }
    }
}

struct PageTableDescriptor: Equatable {
    private static let validBit: UInt64 = 1 << 0
    private static let tableOrPageBit: UInt64 = 1 << 1
    private static let accessFlagBit: UInt64 = 1 << 10
    private static let nonGlobalBit: UInt64 = 1 << 11
    private static let privilegedExecuteNeverBit: UInt64 = 1 << 53
    private static let userExecuteNeverBit: UInt64 = 1 << 54
    private static let softwareGuardBit: UInt64 = 1 << 63
    private static let outputAddressMask: UInt64 = 0x0000_ffff_ffff_f000

    let rawValue: UInt64

    static let unmapped = PageTableDescriptor(rawValue: 0)
    /// Invalid to hardware, but distinguishable by the kernel fault handler.
    static let guardPage = PageTableDescriptor(rawValue: softwareGuardBit)

    var isValid: Bool {
        rawValue & Self.validBit != 0
    }

    var isGuard: Bool {
        !isValid && rawValue & Self.softwareGuardBit != 0
    }

    static func nextLevelTable(at physicalAddress: UInt64) -> PageTableDescriptor? {
        guard validOutputAddress(physicalAddress),
              MemoryPageGeometry.isPageAligned(physicalAddress)
        else {
            return nil
        }
        return PageTableDescriptor(
            rawValue: physicalAddress | validBit | tableOrPageBit
        )
    }

    static func leaf(
        level: PageTableLevel,
        physicalAddress: UInt64,
        attributes: PageMappingAttributes
    ) -> PageTableDescriptor? {
        guard level.supportsLeafMapping,
              attributes.isArchitecturallyValid,
              validOutputAddress(physicalAddress),
              physicalAddress & (level.entrySpan - 1) == 0
        else {
            return nil
        }

        var value = physicalAddress | validBit | accessFlagBit
        if level == .level3 {
            value |= tableOrPageBit
        }
        value |= attributes.memoryType.attributeIndex << 2
        value |= UInt64(attributes.memoryType == .normal ? 3 : 2) << 8
        if attributes.userAccessible {
            value |= 1 << 6
        }
        if !attributes.writable {
            value |= 1 << 7
        }
        if !attributes.global {
            value |= nonGlobalBit
        }
        if !attributes.privilegedExecutable {
            value |= privilegedExecuteNeverBit
        }
        if !attributes.userExecutable {
            value |= userExecuteNeverBit
        }
        return PageTableDescriptor(rawValue: value)
    }

    private static func validOutputAddress(_ address: UInt64) -> Bool {
        address & ~outputAddressMask == 0
    }
}

enum TranslationTableGeometry {
    static let entriesPerTable = 512

    static func isCanonical48BitAddress(_ address: UInt64) -> Bool {
        let sign = (address >> 47) & 1
        let upper = address >> 48
        return sign == 0 ? upper == 0 : upper == 0xffff
    }

    static func index(
        for virtualAddress: UInt64,
        level: PageTableLevel
    ) -> Int? {
        guard isCanonical48BitAddress(virtualAddress) else {
            return nil
        }
        return Int((virtualAddress >> level.addressShift) & 0x1ff)
    }
}

/// Mutates one caller-owned 4 KiB translation-table page. It deliberately does
/// not allocate child tables; the physical allocator and address-space owner
/// retain that policy decision.
struct PageTablePageBuilder {
    private var entries: UnsafeMutableBufferPointer<UInt64>

    init?(entries: UnsafeMutableBufferPointer<UInt64>) {
        guard entries.count >= TranslationTableGeometry.entriesPerTable else {
            return nil
        }
        self.entries = entries
    }

    mutating func clear() {
        var index = 0
        while index < TranslationTableGeometry.entriesPerTable {
            entries[index] = PageTableDescriptor.unmapped.rawValue
            index += 1
        }
    }

    @discardableResult
    mutating func installNextLevelTable(
        for virtualAddress: UInt64,
        level: PageTableLevel,
        at physicalAddress: UInt64
    ) -> Bool {
        guard level.supportsNextLevelTable,
              let index = TranslationTableGeometry.index(
                for: virtualAddress,
                level: level
              ),
              let descriptor = PageTableDescriptor.nextLevelTable(
                at: physicalAddress
              ),
              entries[index] == PageTableDescriptor.unmapped.rawValue
        else {
            return false
        }
        entries[index] = descriptor.rawValue
        return true
    }

    @discardableResult
    mutating func installMapping(
        for virtualAddress: UInt64,
        level: PageTableLevel,
        physicalAddress: UInt64,
        role: MemoryRegionRole
    ) -> Bool {
        guard virtualAddress & (level.entrySpan - 1) == 0,
              let index = TranslationTableGeometry.index(
                for: virtualAddress,
                level: level
              ),
              let descriptor = PageTableDescriptor.leaf(
                level: level,
                physicalAddress: physicalAddress,
                attributes: role.attributes
              ),
              entries[index] == PageTableDescriptor.unmapped.rawValue
        else {
            return false
        }
        entries[index] = descriptor.rawValue
        return true
    }

    @discardableResult
    mutating func installGuard(
        for virtualAddress: UInt64,
        level: PageTableLevel
    ) -> Bool {
        guard virtualAddress & (level.entrySpan - 1) == 0,
              let index = TranslationTableGeometry.index(
                for: virtualAddress,
                level: level
              ),
              entries[index] == PageTableDescriptor.unmapped.rawValue
        else {
            return false
        }
        entries[index] = PageTableDescriptor.guardPage.rawValue
        return true
    }

    @discardableResult
    mutating func unmap(
        virtualAddress: UInt64,
        level: PageTableLevel
    ) -> Bool {
        guard virtualAddress & (level.entrySpan - 1) == 0,
              let index = TranslationTableGeometry.index(
                for: virtualAddress,
                level: level
              )
        else {
            return false
        }
        entries[index] = PageTableDescriptor.unmapped.rawValue
        return true
    }

    func descriptor(
        for virtualAddress: UInt64,
        level: PageTableLevel
    ) -> PageTableDescriptor? {
        guard let index = TranslationTableGeometry.index(
            for: virtualAddress,
            level: level
        ) else {
            return nil
        }
        return PageTableDescriptor(rawValue: entries[index])
    }
}
