struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
}

private struct DeviceTreeSearchResult {
    let resource: DeviceResource?
}

private struct AddressTranslation {
    let childBase: UInt64
    let rootBase: UInt64
    let length: UInt64
    let active: Bool

    static let identity = AddressTranslation(
        childBase: 0,
        rootBase: 0,
        length: UInt64.max,
        active: false
    )

    func translate(address: UInt64, length resourceLength: UInt64) -> UInt64? {
        guard active else { return address }
        guard address >= childBase else { return nil }
        let offset = address - childBase
        guard offset <= length,
              resourceLength <= length - offset,
              rootBase <= UInt64.max - offset
        else {
            return nil
        }
        return rootBase + offset
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
              let rawVersion = Self.readBE32(base: base, offset: 20),
              let rawStringsSize = Self.readBE32(base: base, offset: 32),
              let rawStructureSize = Self.readBE32(base: base, offset: 36)
        else {
            return nil
        }

        let size = UInt(rawTotalSize)
        let structureOffset = UInt(rawStructureStart)
        let stringsOffset = UInt(rawStringsStart)
        let structureSize = UInt(rawStructureSize)
        let stringsSize = UInt(rawStringsSize)

        guard rawVersion >= 16,
              size >= Self.headerSize,
              size <= Self.maximumSize,
              structureOffset & 0x3 == 0,
              Self.range(offset: structureOffset, length: structureSize, fits: size),
              Self.range(offset: stringsOffset, length: stringsSize, fits: size)
        else {
            return nil
        }

        address = base
        totalSize = size
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
            remainingMatches: &remainingMatches,
            registerIndex: 0
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
            remainingMatches: &remainingMatches,
            registerIndex: registerIndex
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
            remainingMatches: &remainingMatches,
            registerIndex: registerIndex
        )?.resource
    }

    private func search(
        compatibleWith compatibility: StaticString?,
        deviceType: StaticString?,
        remainingMatches: inout Int,
        registerIndex: Int
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
                parentTranslation: .identity,
                compatibility: compatibility,
                deviceType: deviceType,
                remainingMatches: &remainingMatches,
                registerIndex: registerIndex
            )
        }
        return nil
    }

    private func scanNode(
        cursor: inout UInt,
        inheritedAddressCells: UInt32,
        inheritedSizeCells: UInt32,
        parentTranslation: AddressTranslation,
        compatibility: StaticString?,
        deviceType: StaticString?,
        remainingMatches: inout Int,
        registerIndex: Int
    ) -> DeviceTreeSearchResult? {
        guard readStructureWord(at: cursor) == Self.beginNode else {
            return nil
        }
        cursor += 4
        guard skipNodeName(cursor: &cursor) else {
            return nil
        }

        // DTSpec: these values describe children and are not inherited. A
        // direct parent that omits them supplies the architectural defaults.
        var childAddressCells: UInt32 = 2
        var childSizeCells: UInt32 = 1
        var compatibleMatches = compatibility == nil
        var deviceTypeMatches = deviceType == nil
        var enabled = true
        var resource: DeviceResource?
        var childTranslation = parentTranslation

        while cursor < structureEnd {
            guard let token = readStructureWord(at: cursor) else {
                return nil
            }
            cursor += 4

            switch token {
            case Self.beginNode:
                cursor -= 4
                if let found = scanNode(
                    cursor: &cursor,
                    inheritedAddressCells: childAddressCells,
                    inheritedSizeCells: childSizeCells,
                    parentTranslation: childTranslation,
                    compatibility: compatibility,
                    deviceType: deviceType,
                    remainingMatches: &remainingMatches,
                    registerIndex: registerIndex
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
                        translation: parentTranslation
                    )
                } else if propertyName(at: UInt(nameOffset), equals: "ranges") {
                    childTranslation = decodeTranslation(
                        at: valueOffset,
                        length: valueLength,
                        childAddressCells: childAddressCells,
                        parentAddressCells: inheritedAddressCells,
                        sizeCells: childSizeCells,
                        parentTranslation: parentTranslation
                    ) ?? parentTranslation
                }

            case Self.endNode:
                if compatibleMatches && deviceTypeMatches && enabled {
                    if remainingMatches == 0 {
                        return DeviceTreeSearchResult(resource: resource)
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

    private func decodeResource(
        at offset: UInt,
        length: UInt,
        addressCells: UInt32,
        sizeCells: UInt32,
        registerIndex: Int,
        translation: AddressTranslation
    ) -> DeviceResource? {
        guard addressCells <= 2,
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
              let baseAddress = readCells(
                  at: offset + entryOffset,
                  count: addressCells
              ),
              let resourceLength = readCells(
                  at: offset + entryOffset + addressByteCount,
                  count: sizeCells
              ),
              let translatedAddress = translation.translate(
                  address: baseAddress,
                  length: resourceLength
              )
        else {
            return nil
        }
        return DeviceResource(
            baseAddress: translatedAddress,
            length: resourceLength
        )
    }

    private func decodeTranslation(
        at offset: UInt,
        length: UInt,
        childAddressCells: UInt32,
        parentAddressCells: UInt32,
        sizeCells: UInt32,
        parentTranslation: AddressTranslation
    ) -> AddressTranslation? {
        if length == 0 { return parentTranslation }
        guard childAddressCells <= 2,
              parentAddressCells <= 2,
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
              let childBase = readCells(at: offset, count: childAddressCells),
              let parentBase = readCells(
                  at: offset + childBytes,
                  count: parentAddressCells
              ),
              let translationLength = readCells(
                  at: offset + childBytes + parentBytes,
                  count: sizeCells
              ),
              let rootBase = parentTranslation.translate(
                  address: parentBase,
                  length: translationLength
              )
        else {
            return nil
        }
        return AddressTranslation(
            childBase: childBase,
            rootBase: rootBase,
            length: translationLength,
            active: true
        )
    }

    private func readCells(at offset: UInt, count: UInt32) -> UInt64? {
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
