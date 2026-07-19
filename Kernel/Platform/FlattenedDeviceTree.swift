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
        var enabled = true
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
                    enabled = !cStringEquals(
                        "disabled",
                        at: valueOffset,
                        length: valueLength
                    )
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
                    && enabled
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
