private enum SyntheticNetworkBoard {
    case qemu(interruptBytes: [UInt8], enabled: Bool)
    case raspberryPi(interruptBytes: [UInt8], dmaCoherent: Bool)
}

@main
struct PlatformNetworkDiscoveryTests {
    private static var failures = 0

    static func main() {
        testQEMUTranslatedCandidate()
        testRaspberryPiTranslatedCandidate()
        testPropertyCellsStayAttachedToTheirNode()
        testMalformedInterruptsFailClosed()
        testDisabledNodeIsNotDiscoverable()

        guard failures == 0 else {
            fatalError("\(failures) platform network discovery test(s) failed")
        }
        print("platform network discovery host tests passed (5 groups)")
    }

    private static func testQEMUTranslatedCandidate() {
        withTree(
            makeTree(
                .qemu(
                    interruptBytes: words([0, 0x10, 1]),
                    enabled: true
                )
            )
        ) { tree in
            guard let description = PlatformNetworkDeviceDiscovery.candidate(
                      in: tree,
                      board: .qemuVirt,
                      at: 0
                  )
            else {
                fail("valid translated QEMU candidate rejected")
                return
            }
            expect(
                description.controller == .virtioMMIOCandidate,
                "QEMU controller kind"
            )
            expect(
                description.registers == DeviceResource(
                    baseAddress: 0x8000_2000,
                    length: 0x200
                ),
                "QEMU MMIO aperture was not translated through ranges"
            )
            expect(
                description.interrupt == .gicSPI(
                    number: 0x10,
                    trigger: .edgeRising
                ),
                "QEMU GIC SPI metadata"
            )
            expect(
                description.interrupt.architecturalGICInterruptID == 48,
                "QEMU GIC architectural interrupt ID"
            )
            expect(
                description.dma == PlatformNetworkDMARequirements(
                    addressing: .directSystemPhysical,
                    coherency: .hardwareCoherent
                ),
                "QEMU DMA contract"
            )
            expect(
                PlatformNetworkDeviceDiscovery.candidate(
                    in: tree,
                    board: .qemuVirt,
                    at: 1
                ) == nil,
                "QEMU discovery escaped candidate bounds"
            )
        }
    }

    private static func testRaspberryPiTranslatedCandidate() {
        withTree(
            makeTree(
                .raspberryPi(
                    interruptBytes: words([6, 4]),
                    dmaCoherent: false
                )
            )
        ) { tree in
            guard let description = PlatformNetworkDeviceDiscovery.candidate(
                      in: tree,
                      board: .raspberryPi5,
                      at: 0
                  )
            else {
                fail("valid translated RP1 GEM candidate rejected")
                return
            }
            expect(description.controller == .rp1GEM, "RP1 controller kind")
            expect(
                description.registers == DeviceResource(
                    baseAddress: 0x1f_0010_0000,
                    length: 0x4_000
                ),
                "RP1 GEM aperture was not translated through PCIe and RP1 ranges"
            )
            expect(
                description.interrupt == .rp1MSIX(
                    vector: 6,
                    trigger: .levelHigh
                ),
                "RP1 MSI-X metadata"
            )
            expect(
                description.interrupt.architecturalGICInterruptID == nil,
                "RP1 vector was collapsed into the GIC domain"
            )
            expect(
                description.dma == PlatformNetworkDMARequirements(
                    addressing: .translatedByParentBus,
                    coherency: .softwareManaged
                ),
                "RP1 DMA contract"
            )
            expect(
                PlatformNetworkDeviceDiscovery.candidate(
                    in: tree,
                    board: .raspberryPi5,
                    at: 1
                ) == nil,
                "RP1 published more than one GEM candidate"
            )
        }

        withTree(
            makeTree(
                .raspberryPi(
                    interruptBytes: words([6, 4]),
                    dmaCoherent: true
                )
            )
        ) { tree in
            expect(
                PlatformNetworkDeviceDiscovery.candidate(
                    in: tree,
                    board: .raspberryPi5,
                    at: 0
                )?.dma.coherency == .hardwareCoherent,
                "explicit RP1 dma-coherent property ignored"
            )
        }
    }

    private static func testPropertyCellsStayAttachedToTheirNode() {
        withTree(makeQEMUPropertyAssociationTree()) { tree in
            // Node zero has no interrupts. The cell reader must not borrow the
            // second compatible node's interrupt specifier.
            expect(
                tree.propertyCells(
                    compatibleWith: "virtio,mmio",
                    nodeIndex: 0,
                    property: "interrupts"
                ) == nil,
                "property cells shifted across compatible nodes"
            )
            expect(
                PlatformNetworkDeviceDiscovery.candidate(
                    in: tree,
                    board: .qemuVirt,
                    at: 0
                ) == nil,
                "candidate borrowed another node's interrupt"
            )
            expect(
                PlatformNetworkDeviceDiscovery.candidate(
                    in: tree,
                    board: .qemuVirt,
                    at: 1
                )?.interrupt == .gicSPI(
                    number: 0x11,
                    trigger: .edgeRising
                ),
                "property-bearing candidate lost its interrupt"
            )
        }
    }

    private static func testMalformedInterruptsFailClosed() {
        let malformedValues: [[UInt8]] = [
            words([0, 0x10]),
            [0, 0, 0],
            words([0, 0x10, 0x20]),
            words([0, 1, 2, 3, 4, 5, 6, 7, 8]),
        ]
        for value in malformedValues {
            withTree(
                makeTree(.qemu(interruptBytes: value, enabled: true))
            ) { tree in
                expect(
                    PlatformNetworkDeviceDiscovery.candidate(
                        in: tree,
                        board: .qemuVirt,
                        at: 0
                    ) == nil,
                    "malformed QEMU interrupt accepted"
                )
            }
        }

        withTree(
            makeTree(
                .raspberryPi(
                    interruptBytes: words([64, 4]),
                    dmaCoherent: false
                )
            )
        ) { tree in
            expect(
                PlatformNetworkDeviceDiscovery.candidate(
                    in: tree,
                    board: .raspberryPi5,
                    at: 0
                ) == nil,
                "out-of-domain RP1 vector accepted"
            )
        }
    }

    private static func testDisabledNodeIsNotDiscoverable() {
        withTree(
            makeTree(
                .qemu(
                    interruptBytes: words([0, 0x10, 1]),
                    enabled: false
                )
            )
        ) { tree in
            expect(
                PlatformNetworkDeviceDiscovery.candidate(
                    in: tree,
                    board: .qemuVirt,
                    at: 0
                ) == nil,
                "disabled VirtIO node was discovered"
            )
        }
    }

    private static func withTree(
        _ bytes: [UInt8],
        body: (FlattenedDeviceTree) -> Void
    ) {
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: bytes.count,
            alignment: 8
        )
        defer { storage.deallocate() }
        bytes.withUnsafeBytes { source in
            storage.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
        guard let tree = FlattenedDeviceTree(
                  address: UInt64(UInt(bitPattern: storage))
              )
        else {
            fail("synthetic FDT rejected")
            return
        }
        body(tree)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func makeTree(_ board: SyntheticNetworkBoard) -> [UInt8] {
    let names = [
        "#address-cells", "#size-cells", "compatible", "ranges", "reg",
        "interrupts", "dma-coherent", "status",
    ]
    let strings = makeStrings(names)
    let offsets = strings.offsets
    var structure: [UInt8] = []
    beginNode("", &structure)
    property(offsets["#address-cells"]!, words([2]), &structure)
    property(offsets["#size-cells"]!, words([2]), &structure)

    switch board {
    case .qemu(let interruptBytes, let enabled):
        beginNode("bus", &structure)
        property(offsets["#address-cells"]!, words([2]), &structure)
        property(offsets["#size-cells"]!, words([2]), &structure)
        property(
            offsets["ranges"]!,
            be64(0) + be64(0x8000_0000) + be64(0x1_0000),
            &structure
        )
        beginNode("virtio@2000", &structure)
        property(offsets["compatible"]!, cStrings(["virtio,mmio"]), &structure)
        property(offsets["reg"]!, be64(0x2_000) + be64(0x200), &structure)
        property(offsets["interrupts"]!, interruptBytes, &structure)
        property(offsets["dma-coherent"]!, [], &structure)
        if !enabled {
            property(offsets["status"]!, cStrings(["disabled"]), &structure)
        }
        endNode(&structure)
        endNode(&structure)

    case .raspberryPi(let interruptBytes, let dmaCoherent):
        beginNode("axi", &structure)
        property(offsets["#address-cells"]!, words([2]), &structure)
        property(offsets["#size-cells"]!, words([2]), &structure)
        property(
            offsets["ranges"]!,
            be64(0x1c_0000_0000) + be64(0x1c_0000_0000)
                + be64(0x4_0000_0000),
            &structure
        )
        beginNode("pcie", &structure)
        property(offsets["#address-cells"]!, words([3]), &structure)
        property(offsets["#size-cells"]!, words([2]), &structure)
        property(
            offsets["ranges"]!,
            words([0x0200_0000]) + be64(0) + be64(0x1f_0000_0000)
                + be64(0xffff_fffc),
            &structure
        )
        beginNode("rp1", &structure)
        property(offsets["#address-cells"]!, words([2]), &structure)
        property(offsets["#size-cells"]!, words([2]), &structure)
        property(
            offsets["ranges"]!,
            be64(0xc0_4000_0000) + words([0x0200_0000]) + be64(0)
                + be64(0x41_0000),
            &structure
        )
        beginNode("ethernet@100000", &structure)
        property(
            offsets["compatible"]!,
            cStrings(["raspberrypi,rp1-gem", "cdns,macb"]),
            &structure
        )
        property(
            offsets["reg"]!,
            be64(0xc0_4010_0000) + be64(0x4_000),
            &structure
        )
        property(offsets["interrupts"]!, interruptBytes, &structure)
        if dmaCoherent {
            property(offsets["dma-coherent"]!, [], &structure)
        }
        endNode(&structure)
        endNode(&structure)
        endNode(&structure)
        endNode(&structure)
    }

    endNode(&structure)
    word(9, &structure)
    return finishFDT(structure: structure, strings: strings.bytes)
}

private func makeQEMUPropertyAssociationTree() -> [UInt8] {
    let names = [
        "#address-cells", "#size-cells", "compatible", "reg", "interrupts",
    ]
    let strings = makeStrings(names)
    let offsets = strings.offsets
    var structure: [UInt8] = []
    beginNode("", &structure)
    property(offsets["#address-cells"]!, words([2]), &structure)
    property(offsets["#size-cells"]!, words([2]), &structure)
    beginNode("virtio@1000", &structure)
    property(offsets["compatible"]!, cStrings(["virtio,mmio"]), &structure)
    property(offsets["reg"]!, be64(0x1_000) + be64(0x200), &structure)
    endNode(&structure)
    beginNode("virtio@2000", &structure)
    property(offsets["compatible"]!, cStrings(["virtio,mmio"]), &structure)
    property(offsets["reg"]!, be64(0x2_000) + be64(0x200), &structure)
    property(offsets["interrupts"]!, words([0, 0x11, 1]), &structure)
    endNode(&structure)
    endNode(&structure)
    word(9, &structure)
    return finishFDT(structure: structure, strings: strings.bytes)
}

private func makeStrings(
    _ names: [String]
) -> (bytes: [UInt8], offsets: [String: UInt32]) {
    var bytes: [UInt8] = []
    var offsets: [String: UInt32] = [:]
    for name in names {
        offsets[name] = UInt32(bytes.count)
        bytes.append(contentsOf: name.utf8)
        bytes.append(0)
    }
    return (bytes, offsets)
}

private func beginNode(_ name: String, _ output: inout [UInt8]) {
    word(1, &output)
    output.append(contentsOf: name.utf8)
    output.append(0)
    pad4(&output)
}

private func endNode(_ output: inout [UInt8]) { word(2, &output) }

private func property(
    _ nameOffset: UInt32,
    _ value: [UInt8],
    _ output: inout [UInt8]
) {
    word(3, &output)
    word(UInt32(value.count), &output)
    word(nameOffset, &output)
    output.append(contentsOf: value)
    pad4(&output)
}

private func finishFDT(structure: [UInt8], strings: [UInt8]) -> [UInt8] {
    let headerSize = 40
    let reservation = [UInt8](repeating: 0, count: 16)
    let structureOffset = headerSize + reservation.count
    let stringsOffset = structureOffset + structure.count
    let totalSize = stringsOffset + strings.count
    var header: [UInt8] = []
    word(0xd00d_feed, &header)
    word(UInt32(totalSize), &header)
    word(UInt32(structureOffset), &header)
    word(UInt32(stringsOffset), &header)
    word(UInt32(headerSize), &header)
    word(17, &header)
    word(16, &header)
    word(0, &header)
    word(UInt32(strings.count), &header)
    word(UInt32(structure.count), &header)
    return header + reservation + structure + strings
}

private func cStrings(_ values: [String]) -> [UInt8] {
    var result: [UInt8] = []
    for value in values {
        result.append(contentsOf: value.utf8)
        result.append(0)
    }
    return result
}

private func words(_ values: [UInt32]) -> [UInt8] {
    var result: [UInt8] = []
    for value in values { word(value, &result) }
    return result
}

private func be64(_ value: UInt64) -> [UInt8] {
    words([UInt32(value >> 32), UInt32(value & 0xffff_ffff)])
}

private func word(_ value: UInt32, _ output: inout [UInt8]) {
    output.append(UInt8((value >> 24) & 0xff))
    output.append(UInt8((value >> 16) & 0xff))
    output.append(UInt8((value >> 8) & 0xff))
    output.append(UInt8(value & 0xff))
}

private func pad4(_ output: inout [UInt8]) {
    while output.count & 3 != 0 { output.append(0) }
}
