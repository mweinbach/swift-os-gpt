@main
struct FlattenedDeviceTreeTests {
    static func main() {
        findsNestedResourcesAndCompatibleListEntries()
        rejectsBadMagicAndTruncatedStructure()
        print("FDT host tests: 2 passed")
    }

    private static func findsNestedResourcesAndCompatibleListEntries() {
        let bytes = makeDeviceTree()
        bytes.withUnsafeBytes { storage in
            guard let rawAddress = storage.baseAddress,
                  let tree = FlattenedDeviceTree(
                      address: UInt64(UInt(bitPattern: rawAddress))
                  )
            else {
                fatalError("valid fixture was rejected")
            }

            expect(
                tree.resource(compatibleWith: "qemu,fw-cfg-mmio")
                    == DeviceResource(baseAddress: 0x0902_0000, length: 0x18),
                "fw_cfg resource mismatch"
            )
            expect(
                tree.resource(compatibleWith: "arm,pl011")
                    == DeviceResource(baseAddress: 0x0900_0000, length: 0x1000),
                "PL011 resource mismatch"
            )
            expect(
                tree.resource(compatibleWith: "swiftos,missing") == nil,
                "missing resource unexpectedly matched"
            )
        }
    }

    private static func rejectsBadMagicAndTruncatedStructure() {
        var badMagic = makeDeviceTree()
        badMagic[0] = 0
        badMagic.withUnsafeBytes { storage in
            let tree = FlattenedDeviceTree(
                address: UInt64(UInt(bitPattern: storage.baseAddress!))
            )
            expect(tree == nil, "bad FDT magic was accepted")
        }

        var badStructure = makeDeviceTree()
        overwriteBE32(&badStructure, at: 36, with: UInt32.max)
        badStructure.withUnsafeBytes { storage in
            let tree = FlattenedDeviceTree(
                address: UInt64(UInt(bitPattern: storage.baseAddress!))
            )
            expect(tree == nil, "truncated FDT structure was accepted")
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

private func makeDeviceTree() -> [UInt8] {
    let names = ["#address-cells", "#size-cells", "compatible", "reg"]
    var strings: [UInt8] = []
    var offsets: [String: UInt32] = [:]
    for name in names {
        offsets[name] = UInt32(strings.count)
        strings.append(contentsOf: name.utf8)
        strings.append(0)
    }

    var structure: [UInt8] = []
    appendBeginNode("", to: &structure)
    appendProperty(nameOffset: offsets["#address-cells"]!, value: be32(2), to: &structure)
    appendProperty(nameOffset: offsets["#size-cells"]!, value: be32(2), to: &structure)

    appendBeginNode("fw-cfg@9020000", to: &structure)
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x0902_0000) + be32(0) + be32(0x18),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("qemu,fw-cfg-mmio".utf8) + [0],
        to: &structure
    )
    appendBE32(2, to: &structure)

    appendBeginNode("soc", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("simple-bus".utf8) + [0],
        to: &structure
    )
    appendProperty(nameOffset: offsets["#address-cells"]!, value: be32(2), to: &structure)
    appendProperty(nameOffset: offsets["#size-cells"]!, value: be32(2), to: &structure)
    appendBeginNode("pl011@9000000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("arm,pl011".utf8) + [0] + Array("arm,primecell".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x0900_0000) + be32(0) + be32(0x1000),
        to: &structure
    )
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)
    appendBE32(9, to: &structure)

    let headerSize = 40
    let reservationSize = 16
    let structureOffset = headerSize + reservationSize
    let stringsOffset = structureOffset + structure.count
    let totalSize = stringsOffset + strings.count

    var header: [UInt8] = []
    appendBE32(0xd00d_feed, to: &header)
    appendBE32(UInt32(totalSize), to: &header)
    appendBE32(UInt32(structureOffset), to: &header)
    appendBE32(UInt32(stringsOffset), to: &header)
    appendBE32(UInt32(headerSize), to: &header)
    appendBE32(17, to: &header)
    appendBE32(16, to: &header)
    appendBE32(0, to: &header)
    appendBE32(UInt32(strings.count), to: &header)
    appendBE32(UInt32(structure.count), to: &header)

    return header + Array(repeating: 0, count: reservationSize) + structure + strings
}

private func appendBeginNode(_ name: String, to bytes: inout [UInt8]) {
    appendBE32(1, to: &bytes)
    bytes.append(contentsOf: name.utf8)
    bytes.append(0)
    padToFour(&bytes)
}

private func appendProperty(nameOffset: UInt32, value: [UInt8], to bytes: inout [UInt8]) {
    appendBE32(3, to: &bytes)
    appendBE32(UInt32(value.count), to: &bytes)
    appendBE32(nameOffset, to: &bytes)
    bytes.append(contentsOf: value)
    padToFour(&bytes)
}

private func padToFour(_ bytes: inout [UInt8]) {
    while bytes.count % 4 != 0 {
        bytes.append(0)
    }
}

private func be32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
    ]
}

private func appendBE32(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(contentsOf: be32(value))
}

private func overwriteBE32(_ bytes: inout [UInt8], at offset: Int, with value: UInt32) {
    bytes.replaceSubrange(offset..<(offset + 4), with: be32(value))
}
