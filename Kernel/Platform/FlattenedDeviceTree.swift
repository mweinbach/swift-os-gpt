struct DeviceResource: Equatable {
    let baseAddress: UInt64
    let length: UInt64
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

    func resource(compatibleWith compatibility: StaticString) -> DeviceResource? {
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
                compatibility: compatibility
            )
        }
        return nil
    }

    private func scanNode(
        cursor: inout UInt,
        inheritedAddressCells: UInt32,
        inheritedSizeCells: UInt32,
        compatibility: StaticString
    ) -> DeviceResource? {
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
        var matches = false
        var resource: DeviceResource?

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
                    compatibility: compatibility
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
                    matches = containsCString(
                        compatibility,
                        at: valueOffset,
                        length: valueLength
                    )
                } else if propertyName(at: UInt(nameOffset), equals: "reg") {
                    resource = decodeResource(
                        at: valueOffset,
                        length: valueLength,
                        addressCells: inheritedAddressCells,
                        sizeCells: inheritedSizeCells
                    )
                }

            case Self.endNode:
                return matches ? resource : nil

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
        sizeCells: UInt32
    ) -> DeviceResource? {
        guard addressCells <= 2,
              sizeCells <= 2
        else {
            return nil
        }
        let addressByteCount = UInt(addressCells) * 4
        let sizeByteCount = UInt(sizeCells) * 4
        guard length >= addressByteCount + sizeByteCount,
              let baseAddress = readCells(at: offset, count: addressCells),
              let resourceLength = readCells(
                  at: offset + addressByteCount,
                  count: sizeCells
              )
        else {
            return nil
        }
        return DeviceResource(baseAddress: baseAddress, length: resourceLength)
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
