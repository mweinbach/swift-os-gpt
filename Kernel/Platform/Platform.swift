enum BoardKind: UInt8, Equatable {
    case qemuVirt
    case raspberryPi5
}

enum InterruptControllerDescription: Equatable {
    case gicV2(distributor: DeviceResource, cpuInterface: DeviceResource)
    case gicV3(distributor: DeviceResource, redistributor: DeviceResource)
}

struct Platform {
    static let physicalTimerInterruptID: UInt32 = 30

    let kind: BoardKind
    let serial: DeviceResource
    let interruptController: InterruptControllerDescription
    let firmwareConfiguration: DeviceResource?
    let deviceTreeAddress: UInt64
    let deviceTreeSize: UInt64

    private let deviceTree: FlattenedDeviceTree

    static func discover(deviceTreeAddress: UInt64) -> Platform? {
        guard let tree = FlattenedDeviceTree(address: deviceTreeAddress),
              let serial = tree.resource(compatibleWith: "arm,pl011")
        else {
            return nil
        }

        let kind: BoardKind
        let firmwareConfiguration = tree.resource(
            compatibleWith: "qemu,fw-cfg-mmio"
        )
        if tree.contains(compatibleWith: "raspberrypi,5-model-b")
            || tree.contains(compatibleWith: "brcm,bcm2712") {
            kind = .raspberryPi5
        } else if firmwareConfiguration != nil {
            kind = .qemuVirt
        } else {
            return nil
        }

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

        return Platform(
            kind: kind,
            serial: serial,
            interruptController: interruptController,
            firmwareConfiguration: firmwareConfiguration,
            deviceTreeAddress: deviceTreeAddress,
            deviceTreeSize: tree.blobSize,
            deviceTree: tree
        )
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
