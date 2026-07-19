enum BoardKind: UInt8, Equatable {
    case qemuVirt
    case raspberryPi5
}

enum FirmwareCallConduit: UInt8, Equatable {
    case hypervisorCall
    case secureMonitorCall
}

enum InterruptControllerDescription: Equatable {
    case gicV2(distributor: DeviceResource, cpuInterface: DeviceResource)
    case gicV3(distributor: DeviceResource, redistributor: DeviceResource)
}

/// Standard Device Tree interrupt trigger encodings shared by platform-device
/// discovery. Keeping the electrical trigger in the firmware description
/// prevents an individual driver from guessing it from a board name.
enum PlatformInterruptTrigger: UInt32, Equatable {
    case edgeRising = 1
    case edgeFalling = 2
    case levelHigh = 4
    case levelLow = 8
}

/// A controller that can expose SwiftOS as a USB device to a host. This is a
/// discovery contract only: register programming, endpoint ownership, and USB
/// protocol policy remain in separate driver layers.
enum USBDeviceControllerDescription: Equatable {
    case dwc2(registers: DeviceResource)
}

/// Names the address-translation owner a graphics backend must program before
/// a buffer can be accessed by one stage of the display pipeline. Renderer and
/// scanout addresses are intentionally independent: a render target handed to
/// a display engine may need two mappings even when both refer to one physical
/// allocation.
enum GraphicsAddressTranslationRequirement: UInt8, Equatable {
    /// The device consumes a system-bus address without another translation
    /// domain. This is useful for simple DMA engines and virtual devices.
    case directSystemBus
    /// The renderer owns its GPU virtual address space and page tables.
    case deviceManaged
    /// A platform IOMMU supplies the device-visible address.
    case platformIOMMU
}

struct GraphicsAddressSpaceRequirements: Equatable {
    let renderer: GraphicsAddressTranslationRequirement
    let scanout: GraphicsAddressTranslationRequirement
}

/// The three independently mapped register regions published by the Pi 5 V3D
/// VII Device Tree binding. This is discovery metadata only; it does not imply
/// that clocks, resets, interrupts, or command submission are implemented.
struct V3DVIIRegisterResources: Equatable {
    let hub: DeviceResource
    let core0: DeviceResource
    let sms: DeviceResource
}

/// The Pi display compositor/scanout register aperture. It remains separate
/// from V3D because rendering and scanout are distinct devices with distinct
/// address spaces and ownership rules.
struct HVSRegisterResources: Equatable {
    let registers: DeviceResource
}

enum GraphicsRendererResourceDescription: Equatable {
    case v3dVII(V3DVIIRegisterResources)
}

enum GraphicsScanoutResourceDescription: Equatable {
    case hvs(HVSRegisterResources)
}

/// Backend-neutral hardware discovery result. Drivers consume this contract
/// instead of reaching back into a board-specific Device Tree or assuming that
/// renderer and scanout share one DMA address.
struct PlatformGraphicsResources: Equatable {
    static let maximumMMIOResourceCount = 4

    let renderer: GraphicsRendererResourceDescription
    let scanout: GraphicsScanoutResourceDescription
    let addressSpaces: GraphicsAddressSpaceRequirements

    func mmioResource(at index: Int) -> DeviceResource? {
        guard index >= 0, index < Self.maximumMMIOResourceCount else {
            return nil
        }
        switch (renderer, scanout, index) {
        case let (.v3dVII(registers), _, 0): return registers.hub
        case let (.v3dVII(registers), _, 1): return registers.core0
        case let (.v3dVII(registers), _, 2): return registers.sms
        case let (_, .hvs(registers), 3): return registers.registers
        default: return nil
        }
    }
}

struct Platform {
    static let physicalTimerInterruptID: UInt32 = 30
    private static let raspberryPi5DebugUART: UInt64 = 0x10_7d00_1000

    let kind: BoardKind
    let serial: DeviceResource
    let interruptController: InterruptControllerDescription
    let firmwareConfiguration: DeviceResource?
    let firmwareMailbox: DeviceResource?
    let usbDeviceController: USBDeviceControllerDescription?
    let simpleFramebuffer: SimpleFramebufferDescription?
    let graphicsResources: PlatformGraphicsResources?
    let virtioTransportWindow: DeviceResource?
    let firmwareCallConduit: FirmwareCallConduit?
    let deviceTreeAddress: UInt64
    let deviceTreeSize: UInt64

    /// Internal discovery view used by driver-specific Platform extensions.
    /// Guest code still receives typed descriptions rather than raw DT bytes.
    let deviceTree: FlattenedDeviceTree

    static func discover(deviceTreeAddress: UInt64) -> Platform? {
        guard let tree = FlattenedDeviceTree(address: deviceTreeAddress) else {
            return nil
        }

        let kind: BoardKind
        let firmwareConfiguration = tree.resource(
            compatibleWith: "qemu,fw-cfg-mmio"
        )
        if tree.contains(compatibleWith: "raspberrypi,5-model-b")
            && tree.contains(compatibleWith: "brcm,bcm2712") {
            kind = .raspberryPi5
        } else if firmwareConfiguration != nil {
            kind = .qemuVirt
        } else {
            return nil
        }

        let serial: DeviceResource?
        switch kind {
        case .qemuVirt:
            serial = tree.resource(compatibleWith: "arm,pl011")
        case .raspberryPi5:
            serial = raspberryPi5DebugSerial(in: tree)
        }
        guard let serial else { return nil }

        let interruptController: InterruptControllerDescription
        if let distributor = tree.resource(
            compatibleWith: "arm,gic-v3",
            registerIndex: 0
        ), let redistributor = tree.resource(
            compatibleWith: "arm,gic-v3",
            registerIndex: 1
        ) {
            interruptController = .gicV3(
                distributor: distributor,
                redistributor: redistributor
            )
        } else if let distributor = tree.resource(
            compatibleWith: "arm,gic-400",
            registerIndex: 0
        ), let cpuInterface = tree.resource(
            compatibleWith: "arm,gic-400",
            registerIndex: 1
        ) {
            interruptController = .gicV2(
                distributor: distributor,
                cpuInterface: cpuInterface
            )
        } else {
            return nil
        }

        let firmwareCallConduit: FirmwareCallConduit?
        if tree.contains(
            compatibleWith: "arm,psci-0.2",
            cStringProperty: "method",
            equalTo: "hvc"
        ) {
            firmwareCallConduit = .hypervisorCall
        } else if tree.contains(
            compatibleWith: "arm,psci-0.2",
            cStringProperty: "method",
            equalTo: "smc"
        ) {
            firmwareCallConduit = .secureMonitorCall
        } else {
            firmwareCallConduit = nil
        }

        let mailboxCandidate = tree.resource(
            compatibleWith: "brcm,bcm2835-mbox"
        )
        let firmwareMailbox: DeviceResource?
        if let mailboxCandidate, mailboxCandidate.length >= 0x40 {
            firmwareMailbox = mailboxCandidate
        } else {
            firmwareMailbox = nil
        }

        return Platform(
            kind: kind,
            serial: serial,
            interruptController: interruptController,
            firmwareConfiguration: firmwareConfiguration,
            firmwareMailbox: firmwareMailbox,
            usbDeviceController: kind == .raspberryPi5
                ? raspberryPi5USBDeviceController(in: tree)
                : nil,
            simpleFramebuffer: tree.simpleFramebuffer(),
            graphicsResources: kind == .raspberryPi5
                ? raspberryPi5GraphicsResources(in: tree)
                : nil,
            virtioTransportWindow: virtioTransportWindow(in: tree),
            firmwareCallConduit: firmwareCallConduit,
            deviceTreeAddress: deviceTreeAddress,
            deviceTreeSize: tree.blobSize,
            deviceTree: tree
        )
    }

    private static func raspberryPi5USBDeviceController(
        in tree: FlattenedDeviceTree
    ) -> USBDeviceControllerDescription? {
        // The firmware overlay chooses the USB-C controller's device role. An
        // older DT may omit dr_mode and leave role selection to the driver; if
        // firmware publishes it explicitly, never bind a host-mode controller.
        guard let registers = tree.resource(
                  compatibleWith: "brcm,bcm2835-usb"
              ), validMMIOResource(registers)
        else {
            return nil
        }

        if let roleQualifiedResource = tree.resource(
            compatibleWith: "brcm,bcm2835-usb",
            requiringProperty: "dr_mode"
        ) {
            guard roleQualifiedResource == registers,
                  tree.resource(
                      compatibleWith: "brcm,bcm2835-usb",
                      cStringProperty: "dr_mode",
                      equalTo: "peripheral"
                  ) == registers
            else {
                return nil
            }
        }

        return .dwc2(registers: registers)
    }

    private static func raspberryPi5GraphicsResources(
        in tree: FlattenedDeviceTree
    ) -> PlatformGraphicsResources? {
        // Register tuple order is part of the bcm2712 V3D binding: hub, core0,
        // then SMS. The FDT parser translates every tuple through its parent
        // ranges, so no SoC MMIO address is duplicated here.
        guard let hub = tree.resource(
                  compatibleWith: "brcm,2712-v3d",
                  registerIndex: 0
              ), let core0 = tree.resource(
                  compatibleWith: "brcm,2712-v3d",
                  registerIndex: 1
              ), let sms = tree.resource(
                  compatibleWith: "brcm,2712-v3d",
                  registerIndex: 2
              ), let hvs = tree.resource(
                  compatibleWith: "brcm,bcm2712-hvs",
                  requiringProperty: "iommus"
              ), validMMIOResource(hub),
              validMMIOResource(core0),
              validMMIOResource(sms),
              validMMIOResource(hvs),
              resourcesAreDisjoint(hub, core0),
              resourcesAreDisjoint(hub, sms),
              resourcesAreDisjoint(core0, sms),
              resourcesAreDisjoint(hub, hvs),
              resourcesAreDisjoint(core0, hvs),
              resourcesAreDisjoint(sms, hvs)
        else {
            return nil
        }

        return PlatformGraphicsResources(
            renderer: .v3dVII(
                V3DVIIRegisterResources(
                    hub: hub,
                    core0: core0,
                    sms: sms
                )
            ),
            scanout: .hvs(HVSRegisterResources(registers: hvs)),
            addressSpaces: GraphicsAddressSpaceRequirements(
                renderer: .deviceManaged,
                scanout: .platformIOMMU
            )
        )
    }

    private static func validMMIOResource(_ resource: DeviceResource) -> Bool {
        resource.length >= 4
            && resource.baseAddress & 0x3 == 0
            && resource.length <= UInt64.max - resource.baseAddress
    }

    private static func resourcesAreDisjoint(
        _ first: DeviceResource,
        _ second: DeviceResource
    ) -> Bool {
        first.baseAddress + first.length <= second.baseAddress
            || second.baseAddress + second.length <= first.baseAddress
    }

    private static func virtioTransportWindow(
        in tree: FlattenedDeviceTree
    ) -> DeviceResource? {
        let pageMask: UInt64 = 0xfff
        var minimumBase = UInt64.max
        var maximumEnd: UInt64 = 0
        var nodeIndex = 0
        var found = false
        while nodeIndex < 64,
              let resource = tree.resource(
                  compatibleWith: "virtio,mmio",
                  nodeIndex: nodeIndex
              ) {
            guard resource.length >= 0x100,
                  resource.length <= UInt64.max - resource.baseAddress,
                  resource.baseAddress + resource.length
                    <= UInt64.max - pageMask
            else {
                return nil
            }
            let alignedBase = resource.baseAddress & ~pageMask
            let alignedEnd = (resource.baseAddress + resource.length
                + pageMask) & ~pageMask
            if alignedBase < minimumBase { minimumBase = alignedBase }
            if alignedEnd > maximumEnd { maximumEnd = alignedEnd }
            found = true
            nodeIndex += 1
        }
        guard found,
              maximumEnd > minimumBase,
              maximumEnd - minimumBase <= 0x1_0000
        else {
            return nil
        }
        return DeviceResource(
            baseAddress: minimumBase,
            length: maximumEnd - minimumBase
        )
    }

    private static func raspberryPi5DebugSerial(
        in tree: FlattenedDeviceTree
    ) -> DeviceResource? {
        // The board DT enables UART10 for the dedicated debug connector. Until
        // alias/stdout-path resolution lands, require that exact translated DT
        // resource instead of silently binding Bluetooth or an RP1 PL011.
        var nodeIndex = 0
        while nodeIndex < 64,
              let candidate = tree.resource(
                  compatibleWith: "arm,pl011",
                  nodeIndex: nodeIndex
              ) {
            if candidate.baseAddress == raspberryPi5DebugUART,
               candidate.length >= 0x200 {
                return candidate
            }
            nodeIndex += 1
        }
        return nil
    }

    func memoryRegion(at index: Int) -> DeviceResource? {
        flattenedResource(at: index) { nodeIndex, registerIndex in
            deviceTree.resource(
                deviceType: "memory",
                nodeIndex: nodeIndex,
                registerIndex: registerIndex
            )
        }
    }

    func reservedMemoryRegion(at index: Int) -> DeviceResource? {
        flattenedResource(at: index) { nodeIndex, registerIndex in
            deviceTree.reservedMemoryResource(
                nodeIndex: nodeIndex,
                registerIndex: registerIndex
            )
        }
    }

    func firmwareReservation(at index: Int) -> DeviceResource? {
        deviceTree.firmwareReservation(at: index)
    }

    func processorAffinity(at index: Int) -> UInt64? {
        deviceTree.resource(deviceType: "cpu", nodeIndex: index)?.baseAddress
    }

    func containsSystemMemory(baseAddress: UInt64, length: UInt64) -> Bool {
        guard length > 0, length <= UInt64.max - baseAddress else {
            return false
        }
        let endAddress = baseAddress + length
        var index = 0
        while index < 4096, let resource = memoryRegion(at: index) {
            guard resource.length > 0,
                  resource.length <= UInt64.max - resource.baseAddress
            else {
                return false
            }
            if baseAddress >= resource.baseAddress,
               endAddress <= resource.baseAddress + resource.length {
                return true
            }
            index += 1
        }
        return false
    }

    func overlapsSystemMemory(baseAddress: UInt64, length: UInt64) -> Bool {
        guard length > 0, length <= UInt64.max - baseAddress else {
            return false
        }
        let endAddress = baseAddress + length
        var index = 0
        while index < 4096, let resource = memoryRegion(at: index) {
            guard resource.length > 0,
                  resource.length <= UInt64.max - resource.baseAddress
            else {
                return true
            }
            if baseAddress < resource.baseAddress + resource.length,
               resource.baseAddress < endAddress {
                return true
            }
            index += 1
        }
        return false
    }

    func virtioTransport(at index: Int) -> DeviceResource? {
        deviceTree.resource(
            compatibleWith: "virtio,mmio",
            nodeIndex: index
        )
    }

    func virtioTransportIsDMACoherent(at index: Int) -> Bool {
        guard let target = virtioTransport(at: index) else { return false }
        var coherentIndex = 0
        while coherentIndex < 64,
              let coherent = deviceTree.resource(
                  compatibleWith: "virtio,mmio",
                  nodeIndex: coherentIndex,
                  requiringProperty: "dma-coherent"
              ) {
            if coherent == target { return true }
            coherentIndex += 1
        }
        return false
    }

    var processorCount: Int {
        var count = 0
        while count < 64, processorAffinity(at: count) != nil {
            count += 1
        }
        return count
    }

    private func flattenedResource(
        at index: Int,
        lookup: (Int, Int) -> DeviceResource?
    ) -> DeviceResource? {
        guard index >= 0 else { return nil }
        var remaining = index
        var nodeIndex = 0
        while nodeIndex < 64 {
            var registerIndex = 0
            while registerIndex < 64,
                  let resource = lookup(nodeIndex, registerIndex) {
                if remaining == 0 { return resource }
                remaining -= 1
                registerIndex += 1
            }
            nodeIndex += 1
        }
        return nil
    }
}
