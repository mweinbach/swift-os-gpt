@main
struct FlattenedDeviceTreeTests {
    static func main() {
        findsNestedResourcesAndCompatibleListEntries()
        readsPlatformMemoryCPUAndRegisterIndexes()
        readsFirmwareSimpleFramebufferProperties()
        rejectsBadMagicAndTruncatedStructure()
        print("FDT host tests: 4 passed")
    }

    private static func readsFirmwareSimpleFramebufferProperties() {
        let bytes = makeDeviceTree()
        bytes.withUnsafeBytes { storage in
            guard let tree = FlattenedDeviceTree(
                      address: UInt64(UInt(bitPattern: storage.baseAddress!))
                  )
            else {
                fatalError("simple framebuffer fixture was rejected")
            }
            let expected = SimpleFramebufferDescription(
                resource: DeviceResource(
                    baseAddress: 0x5e00_0000,
                    length: 0x007e_9000
                ),
                widthInPixels: 1_920,
                heightInPixels: 1_080,
                bytesPerRow: 7_680,
                format: .x8r8g8b8
            )
            expect(
                tree.simpleFramebuffer() == expected,
                "simple-framebuffer properties mismatch"
            )
            let platform = Platform.discover(
                deviceTreeAddress: UInt64(
                    UInt(bitPattern: storage.baseAddress!)
                )
            )
            expect(
                platform?.simpleFramebuffer == expected,
                "platform lost simple-framebuffer handoff"
            )
        }
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
                    == DeviceResource(baseAddress: 0x10_0900_0000, length: 0x1000),
                "PL011 resource mismatch"
            )
            expect(
                tree.resource(compatibleWith: "swiftos,missing") == nil,
                "missing resource unexpectedly matched"
            )
        }
    }

    private static func readsPlatformMemoryCPUAndRegisterIndexes() {
        let bytes = makeDeviceTree()
        bytes.withUnsafeBytes { storage in
            let tree = FlattenedDeviceTree(
                address: UInt64(UInt(bitPattern: storage.baseAddress!))
            )!
            expect(
                tree.contains(compatibleWith: "qemu,virt"),
                "root compatibility was not found"
            )
            expect(
                tree.resource(deviceType: "memory")
                    == DeviceResource(baseAddress: 0x4000_0000, length: 0x2000_0000),
                "memory resource mismatch"
            )
            expect(
                tree.resource(deviceType: "memory", registerIndex: 1)
                    == DeviceResource(baseAddress: 0x1_0000_0000, length: 0x4000_0000),
                "second memory tuple mismatch"
            )
            expect(
                tree.reservedMemoryResource()
                    == DeviceResource(baseAddress: 0x5f00_0000, length: 0x10_0000),
                "reserved-memory resource mismatch"
            )
            expect(
                tree.firmwareReservation(at: 0)
                    == DeviceResource(baseAddress: 0x4100_0000, length: 0x1_0000),
                "firmware reservation mismatch"
            )
            expect(tree.firmwareReservation(at: 1) == nil,
                   "reservation terminator was ignored")
            expect(
                tree.resource(deviceType: "cpu")
                    == DeviceResource(baseAddress: 0x100, length: 0),
                "CPU affinity resource mismatch"
            )
            expect(
                tree.resource(
                    compatibleWith: "arm,gic-v3",
                    registerIndex: 1
                ) == DeviceResource(baseAddress: 0x080a_0000, length: 0x20_0000),
                "second GIC register mismatch"
            )
            let platform = Platform.discover(
                deviceTreeAddress: UInt64(UInt(bitPattern: storage.baseAddress!))
            )
            expect(platform?.kind == .qemuVirt, "QEMU platform mismatch")
            expect(platform?.processorCount == 1, "processor count mismatch")
            expect(platform?.processorAffinity(at: 0) == 0x100, "CPU affinity mismatch")
            expect(
                platform?.memoryRegion(at: 1)
                    == DeviceResource(baseAddress: 0x1_0000_0000, length: 0x4000_0000),
                "platform did not flatten memory tuples"
            )
            expect(
                platform?.reservedMemoryRegion(at: 0)
                    == DeviceResource(baseAddress: 0x5f00_0000, length: 0x10_0000),
                "platform reserved-memory mismatch"
            )
            expect(
                platform?.interruptController == .gicV3(
                    distributor: DeviceResource(
                        baseAddress: 0x0800_0000,
                        length: 0x1_0000
                    ),
                    redistributor: DeviceResource(
                        baseAddress: 0x080a_0000,
                        length: 0x20_0000
                    )
                ),
                "platform GIC mismatch"
            )
            expect(
                platform?.virtioTransport(at: 0)
                    == DeviceResource(baseAddress: 0x0a00_0000, length: 0x200),
                "first VirtIO transport mismatch"
            )
            expect(
                platform?.virtioTransport(at: 1)
                    == DeviceResource(baseAddress: 0x0a00_3e00, length: 0x200),
                "second VirtIO transport mismatch"
            )
            expect(
                platform?.virtioTransportWindow
                    == DeviceResource(baseAddress: 0x0a00_0000, length: 0x4000),
                "VirtIO transport aperture was not coalesced"
            )
            expect(
                platform?.virtioTransportIsDMACoherent(at: 0) == true,
                "coherent VirtIO transport lost its property"
            )
            expect(
                platform?.virtioTransportIsDMACoherent(at: 1) == false,
                "noncoherent VirtIO transport inherited another node's property"
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
    let names = [
        "#address-cells",
        "#size-cells",
        "compatible",
        "device_type",
        "ranges",
        "reg",
        "dma-coherent",
        "width",
        "height",
        "stride",
        "format",
        "status",
    ]
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
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("qemu,virt".utf8) + [0],
        to: &structure
    )

    appendBeginNode("chosen", to: &structure)
    appendProperty(
        nameOffset: offsets["#address-cells"]!,
        value: be32(2),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["#size-cells"]!,
        value: be32(2),
        to: &structure
    )
    appendBeginNode("framebuffer@5e000000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("simple-framebuffer".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x5e00_0000)
            + be32(0) + be32(0x007e_9000),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["width"]!,
        value: be32(1_920),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["height"]!,
        value: be32(1_080),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["stride"]!,
        value: be32(7_680),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["format"]!,
        value: Array("x8r8g8b8".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["status"]!,
        value: Array("okay".utf8) + [0],
        to: &structure
    )
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)

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

    appendBeginNode("memory@40000000", to: &structure)
    appendProperty(
        nameOffset: offsets["device_type"]!,
        value: Array("memory".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x4000_0000) + be32(0) + be32(0x2000_0000)
            + be32(1) + be32(0) + be32(0) + be32(0x4000_0000),
        to: &structure
    )
    appendBE32(2, to: &structure)

    appendBeginNode("reserved-memory", to: &structure)
    appendProperty(nameOffset: offsets["#address-cells"]!, value: be32(2), to: &structure)
    appendProperty(nameOffset: offsets["#size-cells"]!, value: be32(2), to: &structure)
    appendProperty(nameOffset: offsets["ranges"]!, value: [], to: &structure)
    appendBeginNode("firmware@5f000000", to: &structure)
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x5f00_0000) + be32(0) + be32(0x10_0000),
        to: &structure
    )
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)

    appendBeginNode("interrupt-controller@8000000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("arm,gic-v3".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x0800_0000) + be32(0) + be32(0x1_0000)
            + be32(0) + be32(0x080a_0000) + be32(0) + be32(0x20_0000),
        to: &structure
    )
    appendBE32(2, to: &structure)

    appendBeginNode("virtio_mmio@a000000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("virtio,mmio".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x0a00_0000) + be32(0) + be32(0x200),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["dma-coherent"]!,
        value: [],
        to: &structure
    )
    appendBE32(2, to: &structure)

    appendBeginNode("virtio_mmio@a003e00", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("virtio,mmio".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0) + be32(0x0a00_3e00) + be32(0) + be32(0x200),
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
    appendProperty(
        nameOffset: offsets["ranges"]!,
        value: be32(0) + be32(0)
            + be32(0x10) + be32(0)
            + be32(0) + be32(0x1000_0000),
        to: &structure
    )
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
    appendBeginNode("cpus", to: &structure)
    appendProperty(nameOffset: offsets["#address-cells"]!, value: be32(1), to: &structure)
    appendProperty(nameOffset: offsets["#size-cells"]!, value: be32(0), to: &structure)
    appendBeginNode("cpu@100", to: &structure)
    appendProperty(
        nameOffset: offsets["device_type"]!,
        value: Array("cpu".utf8) + [0],
        to: &structure
    )
    appendProperty(nameOffset: offsets["reg"]!, value: be32(0x100), to: &structure)
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)
    appendBE32(9, to: &structure)

    let headerSize = 40
    let reservation = be64(0x4100_0000) + be64(0x1_0000)
        + Array(repeating: UInt8(0), count: 16)
    let structureOffset = headerSize + reservation.count
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

    return header + reservation + structure + strings
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

private func be64(_ value: UInt64) -> [UInt8] {
    be32(UInt32(truncatingIfNeeded: value >> 32))
        + be32(UInt32(truncatingIfNeeded: value))
}

private func appendBE32(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(contentsOf: be32(value))
}

private func overwriteBE32(_ bytes: inout [UInt8], at offset: Int, with value: UInt32) {
    bytes.replaceSubrange(offset..<(offset + 4), with: be32(value))
}
