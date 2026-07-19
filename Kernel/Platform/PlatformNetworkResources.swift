/// The register-level backend that may bind one discovered network device.
/// A VirtIO MMIO node remains a candidate until its device ID is read: the
/// standard Device Tree binding describes transports, not the device behind
/// each transport.
enum PlatformNetworkControllerKind: UInt8, Equatable {
    case virtioMMIOCandidate
    case rp1GEM

    var minimumRegisterByteCount: UInt64 {
        switch self {
        case .virtioMMIOCandidate: return 0x200
        case .rp1GEM: return 0x4_000
        }
    }
}

/// An interrupt remains relative to its hardware routing domain until that
/// domain's controller is initialized. In particular, an RP1 MSI-X vector is
/// not interchangeable with an Arm GIC interrupt ID.
enum PlatformNetworkInterruptRoute: Equatable {
    /// `number` is the GIC binding's zero-based SPI number. Its architectural
    /// interrupt ID is `number + 32`.
    case gicSPI(number: UInt32, trigger: PlatformInterruptTrigger)
    /// RP1 peripheral interrupt vector delivered through the RP1 PCIe
    /// endpoint's MSI-X routing domain.
    case rp1MSIX(vector: UInt32, trigger: PlatformInterruptTrigger)

    var architecturalGICInterruptID: UInt32? {
        guard case .gicSPI(let number, _) = self,
              number <= UInt32.max - 32
        else {
            return nil
        }
        return number + 32
    }
}

/// How a caller must obtain the device address paired with a CPU physical
/// allocation. This does not manufacture a mapping: the allocator/PCIe layer
/// remains responsible for producing a validated `DMAMapping` for each buffer.
enum PlatformNetworkDMAAddressing: UInt8, Equatable {
    /// Device addresses are system physical addresses, as on QEMU `virt`.
    case directSystemPhysical
    /// An ancestor bus owns the DMA translation windows published by
    /// `dma-ranges`, as for a peripheral inside RP1 behind PCIe.
    case translatedByParentBus
}

struct PlatformNetworkDMARequirements: Equatable {
    let addressing: PlatformNetworkDMAAddressing
    let coherency: DMACoherency
}

/// Six firmware-owned Ethernet address bytes copied out of the FDT. Raspberry
/// Pi firmware patches the all-zero value shipped in the base DTB during a
/// real board boot, so callers can distinguish a present placeholder from a
/// usable unicast address without retaining a pointer into the blob.
struct PlatformMACAddressBytes: Equatable {
    let byte0: UInt8
    let byte1: UInt8
    let byte2: UInt8
    let byte3: UInt8
    let byte4: UInt8
    let byte5: UInt8

    var isAllZero: Bool {
        byte0 == 0 && byte1 == 0 && byte2 == 0 && byte3 == 0
            && byte4 == 0 && byte5 == 0
    }

    var isUsableUnicast: Bool {
        !isAllZero && byte0 & 1 == 0
    }

    func byte(at index: Int) -> UInt8? {
        switch index {
        case 0: return byte0
        case 1: return byte1
        case 2: return byte2
        case 3: return byte3
        case 4: return byte4
        case 5: return byte5
        default: return nil
        }
    }
}

enum PlatformNetworkPHYMode: UInt8, Equatable {
    /// RGMII with both PHY-side RX and TX internal clock delays.
    case rgmiiID
}

struct PlatformNetworkPHYDescription: Equatable {
    let clause22Address: UInt32
    let mode: PlatformNetworkPHYMode
}

enum PlatformGPIOAssertedLevel: UInt8, Equatable {
    case high
    case low
}

/// The three RP1 GPIO register tuples, in the order published by the RP1 DT:
/// IO_BANK, SYS_RIO, and PADS_BANK. They remain separate because output value,
/// function selection, and pad policy do not share one register aperture.
struct RP1GPIORegisterResources: Equatable {
    let ioBank: DeviceResource
    let rio: DeviceResource
    let padsBank: DeviceResource
}

struct PlatformPHYResetDescription: Equatable {
    let gpioControllerPhandle: UInt32
    let gpioRegisters: RP1GPIORegisterResources
    let line: UInt32
    let assertedLevel: PlatformGPIOAssertedLevel
    /// The legacy `phy-reset-duration` binding is expressed in milliseconds.
    let durationMilliseconds: UInt32
}

/// RP1 clock-provider metadata for the four named GEM inputs. Discovery
/// resolves and validates every provider phandle but leaves clock programming
/// policy to the board bootstrap.
struct RP1GEMClockResources: Equatable {
    let controllerPhandle: UInt32
    let controllerRegisters: DeviceResource
    let peripheralClockID: UInt32
    let hostClockID: UInt32
    let timestampClockID: UInt32
    let transmitClockID: UInt32
}

/// RP1-only resources supplementing the backend-neutral network description.
/// `ethernetConfigurationRegisters` is the ETH_CFG atomic APB aperture adjacent
/// to GEM in the RP1 peripheral map; it is not represented as a separate DT
/// node in current firmware trees.
struct RP1GEMBoardResources: Equatable {
    let gemRegisters: DeviceResource
    let ethernetConfigurationRegisters: DeviceResource
    let clocks: RP1GEMClockResources
    let phy: PlatformNetworkPHYDescription
    let phyReset: PlatformPHYResetDescription?
    let localMACAddress: PlatformMACAddressBytes?
}

enum PlatformNetworkBoardResources: Equatable {
    case rp1GEM(RP1GEMBoardResources)
}

/// Board-neutral discovery result consumed by a network backend. `registers`
/// is already translated through every Device Tree `ranges` level into the CPU
/// physical address space; no driver should add a board-specific base address.
struct PlatformNetworkDeviceDescription: Equatable {
    let controller: PlatformNetworkControllerKind
    let registers: DeviceResource
    let interrupt: PlatformNetworkInterruptRoute
    let dma: PlatformNetworkDMARequirements
    let boardResources: PlatformNetworkBoardResources?
}

/// Heap-free Device Tree adapter shared by boot code and host probes.
struct PlatformNetworkDeviceDiscovery {
    static let maximumCandidateCount = 64

    static func candidate(
        in tree: FlattenedDeviceTree,
        board: BoardKind,
        at index: Int
    ) -> PlatformNetworkDeviceDescription? {
        guard index >= 0, index < maximumCandidateCount else { return nil }
        switch board {
        case .qemuVirt:
            return qemuVirtIOCandidate(in: tree, at: index)
        case .raspberryPi5:
            guard index == 0 else { return nil }
            return raspberryPi5GEM(in: tree)
        }
    }

    /// Produces the complete CPU/device mapping for one candidate and one
    /// contiguous physical interval. The caller supplies the controller's DMA
    /// width; aliases outside that width are discarded before ambiguity is
    /// evaluated. This is significant on RP1, which publishes both high and
    /// low aliases for system RAM.
    static func dmaMapping(
        in tree: FlattenedDeviceTree,
        board: BoardKind,
        candidateIndex: Int,
        cpuPhysicalAddress: UInt64,
        byteCount: UInt64,
        deviceAddressWidth: DMAAddressWidth
    ) -> DMAMapping? {
        guard let description = candidate(
                  in: tree,
                  board: board,
                  at: candidateIndex
              )
        else { return nil }

        let deviceAddress: UInt64
        switch description.dma.addressing {
        case .directSystemPhysical:
            deviceAddress = cpuPhysicalAddress
        case .translatedByParentBus:
            guard description.controller == .rp1GEM,
                  candidateIndex == 0,
                  let resource = tree.deviceDMAResource(
                      compatibleWith: "raspberrypi,rp1-gem",
                      nodeIndex: 0,
                      cpuPhysicalAddress: cpuPhysicalAddress,
                      byteCount: byteCount,
                      maximumDeviceAddress: deviceAddressWidth.highestAddress
                  ), resource.length == byteCount
            else { return nil }
            deviceAddress = resource.baseAddress
        }

        return DMAMapping(
            cpuPhysicalAddress: cpuPhysicalAddress,
            deviceAddress: deviceAddress,
            byteCount: byteCount,
            deviceAddressWidth: deviceAddressWidth,
            coherency: description.dma.coherency
        )
    }

    private static func qemuVirtIOCandidate(
        in tree: FlattenedDeviceTree,
        at index: Int
    ) -> PlatformNetworkDeviceDescription? {
        let controller = PlatformNetworkControllerKind.virtioMMIOCandidate
        guard let registers = tree.resource(
                  compatibleWith: "virtio,mmio",
                  nodeIndex: index
              ), valid(registers, for: controller),
              let cells = tree.propertyCells(
                  compatibleWith: "virtio,mmio",
                  nodeIndex: index,
                  property: "interrupts"
              ), cells.count == 3,
              cells.cell(at: 0) == 0,
              let number = cells.cell(at: 1),
              let rawTrigger = cells.cell(at: 2),
              let trigger = PlatformInterruptTrigger(rawValue: rawTrigger),
              number <= UInt32.max - 32
        else {
            return nil
        }

        return PlatformNetworkDeviceDescription(
            controller: controller,
            registers: registers,
            interrupt: .gicSPI(number: number, trigger: trigger),
            dma: PlatformNetworkDMARequirements(
                addressing: .directSystemPhysical,
                coherency: isDMACoherent(
                    registers,
                    compatibleWith: "virtio,mmio",
                    in: tree
                ) ? .hardwareCoherent : .softwareManaged
            ),
            boardResources: nil
        )
    }

    private static func raspberryPi5GEM(
        in tree: FlattenedDeviceTree
    ) -> PlatformNetworkDeviceDescription? {
        let controller = PlatformNetworkControllerKind.rp1GEM
        guard let registers = tree.resource(
                  compatibleWith: "raspberrypi,rp1-gem"
              ), valid(registers, for: controller),
              let cells = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "interrupts"
              ), cells.count == 2,
              let vector = cells.cell(at: 0),
              vector < 64,
              let rawTrigger = cells.cell(at: 1),
              let trigger = PlatformInterruptTrigger(rawValue: rawTrigger),
              let boardResources = raspberryPi5GEMBoardResources(
                  in: tree,
                  gemRegisters: registers
              )
        else {
            return nil
        }

        return PlatformNetworkDeviceDescription(
            controller: controller,
            registers: registers,
            interrupt: .rp1MSIX(vector: vector, trigger: trigger),
            dma: PlatformNetworkDMARequirements(
                addressing: .translatedByParentBus,
                coherency: isDMACoherent(
                    registers,
                    compatibleWith: "raspberrypi,rp1-gem",
                    in: tree
                ) ? .hardwareCoherent : .softwareManaged
            ),
            boardResources: .rp1GEM(boardResources)
        )
    }

    private static func raspberryPi5GEMBoardResources(
        in tree: FlattenedDeviceTree,
        gemRegisters: DeviceResource
    ) -> RP1GEMBoardResources? {
        // RP1's published peripheral map places the atomic ETH_CFG APB block
        // immediately after the 16-KiB GEM block. The current DT binding only
        // publishes GEM's `reg`, so derive ETH_CFG after the translated root
        // address is known and fail on any aperture shape or overflow change.
        let blockLength: UInt64 = 0x4_000
        guard gemRegisters.length == blockLength,
              gemRegisters.baseAddress <= UInt64.max - 2 * blockLength,
              let clocks = raspberryPi5GEMClocks(in: tree),
              let phy = raspberryPi5PHY(in: tree),
              let localMACAddress = raspberryPi5LocalMACAddress(in: tree)
        else { return nil }

        let resetGPIOPresent = tree.hasProperty(
            compatibleWith: "raspberrypi,rp1-gem",
            property: "phy-reset-gpios"
        )
        let resetDurationPresent = tree.hasProperty(
            compatibleWith: "raspberrypi,rp1-gem",
            property: "phy-reset-duration"
        )
        guard resetGPIOPresent == resetDurationPresent else { return nil }
        let phyReset: PlatformPHYResetDescription?
        if resetGPIOPresent {
            guard let reset = raspberryPi5PHYReset(in: tree) else {
                return nil
            }
            phyReset = reset
        } else {
            phyReset = nil
        }

        return RP1GEMBoardResources(
            gemRegisters: gemRegisters,
            ethernetConfigurationRegisters: DeviceResource(
                baseAddress: gemRegisters.baseAddress + blockLength,
                length: blockLength
            ),
            clocks: clocks,
            phy: phy,
            phyReset: phyReset,
            localMACAddress: localMACAddress
        )
    }

    private static func raspberryPi5GEMClocks(
        in tree: FlattenedDeviceTree
    ) -> RP1GEMClockResources? {
        guard let controllerRegisters = tree.resource(
                  compatibleWith: "raspberrypi,rp1-clocks"
              ), validMMIO(controllerRegisters),
              let controllerPhandle = uniqueNodePhandle(
                  in: tree,
                  compatibleWith: "raspberrypi,rp1-clocks"
              ),
              let providerCells = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-clocks",
                  property: "#clock-cells"
              ), providerCells.count == 1,
              providerCells.cell(at: 0) == 1,
              tree.propertyCells(
                  nodePhandle: controllerPhandle,
                  property: "#clock-cells"
              ) == providerCells,
              let specifiers = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "clocks"
              ), specifiers.count == 8,
              let names = tree.propertyBytes(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "clock-names"
              ), names.cStringCount == 4,
              names.cString(at: 0, equals: "pclk"),
              names.cString(at: 1, equals: "hclk"),
              names.cString(at: 2, equals: "tsu_clk"),
              names.cString(at: 3, equals: "tx_clk"),
              specifiers.cell(at: 0) == controllerPhandle,
              let peripheralClockID = specifiers.cell(at: 1),
              specifiers.cell(at: 2) == controllerPhandle,
              let hostClockID = specifiers.cell(at: 3),
              specifiers.cell(at: 4) == controllerPhandle,
              let timestampClockID = specifiers.cell(at: 5),
              specifiers.cell(at: 6) == controllerPhandle,
              let transmitClockID = specifiers.cell(at: 7)
        else { return nil }

        return RP1GEMClockResources(
            controllerPhandle: controllerPhandle,
            controllerRegisters: controllerRegisters,
            peripheralClockID: peripheralClockID,
            hostClockID: hostClockID,
            timestampClockID: timestampClockID,
            transmitClockID: transmitClockID
        )
    }

    private static func raspberryPi5PHY(
        in tree: FlattenedDeviceTree
    ) -> PlatformNetworkPHYDescription? {
        guard let addressCells = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "#address-cells"
              ), addressCells.count == 1,
              addressCells.cell(at: 0) == 1,
              let sizeCells = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "#size-cells"
              ), sizeCells.count == 1,
              sizeCells.cell(at: 0) == 0,
              let mode = tree.propertyBytes(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "phy-mode"
              ), mode.cStringCount == 1,
              mode.cString(at: 0, equals: "rgmii-id"),
              let handle = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "phy-handle"
              ), handle.count == 1,
              let phandle = handle.cell(at: 0), phandle != 0,
              let register = tree.propertyCells(
                  nodePhandle: phandle,
                  property: "reg"
              ), register.count == 1,
              let address = register.cell(at: 0), address < 32
        else { return nil }

        return PlatformNetworkPHYDescription(
            clause22Address: address,
            mode: .rgmiiID
        )
    }

    private static func raspberryPi5PHYReset(
        in tree: FlattenedDeviceTree
    ) -> PlatformPHYResetDescription? {
        guard let specifier = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "phy-reset-gpios"
              ), specifier.count == 3,
              let controllerPhandle = specifier.cell(at: 0),
              controllerPhandle != 0,
              let line = specifier.cell(at: 1), line < 54,
              let rawFlags = specifier.cell(at: 2), rawFlags <= 1,
              let duration = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "phy-reset-duration"
              ), duration.count == 1,
              let durationMilliseconds = duration.cell(at: 0),
              durationMilliseconds > 0,
              durationMilliseconds <= 1_000,
              let gpioPhandle = uniqueNodePhandle(
                  in: tree,
                  compatibleWith: "raspberrypi,rp1-gpio"
              ), gpioPhandle == controllerPhandle,
              let gpioCellCount = tree.propertyCells(
                  compatibleWith: "raspberrypi,rp1-gpio",
                  property: "#gpio-cells"
              ), gpioCellCount.count == 1,
              gpioCellCount.cell(at: 0) == 2,
              tree.propertyCells(
                  nodePhandle: controllerPhandle,
                  property: "#gpio-cells"
              ) == gpioCellCount,
              tree.hasProperty(
                  compatibleWith: "raspberrypi,rp1-gpio",
                  property: "gpio-controller"
              ),
              let ioBank = tree.resource(
                  compatibleWith: "raspberrypi,rp1-gpio",
                  registerIndex: 0
              ), let rio = tree.resource(
                  compatibleWith: "raspberrypi,rp1-gpio",
                  registerIndex: 1
              ), let padsBank = tree.resource(
                  compatibleWith: "raspberrypi,rp1-gpio",
                  registerIndex: 2
              ), validRP1GPIOResources(
                  ioBank: ioBank,
                  rio: rio,
                  padsBank: padsBank
              )
        else { return nil }

        return PlatformPHYResetDescription(
            gpioControllerPhandle: controllerPhandle,
            gpioRegisters: RP1GPIORegisterResources(
                ioBank: ioBank,
                rio: rio,
                padsBank: padsBank
            ),
            line: line,
            assertedLevel: rawFlags == 1 ? .low : .high,
            durationMilliseconds: durationMilliseconds
        )
    }

    /// A missing MAC property is valid. A present property must be exactly six
    /// bytes and either a firmware placeholder or a unicast address.
    private static func raspberryPi5LocalMACAddress(
        in tree: FlattenedDeviceTree
    ) -> PlatformMACAddressBytes?? {
        guard tree.hasProperty(
            compatibleWith: "raspberrypi,rp1-gem",
            property: "local-mac-address"
        ) else { return .some(nil) }
        guard let bytes = tree.propertyBytes(
                  compatibleWith: "raspberrypi,rp1-gem",
                  property: "local-mac-address"
              ), bytes.count == 6,
              let byte0 = bytes.byte(at: 0),
              let byte1 = bytes.byte(at: 1),
              let byte2 = bytes.byte(at: 2),
              let byte3 = bytes.byte(at: 3),
              let byte4 = bytes.byte(at: 4),
              let byte5 = bytes.byte(at: 5)
        else { return nil }
        let address = PlatformMACAddressBytes(
            byte0: byte0,
            byte1: byte1,
            byte2: byte2,
            byte3: byte3,
            byte4: byte4,
            byte5: byte5
        )
        guard address.isAllZero || address.isUsableUnicast else { return nil }
        return .some(address)
    }

    private static func uniqueNodePhandle(
        in tree: FlattenedDeviceTree,
        compatibleWith compatibility: StaticString
    ) -> UInt32? {
        let hasStandard = tree.hasProperty(
            compatibleWith: compatibility,
            property: "phandle"
        )
        let hasLegacy = tree.hasProperty(
            compatibleWith: compatibility,
            property: "linux,phandle"
        )
        let standard = tree.propertyCells(
            compatibleWith: compatibility,
            property: "phandle"
        )
        let legacy = tree.propertyCells(
            compatibleWith: compatibility,
            property: "linux,phandle"
        )
        if hasStandard {
            guard standard?.count == 1,
                  let value = standard?.cell(at: 0), value != 0
            else { return nil }
        }
        if hasLegacy {
            guard legacy?.count == 1,
                  let value = legacy?.cell(at: 0), value != 0
            else { return nil }
        }
        guard hasStandard || hasLegacy else { return nil }
        let value = standard?.cell(at: 0) ?? legacy?.cell(at: 0)
        guard standard?.cell(at: 0) == nil
                || legacy?.cell(at: 0) == nil
                || standard?.cell(at: 0) == legacy?.cell(at: 0)
        else { return nil }
        return value
    }

    private static func validMMIO(_ resource: DeviceResource) -> Bool {
        resource.baseAddress & 0x3 == 0
            && resource.length >= 4
            && resource.length <= UInt64.max - resource.baseAddress
    }

    private static func validRP1GPIOResources(
        ioBank: DeviceResource,
        rio: DeviceResource,
        padsBank: DeviceResource
    ) -> Bool {
        let apertureLength: UInt64 = 0xc_000
        let stride: UInt64 = 0x1_0000
        return ioBank.length == apertureLength
            && rio.length == apertureLength
            && padsBank.length == apertureLength
            && ioBank.baseAddress <= UInt64.max - 2 * stride
            && rio.baseAddress == ioBank.baseAddress + stride
            && padsBank.baseAddress == ioBank.baseAddress + 2 * stride
    }

    private static func isDMACoherent(
        _ target: DeviceResource,
        compatibleWith compatibility: StaticString,
        in tree: FlattenedDeviceTree
    ) -> Bool {
        // `nodeIndex` is relative to nodes satisfying the required property,
        // so compare translated resources rather than assuming the two index
        // spaces are identical.
        var coherentIndex = 0
        while coherentIndex < maximumCandidateCount,
              let coherent = tree.resource(
                  compatibleWith: compatibility,
                  nodeIndex: coherentIndex,
                  requiringProperty: "dma-coherent"
              ) {
            if coherent == target { return true }
            coherentIndex += 1
        }
        return false
    }

    private static func valid(
        _ resource: DeviceResource,
        for controller: PlatformNetworkControllerKind
    ) -> Bool {
        resource.baseAddress & 0x3 == 0
            && resource.length >= controller.minimumRegisterByteCount
            && resource.length <= UInt64.max - resource.baseAddress
    }
}

extension Platform {
    /// Returns one enabled network candidate described by the boot FDT. The
    /// description is safe to retain because it owns values rather than raw
    /// pointers into the firmware blob.
    func networkDeviceCandidate(
        at index: Int
    ) -> PlatformNetworkDeviceDescription? {
        guard let tree = FlattenedDeviceTree(address: deviceTreeAddress) else {
            return nil
        }
        return PlatformNetworkDeviceDiscovery.candidate(
            in: tree,
            board: kind,
            at: index
        )
    }

    /// Resolves DMA through the same boot FDT and candidate index used for
    /// network discovery. The returned value is ready for a driver workspace
    /// constructor; no board-specific address arithmetic remains at the call
    /// site.
    func networkDMAMapping(
        forCandidateAt index: Int,
        cpuPhysicalAddress: UInt64,
        byteCount: UInt64,
        deviceAddressWidth: DMAAddressWidth
    ) -> DMAMapping? {
        guard let tree = FlattenedDeviceTree(address: deviceTreeAddress) else {
            return nil
        }
        return PlatformNetworkDeviceDiscovery.dmaMapping(
            in: tree,
            board: kind,
            candidateIndex: index,
            cpuPhysicalAddress: cpuPhysicalAddress,
            byteCount: byteCount,
            deviceAddressWidth: deviceAddressWidth
        )
    }
}
