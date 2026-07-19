@_cdecl("swiftos_validate_rpi5_fdt")
public func validateRaspberryPi5DeviceTree(
    _ rawAddress: UnsafeRawPointer?
) -> Int32 {
    guard let rawAddress,
          let tree = FlattenedDeviceTree(
              address: UInt64(UInt(bitPattern: rawAddress))
          )
    else {
        return 1
    }
    guard tree.contains(compatibleWith: "raspberrypi,5-model-b") else {
        return 2
    }
    var uart10: DeviceResource?
    var serialIndex = 0
    while serialIndex < 64,
          let candidate = tree.resource(
              compatibleWith: "arm,pl011",
              nodeIndex: serialIndex
          ) {
        if candidate.baseAddress == 0x10_7d00_1000 {
            uart10 = candidate
            break
        }
        serialIndex += 1
    }
    guard uart10 != nil else { return 3 }
    guard tree.resource(
        compatibleWith: "arm,gic-400",
        registerIndex: 0
    )?.baseAddress == 0x10_7fff_9000 else {
        return 4
    }
    guard tree.contains(
        compatibleWith: "arm,psci-0.2",
        cStringProperty: "method",
        equalTo: "smc"
    ) else {
        return 5
    }
    guard let platform = Platform.discover(
        deviceTreeAddress: UInt64(UInt(bitPattern: rawAddress))
    ) else {
        return 6
    }
    guard platform.kind == .raspberryPi5 else { return 7 }
    guard platform.serial == DeviceResource(
        baseAddress: 0x10_7d00_1000,
        length: 0x200
    ) else {
        return 8
    }
    guard case let .gicV2(distributor, cpuInterface)
            = platform.interruptController,
          distributor == DeviceResource(
              baseAddress: 0x10_7fff_9000,
              length: 0x1000
          ),
          cpuInterface == DeviceResource(
              baseAddress: 0x10_7fff_a000,
              length: 0x2000
          )
    else {
        return 9
    }
    guard platform.firmwareCallConduit == .secureMonitorCall else {
        return 10
    }
    guard platform.processorCount == 4,
          platform.processorAffinity(at: 0) == 0,
          platform.processorAffinity(at: 1) == 0x100,
          platform.processorAffinity(at: 2) == 0x200,
          platform.processorAffinity(at: 3) == 0x300
    else {
        return 11
    }
    guard let memory = platform.memoryRegion(at: 0),
          memory.baseAddress == 0,
          memory.length > 0
    else {
        return 12
    }
    guard platform.reservedMemoryRegion(at: 0) == DeviceResource(
        baseAddress: 0,
        length: 0x80000
    ) else {
        return 13
    }
    let expectedMailbox = DeviceResource(
        baseAddress: 0x10_7c01_3880,
        length: 0x40
    )
    guard tree.resource(
        compatibleWith: "brcm,bcm2835-mbox"
    ) == expectedMailbox else {
        return 14
    }
    guard platform.firmwareMailbox == expectedMailbox else {
        return 15
    }
    guard tree.resource(
        compatibleWith: "raspberrypi,rp1-gem"
    ) == DeviceResource(
        baseAddress: 0x1f_0010_0000,
        length: 0x4000
    ) else {
        return 16
    }
    return 0
}

@_cdecl("swiftos_rpi5_pl011_base")
public func raspberryPi5PL011Base(
    _ rawAddress: UnsafeRawPointer?,
    _ nodeIndex: Int32
) -> UInt64 {
    guard let rawAddress,
          nodeIndex >= 0,
          let tree = FlattenedDeviceTree(
              address: UInt64(UInt(bitPattern: rawAddress))
          )
    else {
        return UInt64.max
    }
    return tree.resource(
        compatibleWith: "arm,pl011",
        nodeIndex: Int(nodeIndex)
    )?.baseAddress ?? UInt64.max
}
