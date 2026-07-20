@main
struct FlattenedDeviceTreeTests {
    static func main() {
        findsNestedResourcesAndCompatibleListEntries()
        translatesChainedPCIRangesAndRejectsMalformedMappings()
        readsPlatformMemoryCPUAndRegisterIndexes()
        readsFirmwareSimpleFramebufferProperties()
        discoversEnabledPi5GraphicsResources()
        rejectsUnavailablePi5GraphicsResources()
        discoversPi5PeripheralUSBController()
        rejectsUnavailablePi5USBController()
        rejectsNonoperationalStatusesAndUnavailableAncestors()
        rejectsBadMagicAndTruncatedStructure()
        print("FDT host tests: 10 passed")
    }

    private static func translatesChainedPCIRangesAndRejectsMalformedMappings() {
        let bytes = makeRaspberryPiPCITranslationDeviceTree()
        bytes.withUnsafeBytes { storage in
            let tree = FlattenedDeviceTree(
                address: UInt64(UInt(bitPattern: storage.baseAddress!))
            )!
            expect(
                tree.resource(compatibleWith: "raspberrypi,rp1-gem")
                    == DeviceResource(
                        baseAddress: 0x1f_0010_0000,
                        length: 0x4000
                    ),
                "RP1 GEM did not traverse all AXI, PCI, and RP1 ranges"
            )
        }

        for malformed in [
            makeRaspberryPiPCITranslationDeviceTree(
                truncateRP1Ranges: true
            ),
            makeRaspberryPiPCITranslationDeviceTree(
                rp1ParentSelector: 0x4300_0000
            ),
        ] {
            malformed.withUnsafeBytes { storage in
                let tree = FlattenedDeviceTree(
                    address: UInt64(UInt(bitPattern: storage.baseAddress!))
                )!
                expect(
                    tree.resource(compatibleWith: "raspberrypi,rp1-gem")
                        == nil,
                    "malformed PCI translation fell back to an ancestor"
                )
            }
        }
    }

    private static func discoversPi5PeripheralUSBController() {
        for mode in ["peripheral", nil] as [String?] {
            let bytes = makeRaspberryPiGraphicsDeviceTree(usbMode: mode)
            bytes.withUnsafeBytes { storage in
                guard let platform = Platform.discover(
                          deviceTreeAddress: UInt64(
                              UInt(bitPattern: storage.baseAddress!)
                          )
                      )
                else {
                    fatalError("Pi USB fixture was rejected")
                }
                expect(
                    platform.usbDeviceController == .dwc2(
                        registers: DeviceResource(
                            baseAddress: 0x10_0048_0000,
                            length: 0x1_0000
                        )
                    ),
                    "translated Pi DWC2 peripheral resource mismatch"
                )
            }
        }
    }

    private static func rejectsUnavailablePi5USBController() {
        let fixtures = [
            makeRaspberryPiGraphicsDeviceTree(usbMode: "host"),
            makeRaspberryPiGraphicsDeviceTree(usbEnabled: false),
            makeRaspberryPiGraphicsDeviceTree(unalignedUSBRegisters: true),
            makeRaspberryPiGraphicsDeviceTree(usbRegisterLength: 0),
        ]
        for bytes in fixtures {
            bytes.withUnsafeBytes { storage in
                guard let platform = Platform.discover(
                          deviceTreeAddress: UInt64(
                              UInt(bitPattern: storage.baseAddress!)
                          )
                      )
                else {
                    fatalError("Pi platform fixture was rejected")
                }
                expect(
                    platform.usbDeviceController == nil,
                    "unavailable or host-mode Pi USB controller was bound"
                )
            }
        }
    }

    private static func rejectsNonoperationalStatusesAndUnavailableAncestors() {
        let bytes = makeAvailabilityDeviceTree()
        bytes.withUnsafeBytes { storage in
            guard let tree = FlattenedDeviceTree(
                      address: UInt64(UInt(bitPattern: storage.baseAddress!))
                  )
            else {
                fatalError("availability fixture was rejected")
            }

            let operational: [StaticString] = [
                "swiftos,status-absent",
                "swiftos,status-okay",
                "swiftos,status-ok",
            ]
            for compatibility in operational {
                expect(
                    tree.resource(compatibleWith: compatibility) != nil,
                    "operational DT status was rejected"
                )
            }
            let unavailable: [StaticString] = [
                "swiftos,status-disabled",
                "swiftos,status-reserved",
                "swiftos,status-fail",
                "swiftos,status-fail-detail",
                "swiftos,status-unknown",
                "swiftos,status-malformed",
                "swiftos,child-of-disabled-bus",
            ]
            for compatibility in unavailable {
                expect(
                    tree.resource(compatibleWith: compatibility) == nil,
                    "unavailable DT node was exposed to a driver"
                )
            }
        }
    }

    private static func discoversEnabledPi5GraphicsResources() {
        let bytes = makeRaspberryPiGraphicsDeviceTree()
        bytes.withUnsafeBytes { storage in
            guard let platform = Platform.discover(
                      deviceTreeAddress: UInt64(
                          UInt(bitPattern: storage.baseAddress!)
                      )
                  )
            else {
                fatalError("Pi graphics fixture was rejected")
            }

            let expected = PlatformGraphicsResources(
                renderer: .v3dVII(
                    V3DVIIRegisterResources(
                        hub: DeviceResource(
                            baseAddress: 0x21_0000_1000,
                            length: 0x4000
                        ),
                        core0: DeviceResource(
                            baseAddress: 0x21_0000_9000,
                            length: 0x6000
                        ),
                        sms: DeviceResource(
                            baseAddress: 0x21_0003_1800,
                            length: 0x700
                        )
                    )
                ),
                scanout: .hvs(
                    HVSRegisterResources(
                        registers: DeviceResource(
                            baseAddress: 0x22_0c58_0000,
                            length: 0x1a000
                        )
                    )
                ),
                addressSpaces: GraphicsAddressSpaceRequirements(
                    renderer: .deviceManaged,
                    scanout: .platformIOMMU
                )
            )
            expect(
                platform.graphicsResources == expected,
                "Pi graphics resources were not read from the FDT"
            )
        }
    }

    private static func rejectsUnavailablePi5GraphicsResources() {
        let fixtures = [
            makeRaspberryPiGraphicsDeviceTree(v3dEnabled: false),
            makeRaspberryPiGraphicsDeviceTree(hvsEnabled: false),
            makeRaspberryPiGraphicsDeviceTree(includeHVSAddressTranslation: false),
            makeRaspberryPiGraphicsDeviceTree(includeSMSRegisters: false),
            makeRaspberryPiGraphicsDeviceTree(overlapV3DRegisters: true),
            makeRaspberryPiGraphicsDeviceTree(unalignedV3DRegisters: true),
        ]
        for bytes in fixtures {
            bytes.withUnsafeBytes { storage in
                guard let platform = Platform.discover(
                          deviceTreeAddress: UInt64(
                              UInt(bitPattern: storage.baseAddress!)
                          )
                      )
                else {
                    fatalError("Pi platform fixture was rejected")
                }
                expect(
                    platform.graphicsResources == nil,
                    "unavailable Pi graphics hardware was bound"
                )
            }
        }
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
            expect(
                platform?.usbDeviceController == nil,
                "QEMU unexpectedly published a Pi USB device controller"
            )
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
            expect(
                platform?.containsSystemMemory(
                    baseAddress: 0x4000_1000,
                    length: 0x2000
                ) == true,
                "contained system-memory span was rejected"
            )
            expect(
                platform?.overlapsSystemMemory(
                    baseAddress: 0x4000_1000,
                    length: 0x2000
                ) == true,
                "contained system-memory span did not overlap"
            )
            expect(
                platform?.containsSystemMemory(
                    baseAddress: 0x3fff_f000,
                    length: 0x2000
                ) == false,
                "partial system-memory overlap was treated as contained"
            )
            expect(
                platform?.overlapsSystemMemory(
                    baseAddress: 0x3fff_f000,
                    length: 0x2000
                ) == true,
                "partial system-memory overlap was missed"
            )
            expect(
                platform?.overlapsSystemMemory(
                    baseAddress: 0x7000_0000,
                    length: 0x1000
                ) == false,
                "disjoint span overlapped system memory"
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

private func makeRaspberryPiPCITranslationDeviceTree(
    truncateRP1Ranges: Bool = false,
    rp1ParentSelector: UInt32 = 0x0200_0000
) -> [UInt8] {
    let names = ["#address-cells", "#size-cells", "compatible", "ranges", "reg"]
    var strings: [UInt8] = []
    var offsets: [String: UInt32] = [:]
    for name in names {
        offsets[name] = UInt32(strings.count)
        strings.append(contentsOf: name.utf8)
        strings.append(0)
    }

    var structure: [UInt8] = []
    appendBeginNode("", to: &structure)
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

    // The desired address is deliberately in the second AXI range. A parser
    // that consumes only the first tuple cannot reach the RP1 aperture.
    appendBeginNode("axi", to: &structure)
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
    appendProperty(
        nameOffset: offsets["ranges"]!,
        value: be64(0) + be64(0) + be64(0x1000)
            + be64(0x1c_0000_0000) + be64(0x1c_0000_0000)
            + be64(0x4_0000_0000),
        to: &structure
    )

    appendBeginNode("pcie@1000120000", to: &structure)
    appendProperty(
        nameOffset: offsets["#address-cells"]!,
        value: be32(3),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["#size-cells"]!,
        value: be32(2),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["ranges"]!,
        value: be32(0x0200_0000) + be64(0)
            + be64(0x1f_0000_0000) + be64(0xffff_fffc),
        to: &structure
    )

    appendBeginNode("rp1", to: &structure)
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
    var rp1Ranges = be64(0xc0_4000_0000)
        + be32(rp1ParentSelector) + be64(0) + be64(0x41_0000)
    if truncateRP1Ranges {
        rp1Ranges.removeLast(4)
    }
    appendProperty(
        nameOffset: offsets["ranges"]!,
        value: rp1Ranges,
        to: &structure
    )

    appendBeginNode("ethernet@100000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("raspberrypi,rp1-gem".utf8) + [0]
            + Array("cdns,macb".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be64(0xc0_4010_0000) + be64(0x4000),
        to: &structure
    )

    appendBE32(2, to: &structure) // ethernet
    appendBE32(2, to: &structure) // rp1
    appendBE32(2, to: &structure) // pcie
    appendBE32(2, to: &structure) // axi
    appendBE32(2, to: &structure) // root
    appendBE32(9, to: &structure)

    let headerSize = 40
    let reservation = Array(repeating: UInt8(0), count: 16)
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

private func makeAvailabilityDeviceTree() -> [UInt8] {
    let names = [
        "#address-cells",
        "#size-cells",
        "compatible",
        "ranges",
        "reg",
        "status",
    ]
    var strings: [UInt8] = []
    var offsets: [String: UInt32] = [:]
    for name in names {
        offsets[name] = UInt32(strings.count)
        strings.append(contentsOf: name.utf8)
        strings.append(0)
    }

    let nodes: [(name: String, compatibility: String, status: [UInt8]?)] = [
        ("absent@1000", "swiftos,status-absent", nil),
        ("okay@2000", "swiftos,status-okay", Array("okay".utf8) + [0]),
        ("ok@3000", "swiftos,status-ok", Array("ok".utf8) + [0]),
        ("disabled@4000", "swiftos,status-disabled", Array("disabled".utf8) + [0]),
        ("reserved@5000", "swiftos,status-reserved", Array("reserved".utf8) + [0]),
        ("fail@6000", "swiftos,status-fail", Array("fail".utf8) + [0]),
        ("fail-detail@7000", "swiftos,status-fail-detail", Array("fail-selftest".utf8) + [0]),
        ("unknown@8000", "swiftos,status-unknown", Array("standby".utf8) + [0]),
        ("malformed@9000", "swiftos,status-malformed", Array("okay".utf8)),
    ]

    var structure: [UInt8] = []
    appendBeginNode("", to: &structure)
    appendProperty(
        nameOffset: offsets["#address-cells"]!,
        value: be32(1),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["#size-cells"]!,
        value: be32(1),
        to: &structure
    )

    var address: UInt32 = 0x1000
    for node in nodes {
        appendBeginNode(node.name, to: &structure)
        appendProperty(
            nameOffset: offsets["compatible"]!,
            value: Array(node.compatibility.utf8) + [0],
            to: &structure
        )
        appendProperty(
            nameOffset: offsets["reg"]!,
            value: be32(address) + be32(0x100),
            to: &structure
        )
        if let status = node.status {
            appendProperty(
                nameOffset: offsets["status"]!,
                value: status,
                to: &structure
            )
        }
        appendBE32(2, to: &structure)
        address += 0x1000
    }

    appendBeginNode("disabled-bus", to: &structure)
    appendProperty(
        nameOffset: offsets["#address-cells"]!,
        value: be32(1),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["#size-cells"]!,
        value: be32(1),
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["ranges"]!,
        value: [],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["status"]!,
        value: Array("disabled".utf8) + [0],
        to: &structure
    )
    appendBeginNode("child@a000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("swiftos,child-of-disabled-bus".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be32(0xa000) + be32(0x100),
        to: &structure
    )
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)
    appendBE32(9, to: &structure)

    let headerSize = 40
    let reservation = Array(repeating: UInt8(0), count: 16)
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

private func makeRaspberryPiGraphicsDeviceTree(
    v3dEnabled: Bool = true,
    hvsEnabled: Bool = true,
    includeHVSAddressTranslation: Bool = true,
    includeSMSRegisters: Bool = true,
    overlapV3DRegisters: Bool = false,
    unalignedV3DRegisters: Bool = false,
    usbMode: String? = "peripheral",
    usbEnabled: Bool = true,
    unalignedUSBRegisters: Bool = false,
    usbRegisterLength: UInt64 = 0x1_0000
) -> [UInt8] {
    let names = [
        "#address-cells",
        "#size-cells",
        "compatible",
        "reg",
        "status",
        "iommus",
        "ranges",
        "dr_mode",
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
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("raspberrypi,5-model-b".utf8) + [0]
            + Array("brcm,bcm2712".utf8) + [0],
        to: &structure
    )

    appendBeginNode("serial@107d001000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("arm,pl011".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be64(0x10_7d00_1000) + be64(0x200),
        to: &structure
    )
    appendBE32(2, to: &structure)

    appendBeginNode("interrupt-controller@107fff9000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("arm,gic-400".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be64(0x10_7fff_9000) + be64(0x1000)
            + be64(0x10_7fff_a000) + be64(0x2000),
        to: &structure
    )
    appendBE32(2, to: &structure)

    appendBeginNode("gpu@2100001000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("brcm,2712-v3d".utf8) + [0],
        to: &structure
    )
    let hubAddress: UInt64 = unalignedV3DRegisters
        ? 0x21_0000_1001
        : 0x21_0000_1000
    let coreAddress: UInt64 = overlapV3DRegisters
        ? 0x21_0000_2000
        : 0x21_0000_9000
    var v3dRegisters = be64(hubAddress) + be64(0x4000)
        + be64(coreAddress) + be64(0x6000)
    if includeSMSRegisters {
        v3dRegisters += be64(0x21_0003_1800) + be64(0x700)
    }
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: v3dRegisters,
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["status"]!,
        value: Array((v3dEnabled ? "okay" : "disabled").utf8) + [0],
        to: &structure
    )
    appendBE32(2, to: &structure)

    appendBeginNode("hvs@220c580000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("brcm,bcm2712-hvs".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be64(0x22_0c58_0000) + be64(0x1a000),
        to: &structure
    )
    if includeHVSAddressTranslation {
        appendProperty(
            nameOffset: offsets["iommus"]!,
            value: be32(1),
            to: &structure
        )
    }
    appendProperty(
        nameOffset: offsets["status"]!,
        value: Array((hvsEnabled ? "okay" : "disabled").utf8) + [0],
        to: &structure
    )
    appendBE32(2, to: &structure)

    // Exercise the same parent-range translation the firmware-patched Pi DT
    // uses. Platform discovery consumes only the translated resource.
    appendBeginNode("soc@1000000000", to: &structure)
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
    appendProperty(
        nameOffset: offsets["ranges"]!,
        value: be64(0) + be64(0x10_0000_0000) + be64(0x0100_0000),
        to: &structure
    )

    appendBeginNode("usb@480000", to: &structure)
    appendProperty(
        nameOffset: offsets["compatible"]!,
        value: Array("brcm,bcm2835-usb".utf8) + [0],
        to: &structure
    )
    appendProperty(
        nameOffset: offsets["reg"]!,
        value: be64(unalignedUSBRegisters ? 0x0048_0001 : 0x0048_0000)
            + be64(usbRegisterLength),
        to: &structure
    )
    if let usbMode {
        appendProperty(
            nameOffset: offsets["dr_mode"]!,
            value: Array(usbMode.utf8) + [0],
            to: &structure
        )
    }
    appendProperty(
        nameOffset: offsets["status"]!,
        value: Array((usbEnabled ? "okay" : "disabled").utf8) + [0],
        to: &structure
    )
    appendBE32(2, to: &structure)
    appendBE32(2, to: &structure)

    appendBE32(2, to: &structure)
    appendBE32(9, to: &structure)

    let headerSize = 40
    let reservation = Array(repeating: UInt8(0), count: 16)
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
