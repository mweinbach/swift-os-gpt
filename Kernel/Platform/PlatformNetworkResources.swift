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

/// Standard Device Tree interrupt trigger encodings used by both supported
/// interrupt domains. Keeping trigger policy in discovery prevents a driver
/// from guessing electrical semantics from a board name.
enum PlatformInterruptTrigger: UInt32, Equatable {
    case edgeRising = 1
    case edgeFalling = 2
    case levelHigh = 4
    case levelLow = 8
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

/// Board-neutral discovery result consumed by a network backend. `registers`
/// is already translated through every Device Tree `ranges` level into the CPU
/// physical address space; no driver should add a board-specific base address.
struct PlatformNetworkDeviceDescription: Equatable {
    let controller: PlatformNetworkControllerKind
    let registers: DeviceResource
    let interrupt: PlatformNetworkInterruptRoute
    let dma: PlatformNetworkDMARequirements
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
            )
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
              let trigger = PlatformInterruptTrigger(rawValue: rawTrigger)
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
            )
        )
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
}
