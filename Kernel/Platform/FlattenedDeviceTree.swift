struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
}

enum SimpleFramebufferFormat: UInt8, Equatable {
    case r5g6b5
    case a8r8g8b8
    case x8r8g8b8

    var bytesPerPixel: UInt64 {
        switch self {
        case .r5g6b5:
            return 2
        case .a8r8g8b8, .x8r8g8b8:
            return 4
        }
    }
}

/// Firmware-patched scanout state described by the standard Device Tree
/// `simple-framebuffer` binding. `reg` is the CPU-visible framebuffer span;
/// the display engine has already been configured by platform firmware.
struct SimpleFramebufferDescription: Equatable {
    let resource: DeviceResource
    let widthInPixels: UInt32
    let heightInPixels: UInt32
    let bytesPerRow: UInt32
    let format: SimpleFramebufferFormat
}

private struct DeviceTreeSearchResult {
    let nodeOffset: UInt
    let resource: DeviceResource?
    let widthInPixels: UInt32?
    let heightInPixels: UInt32?
    let bytesPerRow: UInt32?
    let framebufferFormat: SimpleFramebufferFormat?
    let matchedPropertyCells: DeviceTreePropertyCells?
    let matchedPropertyBytes: DeviceTreePropertyBytes?
}

private struct DeviceTreePropertyLocation {
    let offset: UInt
    let length: UInt
}

private struct DeviceTreeInterruptSpecifier {
    let controllerNodeOffset: UInt
    let cells: DeviceTreePropertyCells
}

private struct DeviceTreeInterruptPropertyLayout {
    let controllerNodeOffset: UInt
    let property: DeviceTreePropertyLocation
    let cellCount: UInt

    var tupleByteCount: UInt { cellCount * 4 }
    var tupleCount: Int { Int(property.length / tupleByteCount) }
}

private struct DeviceTreeInterruptParentContext {
    let nodeOffset: UInt?
    let isValid: Bool

    static let missing = DeviceTreeInterruptParentContext(
        nodeOffset: nil,
        isValid: true
    )
    static let invalid = DeviceTreeInterruptParentContext(
        nodeOffset: nil,
        isValid: false
    )
}

private struct DeviceTreeInterruptParentSearchResult {
    let context: DeviceTreeInterruptParentContext
}

/// A deliberately small, allocation-free view of one Device Tree property
/// containing big-endian 32-bit cells. Platform discovery uses this for short
/// hardware specifiers such as `interrupts`; larger or byte-oriented
/// properties fail closed instead of being silently truncated.
struct DeviceTreePropertyCells: Equatable {
    static let maximumCellCount = 8

    private var cell0: UInt32 = 0
    private var cell1: UInt32 = 0
    private var cell2: UInt32 = 0
    private var cell3: UInt32 = 0
    private var cell4: UInt32 = 0
    private var cell5: UInt32 = 0
    private var cell6: UInt32 = 0
    private var cell7: UInt32 = 0

    private(set) var count = 0

    init() {}

    mutating func append(_ value: UInt32) -> Bool {
        guard count < Self.maximumCellCount else { return false }
        switch count {
        case 0: cell0 = value
        case 1: cell1 = value
        case 2: cell2 = value
        case 3: cell3 = value
        case 4: cell4 = value
        case 5: cell5 = value
        case 6: cell6 = value
        default: cell7 = value
        }
        count += 1
        return true
    }

    func cell(at index: Int) -> UInt32? {
        guard index >= 0, index < count else { return nil }
        switch index {
        case 0: return cell0
        case 1: return cell1
        case 2: return cell2
        case 3: return cell3
        case 4: return cell4
        case 5: return cell5
        case 6: return cell6
        default: return cell7
        }
    }
}

/// A bounded, allocation-free copy of one opaque Device Tree property. The
/// FDT remains firmware-owned, so platform descriptions copy short byte and
/// string-list values before retaining them. Properties larger than this
/// deliberately fail closed instead of exposing an unbounded raw pointer.
struct DeviceTreePropertyBytes: Equatable {
    static let maximumByteCount = 64

    private var word0: UInt64 = 0
    private var word1: UInt64 = 0
    private var word2: UInt64 = 0
    private var word3: UInt64 = 0
    private var word4: UInt64 = 0
    private var word5: UInt64 = 0
    private var word6: UInt64 = 0
    private var word7: UInt64 = 0

    private(set) var count = 0

    init() {}

    mutating func append(_ value: UInt8) -> Bool {
        guard count < Self.maximumByteCount else { return false }
        let wordIndex = count >> 3
        let shift = UInt64((count & 7) << 3)
        let encoded = UInt64(value) << shift
        switch wordIndex {
        case 0: word0 |= encoded
        case 1: word1 |= encoded
        case 2: word2 |= encoded
        case 3: word3 |= encoded
        case 4: word4 |= encoded
        case 5: word5 |= encoded
        case 6: word6 |= encoded
        default: word7 |= encoded
        }
        count += 1
        return true
    }

    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < count else { return nil }
        let word: UInt64
        switch index >> 3 {
        case 0: word = word0
        case 1: word = word1
        case 2: word = word2
        case 3: word = word3
        case 4: word = word4
        case 5: word = word5
        case 6: word = word6
        default: word = word7
        }
        return UInt8((word >> UInt64((index & 7) << 3)) & 0xff)
    }

    /// Returns the number of well-formed, non-empty C strings. A string list
    /// without a final NUL, or one containing an empty item, is malformed.
    var cStringCount: Int? {
        guard count > 0, byte(at: count - 1) == 0 else { return nil }
        var strings = 0
        var itemLength = 0
        var index = 0
        while index < count {
            guard let value = byte(at: index) else { return nil }
            if value == 0 {
                guard itemLength > 0 else { return nil }
                strings += 1
                itemLength = 0
            } else {
                itemLength += 1
            }
            index += 1
        }
        return strings
    }

    func cString(at itemIndex: Int, equals expected: StaticString) -> Bool {
        guard itemIndex >= 0, cStringCount != nil else { return false }
        var currentItem = 0
        var start = 0
        var index = 0
        while index < count {
            guard let value = byte(at: index) else { return false }
            if value == 0 {
                if currentItem == itemIndex {
                    let length = index - start
                    return expected.withUTF8Buffer { expectedBytes in
                        guard expectedBytes.count == length else {
                            return false
                        }
                        var byteIndex = 0
                        while byteIndex < length {
                            guard byte(at: start + byteIndex)
                                    == expectedBytes[byteIndex]
                            else {
                                return false
                            }
                            byteIndex += 1
                        }
                        return true
                    }
                }
                currentItem += 1
                start = index + 1
            }
            index += 1
        }
        return false
    }
}

/// One address in a Device Tree bus address space. Two-cell buses use only
/// `value`. A three-cell bus keeps the leading cell as an opaque selector and
/// the remaining 64 bits as the address. This covers PCI `phys.hi` ranges
/// without pretending that an arbitrary 96-bit address fits in UInt64.
private struct DeviceTreeBusAddress {
    let selector: UInt32
    let value: UInt64
}

/// A raw `ranges` level retained by offset into the immutable FDT blob. Keeping
/// the tuples in firmware-owned storage avoids heap allocation and lets lookup
/// examine every range instead of silently accepting only the first tuple.
private struct AddressTranslationLevel {
    let offset: UInt
    let length: UInt
    let childAddressCells: UInt32
    let parentAddressCells: UInt32
    let sizeCells: UInt32
}

/// Bounded root-to-leaf translation path. Eight independently described bus
/// levels are sufficient for the supported QEMU and Pi trees; deeper or
/// malformed paths fail closed instead of falling back to an ancestor mapping.
private struct AddressTranslationPath {
    static let maximumLevelCount = 8

    private var level0: AddressTranslationLevel?
    private var level1: AddressTranslationLevel?
    private var level2: AddressTranslationLevel?
    private var level3: AddressTranslationLevel?
    private var level4: AddressTranslationLevel?
    private var level5: AddressTranslationLevel?
    private var level6: AddressTranslationLevel?
    private var level7: AddressTranslationLevel?

    private(set) var levelCount = 0
    private(set) var isValid = true

    static let identity = AddressTranslationPath()

    mutating func append(_ level: AddressTranslationLevel) -> Bool {
        guard isValid, levelCount < Self.maximumLevelCount else {
            isValid = false
            return false
        }
        switch levelCount {
        case 0: level0 = level
        case 1: level1 = level
        case 2: level2 = level
        case 3: level3 = level
        case 4: level4 = level
        case 5: level5 = level
        case 6: level6 = level
        default: level7 = level
        }
        levelCount += 1
        return true
    }

    mutating func invalidate() {
        isValid = false
    }

    func level(at index: Int) -> AddressTranslationLevel? {
        guard isValid, index >= 0, index < levelCount else { return nil }
        switch index {
        case 0: return level0
        case 1: return level1
        case 2: return level2
        case 3: return level3
        case 4: return level4
        case 5: return level5
        case 6: return level6
        default: return level7
        }
    }
}

/// Address-space metadata that is not part of the numeric address. PCI uses
/// the leading cell for space and attribute flags; ordinary buses encode only
/// an integer address. Keeping the distinction prevents a PCI selector from
/// being mistaken for the high 32 bits of a CPU physical address.
private enum DeviceTreeAddressDomain: UInt8 {
    case scalar
    case pci
}

private enum DeviceTreePCIAddressClass: UInt8 {
    case configuration
    case io
    case memory
}

private struct DeviceTreeDMAAddress {
    let domain: DeviceTreeAddressDomain
    let selector: UInt32
    let value: UInt64
}

/// One ancestor bus's `dma-ranges` contract. Missing properties are retained
/// as identity levels because a descendant DMA window can cross parents that
/// do not repeat `dma-ranges`. An explicitly empty property is also identity,
/// but records that firmware deliberately described the DMA relationship.
private struct DeviceTreeDMATranslationLevel {
    let rangesOffset: UInt
    let rangesLength: UInt
    let hasRangesProperty: Bool
    let childAddressCells: UInt32
    let parentAddressCells: UInt32
    let sizeCells: UInt32
    let childDomain: DeviceTreeAddressDomain
    let parentDomain: DeviceTreeAddressDomain
}

/// The supported boot trees place the network controller under at most eight
/// independently described buses. Deeper trees fail closed rather than
/// silently dropping an address-translation level.
private struct DeviceTreeDMATranslationPath {
    static let maximumLevelCount = 8

    private var level0: DeviceTreeDMATranslationLevel?
    private var level1: DeviceTreeDMATranslationLevel?
    private var level2: DeviceTreeDMATranslationLevel?
    private var level3: DeviceTreeDMATranslationLevel?
    private var level4: DeviceTreeDMATranslationLevel?
    private var level5: DeviceTreeDMATranslationLevel?
    private var level6: DeviceTreeDMATranslationLevel?
    private var level7: DeviceTreeDMATranslationLevel?

    private(set) var levelCount = 0
    private(set) var hasExplicitRanges = false
    private(set) var isValid = true

    mutating func append(_ level: DeviceTreeDMATranslationLevel) -> Bool {
        guard isValid, levelCount < Self.maximumLevelCount else {
            isValid = false
            return false
        }
        switch levelCount {
        case 0: level0 = level
        case 1: level1 = level
        case 2: level2 = level
        case 3: level3 = level
        case 4: level4 = level
        case 5: level5 = level
        case 6: level6 = level
        default: level7 = level
        }
        levelCount += 1
        hasExplicitRanges = hasExplicitRanges || level.hasRangesProperty
        return true
    }

    mutating func invalidate() {
        isValid = false
    }

    func level(at index: Int) -> DeviceTreeDMATranslationLevel? {
        guard isValid, index >= 0, index < levelCount else { return nil }
        switch index {
        case 0: return level0
        case 1: return level1
        case 2: return level2
        case 3: return level3
        case 4: return level4
        case 5: return level5
        case 6: return level6
        default: return level7
        }
    }
}

/// A bounded set is required because one CPU interval can have multiple
/// device-visible aliases. Width filtering may make one alias usable, but two
/// usable aliases remain ambiguous and are rejected by the public resolver.
private struct DeviceTreeDMACandidateSet {
    static let maximumCandidateCount = 8

    private var candidate0: DeviceTreeDMAAddress?
    private var candidate1: DeviceTreeDMAAddress?
    private var candidate2: DeviceTreeDMAAddress?
    private var candidate3: DeviceTreeDMAAddress?
    private var candidate4: DeviceTreeDMAAddress?
    private var candidate5: DeviceTreeDMAAddress?
    private var candidate6: DeviceTreeDMAAddress?
    private var candidate7: DeviceTreeDMAAddress?

    private(set) var count = 0

    mutating func append(_ candidate: DeviceTreeDMAAddress) -> Bool {
        guard count < Self.maximumCandidateCount else { return false }
        switch count {
        case 0: candidate0 = candidate
        case 1: candidate1 = candidate
        case 2: candidate2 = candidate
        case 3: candidate3 = candidate
        case 4: candidate4 = candidate
        case 5: candidate5 = candidate
        case 6: candidate6 = candidate
        default: candidate7 = candidate
        }
        count += 1
        return true
    }

    func candidate(at index: Int) -> DeviceTreeDMAAddress? {
        guard index >= 0, index < count else { return nil }
        switch index {
        case 0: return candidate0
        case 1: return candidate1
        case 2: return candidate2
        case 3: return candidate3
        case 4: return candidate4
        case 5: return candidate5
        case 6: return candidate6
        default: return candidate7
        }
    }
}

struct FlattenedDeviceTree {
    private static let magic: UInt32 = 0xd00d_feed
    private static let headerSize: UInt = 40
    private static let beginNode: UInt32 = 1
    private static let endNode: UInt32 = 2
    private static let property: UInt32 = 3
    private static let noOperation: UInt32 = 4
    private static let end: UInt32 = 9
    private static let maximumSize: UInt = 2 * 1024 * 1024

    private let address: UInt
    private let totalSize: UInt
    private let reservationStart: UInt
    private let structureStart: UInt
    private let structureEnd: UInt
    private let stringsStart: UInt
    private let stringsEnd: UInt

    var blobSize: UInt64 {
        UInt64(totalSize)
    }

    init?(address rawAddress: UInt64) {
        guard rawAddress != 0,
              rawAddress <= UInt64(UInt.max),
              let base = UInt(exactly: rawAddress),
              base & 0x7 == 0
        else {
            return nil
        }

        guard let headerMagic = Self.readBE32(base: base, offset: 0),
              headerMagic == Self.magic,
              let rawTotalSize = Self.readBE32(base: base, offset: 4),
              let rawStructureStart = Self.readBE32(base: base, offset: 8),
              let rawStringsStart = Self.readBE32(base: base, offset: 12),
              let rawReservationStart = Self.readBE32(base: base, offset: 16),
              let rawVersion = Self.readBE32(base: base, offset: 20),
              let rawStringsSize = Self.readBE32(base: base, offset: 32),
              let rawStructureSize = Self.readBE32(base: base, offset: 36)
        else {
            return nil
        }

        let size = UInt(rawTotalSize)
        let structureOffset = UInt(rawStructureStart)
        let stringsOffset = UInt(rawStringsStart)
        let reservationOffset = UInt(rawReservationStart)
        let structureSize = UInt(rawStructureSize)
        let stringsSize = UInt(rawStringsSize)

        guard rawVersion >= 16,
              size >= Self.headerSize,
              size <= Self.maximumSize,
              structureOffset & 0x3 == 0,
              reservationOffset & 0x7 == 0,
              Self.range(offset: reservationOffset, length: 16, fits: size),
              Self.range(offset: structureOffset, length: structureSize, fits: size),
              Self.range(offset: stringsOffset, length: stringsSize, fits: size)
        else {
            return nil
        }

        address = base
        totalSize = size
        reservationStart = reservationOffset
        structureStart = structureOffset
        structureEnd = structureOffset + structureSize
        stringsStart = stringsOffset
        stringsEnd = stringsOffset + stringsSize
    }

    func contains(compatibleWith compatibility: StaticString) -> Bool {
        var remainingMatches = 0
        return search(
            compatibleWith: compatibility,
            deviceType: nil,
            reservedMemory: false,
            remainingMatches: &remainingMatches,
            registerIndex: 0
        ) != nil
    }

    func contains(
        compatibleWith compatibility: StaticString,
        cStringProperty property: StaticString,
        equalTo value: StaticString
    ) -> Bool {
        var remainingMatches = 0
        return search(
            compatibleWith: compatibility,
            deviceType: nil,
            reservedMemory: false,
            remainingMatches: &remainingMatches,
            registerIndex: 0,
            matchingPropertyName: property,
            matchingPropertyValue: value
        ) != nil
    }

    func resource(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        registerIndex: Int = 0
    ) -> DeviceResource? {
        guard nodeIndex >= 0, registerIndex >= 0 else { return nil }
        var remainingMatches = nodeIndex
        return search(
            compatibleWith: compatibility,
            deviceType: nil,
            reservedMemory: false,
            remainingMatches: &remainingMatches,
            registerIndex: registerIndex
        )?.resource
    }

    func propertyCells(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        property: StaticString
    ) -> DeviceTreePropertyCells? {
        guard nodeIndex >= 0,
              let nodeOffset = compatibleNodeOffset(
                  compatibility,
                  nodeIndex: nodeIndex
              )
        else { return nil }
        return propertyCells(atNode: nodeOffset, property: property)
    }

    func propertyBytes(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        property: StaticString
    ) -> DeviceTreePropertyBytes? {
        guard nodeIndex >= 0,
              let nodeOffset = compatibleNodeOffset(
                  compatibility,
                  nodeIndex: nodeIndex
              )
        else { return nil }
        return propertyBytes(atNode: nodeOffset, property: property)
    }

    /// Resolves one Arm GIC interrupt from a compatible node. Tuple width is
    /// obtained from the selected interrupt controller's `#interrupt-cells`;
    /// this routine never assumes that an arbitrary `interrupts` property is
    /// a sequence of three-cell records. Only a directly supported GIC domain
    /// is decoded, so interrupt nexuses and other controller bindings fail
    /// closed rather than being mistaken for architectural GIC INTIDs.
    func gicInterrupt(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        interruptIndex: Int
    ) -> PlatformGICInterrupt? {
        guard let specifier = interruptSpecifier(
                  compatibleWith: compatibility,
                  nodeIndex: nodeIndex,
                  interruptIndex: interruptIndex
              ), specifier.cells.count == 3,
              let interruptType = specifier.cells.cell(at: 0),
              let number = specifier.cells.cell(at: 1),
              let rawFlags = specifier.cells.cell(at: 2)
        else {
            return nil
        }

        let isGICV2 = node(
            at: specifier.controllerNodeOffset,
            isCompatibleWith: "arm,gic-400"
        ) || node(
            at: specifier.controllerNodeOffset,
            isCompatibleWith: "arm,cortex-a15-gic"
        )
        let isGICV3 = node(
            at: specifier.controllerNodeOffset,
            isCompatibleWith: "arm,gic-v3"
        )
        guard isGICV2 != isGICV3,
              rawFlags & (isGICV2 ? 0xffff_00f0 : 0xffff_fff0) == 0,
              let trigger = PlatformInterruptTrigger(
                  rawValue: rawFlags & 0x0f
              )
        else {
            return nil
        }

        switch interruptType {
        case 0:
            // The GIC binding permits only rising-edge and active-high SPIs;
            // its processor-mask field is PPI-only.
            guard number <= 987,
                  rawFlags & 0x0000_ff00 == 0,
                  trigger == .edgeRising || trigger == .levelHigh
            else { return nil }
            return .sharedPeripheral(number: number, trigger: trigger)

        case 1:
            guard number <= 15,
                  !isGICV3
                    || trigger == .edgeRising || trigger == .levelHigh
            else { return nil }
            return .privatePeripheral(
                number: number,
                trigger: trigger,
                processorMask: isGICV2
                    ? UInt8(truncatingIfNeeded: rawFlags >> 8) : 0
            )

        default:
            return nil
        }
    }

    /// Number of complete specifiers in an enabled node's `interrupts`
    /// property, using the resolved controller's declared cell width.
    func interruptCount(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0
    ) -> Int? {
        interruptPropertyLayout(
            compatibleWith: compatibility,
            nodeIndex: nodeIndex
        )?.tupleCount
    }

    /// Resolves a short cell property through a unique Device Tree phandle.
    /// Both standard `phandle` and legacy `linux,phandle` spellings are
    /// accepted when they agree. Duplicate owners or conflicting spellings
    /// fail closed.
    func propertyCells(
        nodePhandle phandle: UInt32,
        property: StaticString
    ) -> DeviceTreePropertyCells? {
        guard let nodeOffset = uniqueNodeOffset(forPhandle: phandle) else {
            return nil
        }
        return propertyCells(atNode: nodeOffset, property: property)
    }

    /// Whether the uniquely resolved phandle owner contains a property. This
    /// is useful for boolean contracts such as `regulator-boot-on`, whose
    /// presence is meaningful even though its value has zero cells.
    func hasProperty(
        nodePhandle phandle: UInt32,
        property: StaticString
    ) -> Bool {
        guard let nodeOffset = uniqueNodeOffset(forPhandle: phandle) else {
            return false
        }
        return propertyLocation(atNode: nodeOffset, property: property) != nil
    }

    /// Whether an enabled compatible node contains a property, independent
    /// of whether that property's value can be decoded into cells or bytes.
    func hasProperty(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        property: StaticString
    ) -> Bool {
        guard nodeIndex >= 0,
              let nodeOffset = compatibleNodeOffset(
                  compatibility,
                  nodeIndex: nodeIndex
              )
        else { return false }
        return propertyLocation(atNode: nodeOffset, property: property) != nil
    }

    func simpleFramebuffer(nodeIndex: Int = 0)
        -> SimpleFramebufferDescription? {
        guard nodeIndex >= 0 else { return nil }
        var remainingMatches = nodeIndex
        guard let result = search(
                  compatibleWith: "simple-framebuffer",
                  deviceType: nil,
                  reservedMemory: false,
                  remainingMatches: &remainingMatches,
                  registerIndex: 0
              ),
              let resource = result.resource,
              resource.length > 0,
              let width = result.widthInPixels,
              let height = result.heightInPixels,
              let stride = result.bytesPerRow,
              let format = result.framebufferFormat,
              width > 0,
              height > 0,
              stride > 0
        else {
            return nil
        }

        let minimumRowBytes = UInt64(width) * format.bytesPerPixel
        let requiredBytes = UInt64(stride).multipliedReportingOverflow(
            by: UInt64(height)
        )
        guard UInt64(stride) >= minimumRowBytes,
              !requiredBytes.overflow,
              requiredBytes.partialValue <= resource.length
        else {
            return nil
        }
        return SimpleFramebufferDescription(
            resource: resource,
            widthInPixels: width,
            heightInPixels: height,
            bytesPerRow: stride,
            format: format
        )
    }

    func resource(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        registerIndex: Int = 0,
        requiringProperty property: StaticString
    ) -> DeviceResource? {
        guard nodeIndex >= 0, registerIndex >= 0 else { return nil }
        var remainingMatches = nodeIndex
        return search(
            compatibleWith: compatibility,
            deviceType: nil,
            reservedMemory: false,
            remainingMatches: &remainingMatches,
            registerIndex: registerIndex,
            matchingPropertyName: property
        )?.resource
    }

    func resource(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        registerIndex: Int = 0,
        cStringProperty property: StaticString,
        equalTo value: StaticString
    ) -> DeviceResource? {
        guard nodeIndex >= 0, registerIndex >= 0 else { return nil }
        var remainingMatches = nodeIndex
        return search(
            compatibleWith: compatibility,
            deviceType: nil,
            reservedMemory: false,
            remainingMatches: &remainingMatches,
            registerIndex: registerIndex,
            matchingPropertyName: property,
            matchingPropertyValue: value
        )?.resource
    }

    func resource(
        deviceType: StaticString,
        nodeIndex: Int = 0,
        registerIndex: Int = 0
    ) -> DeviceResource? {
        guard nodeIndex >= 0, registerIndex >= 0 else { return nil }
        var remainingMatches = nodeIndex
        return search(
            compatibleWith: nil,
            deviceType: deviceType,
            reservedMemory: false,
            remainingMatches: &remainingMatches,
            registerIndex: registerIndex
        )?.resource
    }

    func reservedMemoryResource(
        nodeIndex: Int = 0,
        registerIndex: Int = 0
    ) -> DeviceResource? {
        guard nodeIndex >= 0, registerIndex >= 0 else { return nil }
        var remainingMatches = nodeIndex
        return search(
            compatibleWith: nil,
            deviceType: nil,
            reservedMemory: true,
            remainingMatches: &remainingMatches,
            registerIndex: registerIndex
        )?.resource
    }

    func firmwareReservation(at index: Int) -> DeviceResource? {
        guard index >= 0 else { return nil }
        var cursor = reservationStart
        var remaining = index
        var entries = 0
        while entries < 4096,
              Self.range(offset: cursor, length: 16, fits: totalSize),
              let baseAddress = readBE64(at: cursor),
              let length = readBE64(at: cursor + 8) {
            if baseAddress == 0 && length == 0 { return nil }
            if remaining == 0 {
                return DeviceResource(baseAddress: baseAddress, length: length)
            }
            remaining -= 1
            entries += 1
            cursor += 16
        }
        return nil
    }

    /// Resolves one CPU physical interval into the address consumed by a DMA
    /// master at an enabled compatible node. Translation walks every ancestor
    /// `dma-ranges` level from the CPU root toward the device. Multiple aliases
    /// are retained until `maximumDeviceAddress` is applied; zero or more than
    /// one usable result fails closed.
    func deviceDMAResource(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int = 0,
        cpuPhysicalAddress: UInt64,
        byteCount: UInt64,
        maximumDeviceAddress: UInt64
    ) -> DeviceResource? {
        guard nodeIndex >= 0,
              byteCount > 0,
              !cpuPhysicalAddress.addingReportingOverflow(byteCount - 1)
                  .overflow,
              let nodeOffset = compatibleNodeOffset(
                  compatibility,
                  nodeIndex: nodeIndex
              ),
              let path = dmaTranslationPath(toNode: nodeOffset),
              path.isValid,
              path.hasExplicitRanges
        else {
            return nil
        }

        var candidates = DeviceTreeDMACandidateSet()
        guard candidates.append(
                  DeviceTreeDMAAddress(
                      domain: .scalar,
                      selector: 0,
                      value: cpuPhysicalAddress
                  )
              )
        else { return nil }

        var levelIndex = 0
        while levelIndex < path.levelCount {
            guard let level = path.level(at: levelIndex),
                  let translated = translateDMAFromParent(
                      candidates,
                      byteCount: byteCount,
                      through: level
                  )
            else {
                return nil
            }
            candidates = translated
            levelIndex += 1
        }

        var selectedAddress: UInt64?
        var candidateIndex = 0
        while candidateIndex < candidates.count {
            guard let candidate = candidates.candidate(at: candidateIndex)
            else { return nil }
            let lastAddress = candidate.value.addingReportingOverflow(
                byteCount - 1
            )
            if !lastAddress.overflow,
               lastAddress.partialValue <= maximumDeviceAddress {
                // A PCI selector describes the address space, not bits that a
                // device places on its DMA address pins. Only memory aliases
                // are valid for this resolver.
                guard candidate.domain != .pci
                        || pciAddressClass(candidate.selector) == .memory
                else { return nil }
                guard selectedAddress == nil else { return nil }
                selectedAddress = candidate.value
            }
            candidateIndex += 1
        }
        guard let selectedAddress else { return nil }
        return DeviceResource(
            baseAddress: selectedAddress,
            length: byteCount
        )
    }

    private func compatibleNodeOffset(
        _ compatibility: StaticString,
        nodeIndex: Int
    ) -> UInt? {
        var remainingMatches = nodeIndex
        return search(
            compatibleWith: compatibility,
            deviceType: nil,
            reservedMemory: false,
            remainingMatches: &remainingMatches,
            registerIndex: 0
        )?.nodeOffset
    }

    private func interruptSpecifier(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int,
        interruptIndex: Int
    ) -> DeviceTreeInterruptSpecifier? {
        guard interruptIndex >= 0,
              let layout = interruptPropertyLayout(
                  compatibleWith: compatibility,
                  nodeIndex: nodeIndex
              ), interruptIndex < layout.tupleCount,
              UInt(interruptIndex) <= UInt.max / layout.tupleByteCount
        else {
            return nil
        }
        let selectedOffset = UInt(interruptIndex) * layout.tupleByteCount
        guard selectedOffset
                  <= layout.property.length - layout.tupleByteCount,
              layout.property.offset <= UInt.max - selectedOffset,
              let cells = decodePropertyCells(
                  at: layout.property.offset + selectedOffset,
                  length: layout.tupleByteCount
              )
        else {
            return nil
        }
        return DeviceTreeInterruptSpecifier(
            controllerNodeOffset: layout.controllerNodeOffset,
            cells: cells
        )
    }

    private func interruptPropertyLayout(
        compatibleWith compatibility: StaticString,
        nodeIndex: Int
    ) -> DeviceTreeInterruptPropertyLayout? {
        guard nodeIndex >= 0,
              let targetNodeOffset = compatibleNodeOffset(
                  compatibility,
                  nodeIndex: nodeIndex
              ), directPropertyOccurrenceCount(
                  atNode: targetNodeOffset,
                  property: "interrupts"
              ) == 1,
              directPropertyOccurrenceCount(
                  atNode: targetNodeOffset,
                  property: "interrupts-extended"
              ) == 0,
              let interrupts = propertyLocation(
                  atNode: targetNodeOffset,
                  property: "interrupts"
              ), interrupts.length > 0,
              let parent = interruptParentContext(forNode: targetNodeOffset),
              parent.isValid,
              let controllerNodeOffset = parent.nodeOffset,
              directPropertyOccurrenceCount(
                  atNode: controllerNodeOffset,
                  property: "interrupt-controller"
              ) == 1,
              propertyLocation(
                  atNode: controllerNodeOffset,
                  property: "interrupt-controller"
              )?.length == 0,
              directPropertyOccurrenceCount(
                  atNode: controllerNodeOffset,
                  property: "#interrupt-cells"
              ) == 1,
              let width = propertyCells(
                  atNode: controllerNodeOffset,
                  property: "#interrupt-cells"
              ), width.count == 1,
              let rawCellCount = width.cell(at: 0),
              rawCellCount > 0,
              rawCellCount <= UInt32(DeviceTreePropertyCells.maximumCellCount)
        else {
            return nil
        }

        let cellCount = UInt(rawCellCount)
        guard cellCount <= UInt.max / 4 else { return nil }
        let tupleByteCount = cellCount * 4
        guard tupleByteCount > 0,
              interrupts.length % tupleByteCount == 0,
              interrupts.length / tupleByteCount <= UInt(Int.max)
        else {
            return nil
        }
        return DeviceTreeInterruptPropertyLayout(
            controllerNodeOffset: controllerNodeOffset,
            property: interrupts,
            cellCount: cellCount
        )
    }

    private func interruptParentContext(
        forNode targetNodeOffset: UInt
    ) -> DeviceTreeInterruptParentContext? {
        var cursor = structureStart
        var result: DeviceTreeInterruptParentSearchResult?
        guard scanInterruptParentPath(
                  cursor: &cursor,
                  targetNodeOffset: targetNodeOffset,
                  inheritedParent: .missing,
                  depth: 0,
                  result: &result
              )
        else {
            return nil
        }
        return result?.context
    }

    /// Retains only the interrupt-parent state along the structural path to a
    /// target node. An explicit phandle applies to the node and descendants;
    /// an interrupt-controller node becomes the natural parent of its own
    /// children while keeping its explicit parent for its upstream interrupt.
    private func scanInterruptParentPath(
        cursor: inout UInt,
        targetNodeOffset: UInt,
        inheritedParent: DeviceTreeInterruptParentContext,
        depth: Int,
        result: inout DeviceTreeInterruptParentSearchResult?
    ) -> Bool {
        guard depth < 64 else { return false }
        let nodeOffset = cursor
        guard readStructureWord(at: cursor) == Self.beginNode else {
            return false
        }
        cursor += 4
        guard skipNodeName(cursor: &cursor) else { return false }

        var explicitParentSeen = false
        var explicitParent = DeviceTreeInterruptParentContext.missing
        var interruptControllerSeen = false
        var interruptControllerIsValid = true
        var sawChild = false

        while cursor < structureEnd {
            guard let token = readStructureWord(at: cursor) else {
                return false
            }
            switch token {
            case Self.property:
                // DTSpec places a node's properties before its subnodes. The
                // topology cannot be inherited deterministically otherwise.
                guard !sawChild,
                      let rawLength = readStructureWord(at: cursor + 4),
                      let rawNameOffset = readStructureWord(at: cursor + 8)
                else { return false }
                let valueOffset = cursor + 12
                let valueLength = UInt(rawLength)
                guard Self.range(
                          offset: valueOffset,
                          length: valueLength,
                          fits: structureEnd
                      ), let next = Self.align4(valueOffset + valueLength),
                      next <= structureEnd
                else { return false }
                cursor = next

                if propertyName(
                    at: UInt(rawNameOffset),
                    equals: "interrupt-parent"
                ) {
                    if explicitParentSeen {
                        explicitParent = .invalid
                    } else if rawLength == 4,
                              let phandle = readStructureWord(at: valueOffset),
                              phandle != 0,
                              let parentNodeOffset = uniqueNodeOffset(
                                  forPhandle: phandle
                              ) {
                        explicitParent = DeviceTreeInterruptParentContext(
                            nodeOffset: parentNodeOffset,
                            isValid: true
                        )
                    } else {
                        explicitParent = .invalid
                    }
                    explicitParentSeen = true
                } else if propertyName(
                    at: UInt(rawNameOffset),
                    equals: "interrupt-controller"
                ) {
                    if interruptControllerSeen || rawLength != 0 {
                        interruptControllerIsValid = false
                    }
                    interruptControllerSeen = true
                }

            case Self.beginNode:
                sawChild = true
                let ownParent = explicitParentSeen
                    ? explicitParent : inheritedParent
                if nodeOffset == targetNodeOffset {
                    result = DeviceTreeInterruptParentSearchResult(
                        context: ownParent
                    )
                    return true
                }
                let childParent: DeviceTreeInterruptParentContext
                if interruptControllerSeen {
                    childParent = interruptControllerIsValid
                        ? DeviceTreeInterruptParentContext(
                            nodeOffset: nodeOffset,
                            isValid: true
                        )
                        : .invalid
                } else {
                    childParent = ownParent
                }
                guard scanInterruptParentPath(
                          cursor: &cursor,
                          targetNodeOffset: targetNodeOffset,
                          inheritedParent: childParent,
                          depth: depth + 1,
                          result: &result
                      )
                else { return false }
                if result != nil { return true }

            case Self.endNode:
                cursor += 4
                if nodeOffset == targetNodeOffset {
                    result = DeviceTreeInterruptParentSearchResult(
                        context: explicitParentSeen
                            ? explicitParent : inheritedParent
                    )
                }
                return true

            case Self.noOperation:
                cursor += 4

            default:
                return false
            }
        }
        return false
    }

    private func directPropertyOccurrenceCount(
        atNode nodeOffset: UInt,
        property: StaticString
    ) -> Int? {
        guard readStructureWord(at: nodeOffset) == Self.beginNode else {
            return nil
        }
        var cursor = nodeOffset + 4
        guard skipNodeName(cursor: &cursor) else { return nil }
        var count = 0
        while cursor < structureEnd {
            guard let token = readStructureWord(at: cursor) else { return nil }
            cursor += 4
            switch token {
            case Self.property:
                guard let rawLength = readStructureWord(at: cursor),
                      let rawNameOffset = readStructureWord(at: cursor + 4)
                else { return nil }
                let valueOffset = cursor + 8
                let valueLength = UInt(rawLength)
                guard Self.range(
                          offset: valueOffset,
                          length: valueLength,
                          fits: structureEnd
                      ), let next = Self.align4(valueOffset + valueLength),
                      next <= structureEnd
                else { return nil }
                cursor = next
                if propertyName(
                    at: UInt(rawNameOffset),
                    equals: property
                ) {
                    guard count < Int.max else { return nil }
                    count += 1
                }
            case Self.noOperation:
                continue
            case Self.beginNode, Self.endNode:
                return count
            default:
                return nil
            }
        }
        return nil
    }

    private func node(
        at nodeOffset: UInt,
        isCompatibleWith compatibility: StaticString
    ) -> Bool {
        guard let location = propertyLocation(
                  atNode: nodeOffset,
                  property: "compatible"
              )
        else { return false }
        return containsCString(
            compatibility,
            at: location.offset,
            length: location.length
        )
    }

    private func dmaTranslationPath(
        toNode targetNodeOffset: UInt
    ) -> DeviceTreeDMATranslationPath? {
        var cursor = structureStart
        var result: DeviceTreeDMATranslationPath?
        let path = DeviceTreeDMATranslationPath()
        guard scanDMAPath(
                  cursor: &cursor,
                  targetNodeOffset: targetNodeOffset,
                  inheritedAddressCells: 2,
                  inheritedDomain: .scalar,
                  path: path,
                  isRoot: true,
                  result: &result
              )
        else { return nil }
        return result
    }

    /// Locates one node while retaining only its ancestor DMA path. DTSpec
    /// places a node's properties before its children; a property after a
    /// child is rejected so cell widths can never depend on token order.
    private func scanDMAPath(
        cursor: inout UInt,
        targetNodeOffset: UInt,
        inheritedAddressCells: UInt32,
        inheritedDomain: DeviceTreeAddressDomain,
        path: DeviceTreeDMATranslationPath,
        isRoot: Bool,
        result: inout DeviceTreeDMATranslationPath?
    ) -> Bool {
        let nodeOffset = cursor
        guard readStructureWord(at: cursor) == Self.beginNode else {
            return false
        }
        if nodeOffset == targetNodeOffset {
            result = path
            return true
        }

        cursor += 4
        let nodeNameOffset = cursor
        guard skipNodeName(cursor: &cursor) else { return false }

        var childAddressCells: UInt32 = 2
        var childSizeCells: UInt32 = 1
        var addressCellsSeen = false
        var sizeCellsSeen = false
        var dmaRangesSeen = false
        var dmaRangesOffset: UInt = 0
        var dmaRangesLength: UInt = 0
        var sawChild = false
        var childDomain: DeviceTreeAddressDomain = nodeName(
            at: nodeNameOffset,
            equals: "pcie"
        ) ? .pci : .scalar

        while cursor < structureEnd {
            guard let token = readStructureWord(at: cursor) else {
                return false
            }
            switch token {
            case Self.property:
                guard !sawChild,
                      let rawLength = readStructureWord(at: cursor + 4),
                      let rawNameOffset = readStructureWord(at: cursor + 8)
                else { return false }
                let valueOffset = cursor + 12
                let valueLength = UInt(rawLength)
                guard Self.range(
                          offset: valueOffset,
                          length: valueLength,
                          fits: structureEnd
                      ), let next = Self.align4(valueOffset + valueLength),
                      next <= structureEnd
                else { return false }
                cursor = next

                if propertyName(
                    at: UInt(rawNameOffset),
                    equals: "#address-cells"
                ) {
                    guard !addressCellsSeen,
                          rawLength == 4,
                          let value = readStructureWord(at: valueOffset)
                    else { return false }
                    addressCellsSeen = true
                    childAddressCells = value
                } else if propertyName(
                    at: UInt(rawNameOffset),
                    equals: "#size-cells"
                ) {
                    guard !sizeCellsSeen,
                          rawLength == 4,
                          let value = readStructureWord(at: valueOffset)
                    else { return false }
                    sizeCellsSeen = true
                    childSizeCells = value
                } else if propertyName(
                    at: UInt(rawNameOffset),
                    equals: "dma-ranges"
                ) {
                    guard !dmaRangesSeen else { return false }
                    dmaRangesSeen = true
                    dmaRangesOffset = valueOffset
                    dmaRangesLength = valueLength
                } else if propertyName(
                    at: UInt(rawNameOffset),
                    equals: "device_type"
                ) {
                    if cStringEquals(
                        "pci",
                        at: valueOffset,
                        length: valueLength
                    ) || cStringEquals(
                        "pciex",
                        at: valueOffset,
                        length: valueLength
                    ) {
                        childDomain = .pci
                    }
                }

            case Self.beginNode:
                sawChild = true
                var childPath = path
                if !isRoot {
                    if let level = dmaTranslationLevel(
                        rangesOffset: dmaRangesOffset,
                        rangesLength: dmaRangesLength,
                        hasRangesProperty: dmaRangesSeen,
                        childAddressCells: childAddressCells,
                        parentAddressCells: inheritedAddressCells,
                        sizeCells: childSizeCells,
                        childDomain: childDomain,
                        parentDomain: inheritedDomain
                    ) {
                        _ = childPath.append(level)
                    } else {
                        childPath.invalidate()
                    }
                }
                guard scanDMAPath(
                          cursor: &cursor,
                          targetNodeOffset: targetNodeOffset,
                          inheritedAddressCells: childAddressCells,
                          inheritedDomain: childDomain,
                          path: childPath,
                          isRoot: false,
                          result: &result
                      )
                else { return false }
                if result != nil { return true }

            case Self.endNode:
                cursor += 4
                return true

            case Self.noOperation:
                cursor += 4

            default:
                return false
            }
        }
        return false
    }

    private func dmaTranslationLevel(
        rangesOffset: UInt,
        rangesLength: UInt,
        hasRangesProperty: Bool,
        childAddressCells: UInt32,
        parentAddressCells: UInt32,
        sizeCells: UInt32,
        childDomain: DeviceTreeAddressDomain,
        parentDomain: DeviceTreeAddressDomain
    ) -> DeviceTreeDMATranslationLevel? {
        guard childAddressCells > 0, childAddressCells <= 3,
              parentAddressCells > 0, parentAddressCells <= 3,
              sizeCells <= 2,
              (childDomain != .pci || childAddressCells == 3),
              (parentDomain != .pci || parentAddressCells == 3)
        else { return nil }

        if hasRangesProperty && rangesLength > 0 {
            guard sizeCells > 0 else { return nil }
            let entryCellCount = UInt(childAddressCells)
                + UInt(parentAddressCells) + UInt(sizeCells)
            guard entryCellCount > 0,
                  entryCellCount <= UInt.max / 4
            else { return nil }
            let entryByteCount = entryCellCount * 4
            guard rangesLength >= entryByteCount,
                  rangesLength % entryByteCount == 0,
                  Self.range(
                      offset: rangesOffset,
                      length: rangesLength,
                      fits: structureEnd
                  )
            else { return nil }
        }

        return DeviceTreeDMATranslationLevel(
            rangesOffset: rangesOffset,
            rangesLength: rangesLength,
            hasRangesProperty: hasRangesProperty,
            childAddressCells: childAddressCells,
            parentAddressCells: parentAddressCells,
            sizeCells: sizeCells,
            childDomain: childDomain,
            parentDomain: parentDomain
        )
    }

    private func translateDMAFromParent(
        _ candidates: DeviceTreeDMACandidateSet,
        byteCount: UInt64,
        through level: DeviceTreeDMATranslationLevel
    ) -> DeviceTreeDMACandidateSet? {
        guard candidates.count > 0 else { return nil }
        if !level.hasRangesProperty || level.rangesLength == 0 {
            var identities = DeviceTreeDMACandidateSet()
            var index = 0
            while index < candidates.count {
                guard let candidate = candidates.candidate(at: index),
                      let identity = dmaIdentityAddress(
                          candidate,
                          childDomain: level.childDomain,
                          parentDomain: level.parentDomain
                      ), identities.append(identity)
                else { return nil }
                index += 1
            }
            return identities
        }

        let childBytes = UInt(level.childAddressCells) * 4
        let parentBytes = UInt(level.parentAddressCells) * 4
        let sizeBytes = UInt(level.sizeCells) * 4
        let entryBytes = childBytes + parentBytes + sizeBytes
        guard entryBytes > 0,
              level.rangesLength >= entryBytes,
              level.rangesLength % entryBytes == 0
        else { return nil }

        var translated = DeviceTreeDMACandidateSet()
        var candidateIndex = 0
        while candidateIndex < candidates.count {
            guard let candidate = candidates.candidate(at: candidateIndex),
                  candidate.domain == level.parentDomain
            else { return nil }
            var entryOffset: UInt = 0
            while entryOffset < level.rangesLength {
                guard let childBase = readDMAAddress(
                          at: level.rangesOffset + entryOffset,
                          count: level.childAddressCells,
                          domain: level.childDomain
                      ), let parentBase = readDMAAddress(
                          at: level.rangesOffset + entryOffset + childBytes,
                          count: level.parentAddressCells,
                          domain: level.parentDomain
                      ), let rangeLength = readCells(
                          at: level.rangesOffset + entryOffset + childBytes
                              + parentBytes,
                          count: level.sizeCells
                      )
                else { return nil }

                if dmaSelectorsMatch(candidate, parentBase),
                   candidate.value >= parentBase.value {
                    let offset = candidate.value - parentBase.value
                    if offset <= rangeLength,
                       byteCount <= rangeLength - offset,
                       childBase.value <= UInt64.max - offset {
                        guard translated.append(
                                  DeviceTreeDMAAddress(
                                      domain: level.childDomain,
                                      selector: childBase.selector,
                                      value: childBase.value + offset
                                  )
                              )
                        else { return nil }
                    }
                }
                entryOffset += entryBytes
            }
            candidateIndex += 1
        }
        return translated.count > 0 ? translated : nil
    }

    private func dmaIdentityAddress(
        _ address: DeviceTreeDMAAddress,
        childDomain: DeviceTreeAddressDomain,
        parentDomain: DeviceTreeAddressDomain
    ) -> DeviceTreeDMAAddress? {
        guard address.domain == parentDomain else { return nil }
        switch (childDomain, parentDomain) {
        case (.scalar, .scalar):
            return DeviceTreeDMAAddress(
                domain: .scalar,
                selector: 0,
                value: address.value
            )
        case (.pci, .pci):
            guard pciAddressClass(address.selector) == .memory else {
                return nil
            }
            return address
        case (.scalar, .pci):
            guard pciAddressClass(address.selector) == .memory else {
                return nil
            }
            return DeviceTreeDMAAddress(
                domain: .scalar,
                selector: 0,
                value: address.value
            )
        case (.pci, .scalar):
            // An empty reverse mapping cannot invent PCI space flags. A
            // non-empty tuple is required at such a domain transition.
            return nil
        }
    }

    private func readDMAAddress(
        at offset: UInt,
        count: UInt32,
        domain: DeviceTreeAddressDomain
    ) -> DeviceTreeDMAAddress? {
        switch domain {
        case .pci:
            guard count == 3,
                  let selector = readStructureWord(at: offset),
                  pciAddressClass(selector) == .memory,
                  let value = readCells(at: offset + 4, count: 2)
            else { return nil }
            return DeviceTreeDMAAddress(
                domain: .pci,
                selector: selector,
                value: value
            )
        case .scalar:
            if count == 3 {
                guard readStructureWord(at: offset) == 0,
                      let value = readCells(at: offset + 4, count: 2)
                else { return nil }
                return DeviceTreeDMAAddress(
                    domain: .scalar,
                    selector: 0,
                    value: value
                )
            }
            guard let value = readCells(at: offset, count: count) else {
                return nil
            }
            return DeviceTreeDMAAddress(
                domain: .scalar,
                selector: 0,
                value: value
            )
        }
    }

    private func dmaSelectorsMatch(
        _ address: DeviceTreeDMAAddress,
        _ rangeBase: DeviceTreeDMAAddress
    ) -> Bool {
        guard address.domain == rangeBase.domain else { return false }
        switch address.domain {
        case .scalar:
            return address.selector == 0 && rangeBase.selector == 0
        case .pci:
            // PCI `phys.hi` distinguishes 32/64-bit and prefetchability, but
            // address translation matches the I/O-versus-memory class. This is
            // what lets RP1 publish both its high and low system-RAM aliases.
            return pciAddressClass(address.selector) == .memory
                && pciAddressClass(rangeBase.selector) == .memory
        }
    }

    private func pciAddressClass(
        _ selector: UInt32
    ) -> DeviceTreePCIAddressClass {
        switch (selector >> 24) & 0x3 {
        case 1: return .io
        case 2, 3: return .memory
        default: return .configuration
        }
    }

    private func propertyCells(
        atNode nodeOffset: UInt,
        property: StaticString
    ) -> DeviceTreePropertyCells? {
        guard let location = propertyLocation(
                  atNode: nodeOffset,
                  property: property
              )
        else { return nil }
        return decodePropertyCells(
            at: location.offset,
            length: location.length
        )
    }

    private func propertyBytes(
        atNode nodeOffset: UInt,
        property: StaticString
    ) -> DeviceTreePropertyBytes? {
        guard let location = propertyLocation(
                  atNode: nodeOffset,
                  property: property
              )
        else { return nil }
        return decodePropertyBytes(
            at: location.offset,
            length: location.length
        )
    }

    /// Finds a property on exactly one node without descending into children.
    /// Duplicate properties are malformed under DTSpec and are rejected.
    private func propertyLocation(
        atNode nodeOffset: UInt,
        property: StaticString
    ) -> DeviceTreePropertyLocation? {
        guard readStructureWord(at: nodeOffset) == Self.beginNode else {
            return nil
        }
        var cursor = nodeOffset + 4
        guard skipNodeName(cursor: &cursor) else { return nil }
        var match: DeviceTreePropertyLocation?

        while cursor < structureEnd {
            guard let token = readStructureWord(at: cursor) else { return nil }
            cursor += 4
            switch token {
            case Self.property:
                guard let rawLength = readStructureWord(at: cursor),
                      let rawNameOffset = readStructureWord(at: cursor + 4)
                else { return nil }
                cursor += 8
                let length = UInt(rawLength)
                let valueOffset = cursor
                guard Self.range(
                          offset: valueOffset,
                          length: length,
                          fits: structureEnd
                      ), let next = Self.align4(valueOffset + length),
                      next <= structureEnd
                else { return nil }
                cursor = next
                if propertyName(
                    at: UInt(rawNameOffset),
                    equals: property
                ) {
                    guard match == nil else { return nil }
                    match = DeviceTreePropertyLocation(
                        offset: valueOffset,
                        length: length
                    )
                }
            case Self.noOperation:
                continue
            case Self.beginNode, Self.endNode:
                return match
            default:
                return nil
            }
        }
        return nil
    }

    private func uniqueNodeOffset(forPhandle phandle: UInt32) -> UInt? {
        guard phandle != 0 else { return nil }
        var match: UInt?
        guard collectNodeOffset(
                  forPhandle: phandle,
                  property: "phandle",
                  match: &match
              ), collectNodeOffset(
                  forPhandle: phandle,
                  property: "linux,phandle",
                  match: &match
              ), let match
        else { return nil }

        let standardPresent = propertyLocation(
            atNode: match,
            property: "phandle"
        ) != nil
        let legacyPresent = propertyLocation(
            atNode: match,
            property: "linux,phandle"
        ) != nil
        let standard = propertyCells(atNode: match, property: "phandle")
        let legacy = propertyCells(atNode: match, property: "linux,phandle")
        if standardPresent {
            guard standard?.count == 1,
                  standard?.cell(at: 0) == phandle
            else { return nil }
        }
        if legacyPresent {
            guard legacy?.count == 1,
                  legacy?.cell(at: 0) == phandle
            else { return nil }
        }
        return match
    }

    private func collectNodeOffset(
        forPhandle phandle: UInt32,
        property: StaticString,
        match: inout UInt?
    ) -> Bool {
        var propertyIndex = 0
        while propertyIndex < 4_096 {
            var remainingMatches = propertyIndex
            guard let result = search(
                      compatibleWith: nil,
                      deviceType: nil,
                      reservedMemory: false,
                      remainingMatches: &remainingMatches,
                      registerIndex: 0,
                      matchingPropertyName: property
                  )
            else { return true }
            if result.matchedPropertyCells?.count == 1,
               result.matchedPropertyCells?.cell(at: 0) == phandle {
                if let match, match != result.nodeOffset { return false }
                match = result.nodeOffset
            }
            propertyIndex += 1
        }
        // Refuse a blob whose property-bearing node count exceeds the bound.
        return false
    }

    private func search(
        compatibleWith compatibility: StaticString?,
        deviceType: StaticString?,
        reservedMemory: Bool,
        remainingMatches: inout Int,
        registerIndex: Int,
        matchingPropertyName: StaticString? = nil,
        matchingPropertyValue: StaticString? = nil
    ) -> DeviceTreeSearchResult? {
        var cursor = structureStart
        while cursor < structureEnd {
            guard let token = readStructureWord(at: cursor) else {
                return nil
            }
            if token == Self.noOperation {
                cursor += 4
                continue
            }
            guard token == Self.beginNode else {
                return nil
            }
            return scanNode(
                cursor: &cursor,
                inheritedAddressCells: 2,
                inheritedSizeCells: 1,
                translationPath: .identity,
                insideReservedMemory: false,
                ancestorsAvailable: true,
                compatibility: compatibility,
                deviceType: deviceType,
                reservedMemory: reservedMemory,
                remainingMatches: &remainingMatches,
                registerIndex: registerIndex,
                matchingPropertyName: matchingPropertyName,
                matchingPropertyValue: matchingPropertyValue
            )
        }
        return nil
    }

    private func scanNode(
        cursor: inout UInt,
        inheritedAddressCells: UInt32,
        inheritedSizeCells: UInt32,
        translationPath: AddressTranslationPath,
        insideReservedMemory: Bool,
        ancestorsAvailable: Bool,
        compatibility: StaticString?,
        deviceType: StaticString?,
        reservedMemory: Bool,
        remainingMatches: inout Int,
        registerIndex: Int,
        matchingPropertyName: StaticString?,
        matchingPropertyValue: StaticString?
    ) -> DeviceTreeSearchResult? {
        guard readStructureWord(at: cursor) == Self.beginNode else {
            return nil
        }
        cursor += 4
        let nodeNameOffset = cursor
        let nodeIntroducesReservedMemory = nodeName(
            at: nodeNameOffset,
            equals: "reserved-memory"
        )
        guard skipNodeName(cursor: &cursor) else {
            return nil
        }

        // DTSpec: these values describe children and are not inherited. A
        // direct parent that omits them supplies the architectural defaults.
        var childAddressCells: UInt32 = 2
        var childSizeCells: UInt32 = 1
        var compatibleMatches = compatibility == nil
        var deviceTypeMatches = deviceType == nil
        var propertyMatches = matchingPropertyName == nil
        // DTSpec defines a node as usable only when `status` is absent or an
        // operational value. A globally searched child also cannot be usable
        // through an unavailable parent bus, even when the child omits status.
        var available = ancestorsAvailable
        var resource: DeviceResource?
        var widthInPixels: UInt32?
        var heightInPixels: UInt32?
        var bytesPerRow: UInt32?
        var framebufferFormat: SimpleFramebufferFormat?
        var matchedPropertyCells: DeviceTreePropertyCells?
        var matchedPropertyBytes: DeviceTreePropertyBytes?
        var rangesOffset: UInt?
        var rangesLength: UInt = 0

        while cursor < structureEnd {
            guard let token = readStructureWord(at: cursor) else {
                return nil
            }
            cursor += 4

            switch token {
            case Self.beginNode:
                cursor -= 4
                var childTranslationPath = translationPath
                if let rangesOffset, rangesLength != 0 {
                    if let level = addressTranslationLevel(
                        at: rangesOffset,
                        length: rangesLength,
                        childAddressCells: childAddressCells,
                        parentAddressCells: inheritedAddressCells,
                        sizeCells: childSizeCells
                    ) {
                        _ = childTranslationPath.append(level)
                    } else {
                        childTranslationPath.invalidate()
                    }
                }
                if let found = scanNode(
                    cursor: &cursor,
                    inheritedAddressCells: childAddressCells,
                    inheritedSizeCells: childSizeCells,
                    translationPath: childTranslationPath,
                    insideReservedMemory: insideReservedMemory
                        || nodeIntroducesReservedMemory,
                    ancestorsAvailable: available,
                    compatibility: compatibility,
                    deviceType: deviceType,
                    reservedMemory: reservedMemory,
                    remainingMatches: &remainingMatches,
                    registerIndex: registerIndex,
                    matchingPropertyName: matchingPropertyName,
                    matchingPropertyValue: matchingPropertyValue
                ) {
                    return found
                }

            case Self.property:
                guard let propertyLength = readStructureWord(at: cursor),
                      let nameOffset = readStructureWord(at: cursor + 4)
                else {
                    return nil
                }
                cursor += 8
                let valueLength = UInt(propertyLength)
                let valueOffset = cursor
                guard Self.range(
                    offset: valueOffset,
                    length: valueLength,
                    fits: structureEnd
                ) else {
                    return nil
                }
                guard let nextCursor = Self.align4(valueOffset + valueLength),
                      nextCursor <= structureEnd
                else {
                    return nil
                }
                cursor = nextCursor

                if propertyName(at: UInt(nameOffset), equals: "#address-cells") {
                    guard propertyLength == 4,
                          let value = readStructureWord(at: valueOffset)
                    else {
                        return nil
                    }
                    childAddressCells = value
                } else if propertyName(at: UInt(nameOffset), equals: "#size-cells") {
                    guard propertyLength == 4,
                          let value = readStructureWord(at: valueOffset)
                    else {
                        return nil
                    }
                    childSizeCells = value
                } else if propertyName(at: UInt(nameOffset), equals: "compatible") {
                    if let compatibility {
                        compatibleMatches = containsCString(
                            compatibility,
                            at: valueOffset,
                            length: valueLength
                        )
                    }
                } else if propertyName(at: UInt(nameOffset), equals: "device_type") {
                    if let deviceType {
                        deviceTypeMatches = cStringEquals(
                            deviceType,
                            at: valueOffset,
                            length: valueLength
                        )
                    }
                } else if propertyName(at: UInt(nameOffset), equals: "status") {
                    available = ancestorsAvailable
                        && (cStringEquals(
                            "okay",
                            at: valueOffset,
                            length: valueLength
                        ) || cStringEquals(
                            "ok",
                            at: valueOffset,
                            length: valueLength
                        ))
                } else if propertyName(at: UInt(nameOffset), equals: "reg") {
                    resource = decodeResource(
                        at: valueOffset,
                        length: valueLength,
                        addressCells: inheritedAddressCells,
                        sizeCells: inheritedSizeCells,
                        registerIndex: registerIndex,
                        translationPath: translationPath
                    )
                } else if propertyName(at: UInt(nameOffset), equals: "ranges") {
                    // Property order is not semantic in DT. Decode only when a
                    // child begins, after this node's cell widths are known.
                    rangesOffset = valueOffset
                    rangesLength = valueLength
                } else if propertyName(
                    at: UInt(nameOffset),
                    equals: "width"
                ), propertyLength == 4 {
                    widthInPixels = readStructureWord(at: valueOffset)
                } else if propertyName(
                    at: UInt(nameOffset),
                    equals: "height"
                ), propertyLength == 4 {
                    heightInPixels = readStructureWord(at: valueOffset)
                } else if propertyName(
                    at: UInt(nameOffset),
                    equals: "stride"
                ), propertyLength == 4 {
                    bytesPerRow = readStructureWord(at: valueOffset)
                } else if propertyName(
                    at: UInt(nameOffset),
                    equals: "format"
                ) {
                    if cStringEquals(
                        "r5g6b5",
                        at: valueOffset,
                        length: valueLength
                    ) {
                        framebufferFormat = .r5g6b5
                    } else if cStringEquals(
                        "a8r8g8b8",
                        at: valueOffset,
                        length: valueLength
                    ) {
                        framebufferFormat = .a8r8g8b8
                    } else if cStringEquals(
                        "x8r8g8b8",
                        at: valueOffset,
                        length: valueLength
                    ) {
                        framebufferFormat = .x8r8g8b8
                    }
                }
                if let matchingPropertyName,
                   propertyName(
                       at: UInt(nameOffset),
                       equals: matchingPropertyName
                   ) {
                    if let matchingPropertyValue {
                        propertyMatches = cStringEquals(
                            matchingPropertyValue,
                            at: valueOffset,
                            length: valueLength
                        )
                    } else {
                        propertyMatches = true
                    }
                    matchedPropertyCells = decodePropertyCells(
                        at: valueOffset,
                        length: valueLength
                    )
                    matchedPropertyBytes = decodePropertyBytes(
                        at: valueOffset,
                        length: valueLength
                    )
                }

            case Self.endNode:
                let reservedMemoryMatches = !reservedMemory
                    || (insideReservedMemory && resource != nil)
                if compatibleMatches && deviceTypeMatches && propertyMatches
                    && available
                    && reservedMemoryMatches {
                    if remainingMatches == 0 {
                        return DeviceTreeSearchResult(
                            nodeOffset: nodeNameOffset - 4,
                            resource: resource,
                            widthInPixels: widthInPixels,
                            heightInPixels: heightInPixels,
                            bytesPerRow: bytesPerRow,
                            framebufferFormat: framebufferFormat,
                            matchedPropertyCells: matchedPropertyCells,
                            matchedPropertyBytes: matchedPropertyBytes
                        )
                    }
                    remainingMatches -= 1
                }
                return nil

            case Self.noOperation:
                continue

            case Self.end:
                return nil

            default:
                return nil
            }
        }
        return nil
    }

    private func decodePropertyCells(
        at offset: UInt,
        length: UInt
    ) -> DeviceTreePropertyCells? {
        guard length > 0,
              length & 0x3 == 0,
              length / 4 <= UInt(DeviceTreePropertyCells.maximumCellCount)
        else {
            return nil
        }
        var result = DeviceTreePropertyCells()
        var cellOffset: UInt = 0
        while cellOffset < length {
            guard let value = readStructureWord(at: offset + cellOffset),
                  result.append(value)
            else {
                return nil
            }
            cellOffset += 4
        }
        return result
    }

    private func decodePropertyBytes(
        at offset: UInt,
        length: UInt
    ) -> DeviceTreePropertyBytes? {
        guard length <= UInt(DeviceTreePropertyBytes.maximumByteCount),
              Self.range(offset: offset, length: length, fits: structureEnd)
        else { return nil }
        var result = DeviceTreePropertyBytes()
        var byteOffset: UInt = 0
        while byteOffset < length {
            guard let value = readByte(at: offset + byteOffset),
                  result.append(value)
            else { return nil }
            byteOffset += 1
        }
        return result
    }

    private func decodeResource(
        at offset: UInt,
        length: UInt,
        addressCells: UInt32,
        sizeCells: UInt32,
        registerIndex: Int,
        translationPath: AddressTranslationPath
    ) -> DeviceResource? {
        guard addressCells <= 3,
              sizeCells <= 2
        else {
            return nil
        }
        let addressByteCount = UInt(addressCells) * 4
        let sizeByteCount = UInt(sizeCells) * 4
        let entryByteCount = addressByteCount + sizeByteCount
        guard entryByteCount > 0,
              registerIndex <= Int.max / Int(entryByteCount),
              let entryOffset = UInt(exactly: registerIndex * Int(entryByteCount)),
              entryOffset <= length,
              entryByteCount <= length - entryOffset,
              let busAddress = readBusAddress(
                  at: offset + entryOffset,
                  count: addressCells
              ),
              let resourceLength = readCells(
                  at: offset + entryOffset + addressByteCount,
                  count: sizeCells
              ),
              let translatedAddress = translateToRoot(
                  busAddress,
                  resourceLength: resourceLength,
                  through: translationPath
              )
        else {
            return nil
        }
        return DeviceResource(
            baseAddress: translatedAddress,
            length: resourceLength
        )
    }

    private func addressTranslationLevel(
        at offset: UInt,
        length: UInt,
        childAddressCells: UInt32,
        parentAddressCells: UInt32,
        sizeCells: UInt32
    ) -> AddressTranslationLevel? {
        guard length != 0,
              childAddressCells <= 3,
              parentAddressCells <= 3,
              sizeCells <= 2
        else {
            return nil
        }
        let childBytes = UInt(childAddressCells) * 4
        let parentBytes = UInt(parentAddressCells) * 4
        let sizeBytes = UInt(sizeCells) * 4
        let entryBytes = childBytes + parentBytes + sizeBytes
        guard entryBytes > 0,
              length >= entryBytes,
              length % entryBytes == 0,
              Self.range(offset: offset, length: length, fits: structureEnd)
        else {
            return nil
        }
        return AddressTranslationLevel(
            offset: offset,
            length: length,
            childAddressCells: childAddressCells,
            parentAddressCells: parentAddressCells,
            sizeCells: sizeCells
        )
    }

    private func translateToRoot(
        _ address: DeviceTreeBusAddress,
        resourceLength: UInt64,
        through path: AddressTranslationPath
    ) -> UInt64? {
        guard path.isValid else { return nil }
        var translated = address
        var index = path.levelCount
        while index > 0 {
            index -= 1
            guard let level = path.level(at: index),
                  let parentAddress = translate(
                      translated,
                      resourceLength: resourceLength,
                      through: level
                  )
            else {
                return nil
            }
            translated = parentAddress
        }
        // SwiftOS identity maps a UInt64 CPU physical address. A remaining
        // selector means the root address cannot be represented by that model.
        guard translated.selector == 0 else { return nil }
        return translated.value
    }

    private func translate(
        _ address: DeviceTreeBusAddress,
        resourceLength: UInt64,
        through level: AddressTranslationLevel
    ) -> DeviceTreeBusAddress? {
        let childBytes = UInt(level.childAddressCells) * 4
        let parentBytes = UInt(level.parentAddressCells) * 4
        let sizeBytes = UInt(level.sizeCells) * 4
        let entryBytes = childBytes + parentBytes + sizeBytes
        guard entryBytes > 0,
              level.length >= entryBytes,
              level.length % entryBytes == 0
        else {
            return nil
        }

        var matchedAddress: DeviceTreeBusAddress?
        var entryOffset: UInt = 0
        while entryOffset < level.length {
            guard let childBase = readBusAddress(
                      at: level.offset + entryOffset,
                      count: level.childAddressCells
                  ),
                  let parentBase = readBusAddress(
                      at: level.offset + entryOffset + childBytes,
                      count: level.parentAddressCells
                  ),
                  let translationLength = readCells(
                      at: level.offset + entryOffset + childBytes
                          + parentBytes,
                      count: level.sizeCells
                  )
            else {
                return nil
            }

            if address.selector == childBase.selector,
               address.value >= childBase.value {
                let offset = address.value - childBase.value
                if offset <= translationLength,
                   resourceLength <= translationLength - offset,
                   parentBase.value <= UInt64.max - offset {
                    // Ambiguous ranges are malformed for one resource. Failing
                    // closed prevents tuple order from selecting hardware.
                    guard matchedAddress == nil else { return nil }
                    matchedAddress = DeviceTreeBusAddress(
                        selector: parentBase.selector,
                        value: parentBase.value + offset
                    )
                }
            }
            entryOffset += entryBytes
        }
        return matchedAddress
    }

    private func readBusAddress(
        at offset: UInt,
        count: UInt32
    ) -> DeviceTreeBusAddress? {
        switch count {
        case 0:
            return DeviceTreeBusAddress(selector: 0, value: 0)
        case 1, 2:
            guard let value = readCells(at: offset, count: count) else {
                return nil
            }
            return DeviceTreeBusAddress(selector: 0, value: value)
        case 3:
            guard let selector = readStructureWord(at: offset),
                  let value = readCells(at: offset + 4, count: 2)
            else {
                return nil
            }
            return DeviceTreeBusAddress(selector: selector, value: value)
        default:
            return nil
        }
    }

    private func readCells(at offset: UInt, count: UInt32) -> UInt64? {
        guard count <= 2 else { return nil }
        var value: UInt64 = 0
        var cell: UInt32 = 0
        while cell < count {
            guard let next = readStructureWord(at: offset + UInt(cell) * 4) else {
                return nil
            }
            value = (value << 32) | UInt64(next)
            cell += 1
        }
        return value
    }

    private func skipNodeName(cursor: inout UInt) -> Bool {
        while cursor < structureEnd {
            guard let byte = readByte(at: cursor) else {
                return false
            }
            cursor += 1
            if byte == 0 {
                guard let aligned = Self.align4(cursor), aligned <= structureEnd else {
                    return false
                }
                cursor = aligned
                return true
            }
        }
        return false
    }

    private func nodeName(at offset: UInt, equals expected: StaticString) -> Bool {
        expected.withUTF8Buffer { expectedBytes in
            var index = 0
            while index < expectedBytes.count {
                guard readByte(at: offset + UInt(index)) == expectedBytes[index] else {
                    return false
                }
                index += 1
            }
            let terminator = readByte(at: offset + UInt(expectedBytes.count))
            return terminator == 0 || terminator == UInt8(ascii: "@")
        }
    }

    private func propertyName(at offset: UInt, equals expected: StaticString) -> Bool {
        guard offset < stringsEnd - stringsStart else {
            return false
        }
        var cursor = stringsStart + offset
        return expected.withUTF8Buffer { expectedBytes in
            var index = 0
            while cursor < stringsEnd {
                guard let byte = readByte(at: cursor) else {
                    return false
                }
                cursor += 1
                if byte == 0 {
                    return index == expectedBytes.count
                }
                guard index < expectedBytes.count, byte == expectedBytes[index] else {
                    return false
                }
                index += 1
            }
            return false
        }
    }

    private func containsCString(
        _ expected: StaticString,
        at offset: UInt,
        length: UInt
    ) -> Bool {
        guard Self.range(offset: offset, length: length, fits: structureEnd) else {
            return false
        }
        return expected.withUTF8Buffer { expectedBytes in
            var itemStart: UInt = 0
            var index: UInt = 0
            while index < length {
                guard let byte = readByte(at: offset + index) else {
                    return false
                }
                if byte == 0 {
                    let itemLength = index - itemStart
                    if itemLength == UInt(expectedBytes.count) {
                        var itemIndex: UInt = 0
                        var equal = true
                        while itemIndex < itemLength {
                            guard let itemByte = readByte(at: offset + itemStart + itemIndex),
                                  itemByte == expectedBytes[Int(itemIndex)]
                            else {
                                equal = false
                                break
                            }
                            itemIndex += 1
                        }
                        if equal {
                            return true
                        }
                    }
                    itemStart = index + 1
                }
                index += 1
            }
            return false
        }
    }

    private func cStringEquals(
        _ expected: StaticString,
        at offset: UInt,
        length: UInt
    ) -> Bool {
        expected.withUTF8Buffer { expectedBytes in
            guard length == UInt(expectedBytes.count + 1) else { return false }
            var index = 0
            while index < expectedBytes.count {
                guard readByte(at: offset + UInt(index)) == expectedBytes[index] else {
                    return false
                }
                index += 1
            }
            return readByte(at: offset + UInt(expectedBytes.count)) == 0
        }
    }

    private func readStructureWord(at offset: UInt) -> UInt32? {
        guard offset >= structureStart,
              Self.range(offset: offset, length: 4, fits: structureEnd)
        else {
            return nil
        }
        return Self.readBE32(base: address, offset: offset)
    }

    private func readByte(at offset: UInt) -> UInt8? {
        guard offset < totalSize,
              let pointer = UnsafeRawPointer(bitPattern: address + offset)
        else {
            return nil
        }
        return pointer.load(as: UInt8.self)
    }

    private func readBE64(at offset: UInt) -> UInt64? {
        guard Self.range(offset: offset, length: 8, fits: totalSize),
              let high = Self.readBE32(base: address, offset: offset),
              let low = Self.readBE32(base: address, offset: offset + 4)
        else {
            return nil
        }
        return UInt64(high) << 32 | UInt64(low)
    }

    private static func readBE32(base: UInt, offset: UInt) -> UInt32? {
        guard base <= UInt.max - offset,
              let pointer = UnsafeRawPointer(bitPattern: base + offset)
        else {
            return nil
        }
        let byte0 = UInt32(pointer.load(as: UInt8.self))
        let byte1 = UInt32(pointer.advanced(by: 1).load(as: UInt8.self))
        let byte2 = UInt32(pointer.advanced(by: 2).load(as: UInt8.self))
        let byte3 = UInt32(pointer.advanced(by: 3).load(as: UInt8.self))
        return byte0 << 24 | byte1 << 16 | byte2 << 8 | byte3
    }

    private static func range(offset: UInt, length: UInt, fits limit: UInt) -> Bool {
        offset <= limit && length <= limit - offset
    }

    private static func align4(_ value: UInt) -> UInt? {
        guard value <= UInt.max - 3 else {
            return nil
        }
        return (value + 3) & ~UInt(3)
    }
}
