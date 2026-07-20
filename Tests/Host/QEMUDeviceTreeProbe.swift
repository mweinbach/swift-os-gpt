@_cdecl("swiftos_validate_qemu_fdt")
public func validateQEMUDeviceTree(_ rawAddress: UnsafeRawPointer?) -> Int32 {
    guard let rawAddress,
          let tree = FlattenedDeviceTree(
              address: UInt64(UInt(bitPattern: rawAddress))
          )
    else {
        return 1
    }
    guard tree.resource(compatibleWith: "arm,pl011")
            == DeviceResource(baseAddress: 0x0900_0000, length: 0x1000)
    else {
        return 2
    }
    guard tree.resource(compatibleWith: "qemu,fw-cfg-mmio")
            == DeviceResource(baseAddress: 0x0902_0000, length: 0x18)
    else {
        return 3
    }
    guard tree.resource(deviceType: "memory")
            == DeviceResource(baseAddress: 0x4000_0000, length: 0x2000_0000)
    else {
        return 4
    }
    guard let platform = Platform.discover(
        deviceTreeAddress: UInt64(UInt(bitPattern: rawAddress))
    )
    else {
        return 5
    }
    guard platform.kind == .qemuVirt else { return 7 }
    guard platform.processorCount == 1 else { return 8 }
    guard platform.processorAffinity(at: 0) == 0 else { return 9 }
    guard platform.firmwareCallConduit == .hypervisorCall else { return 10 }
    guard platform.nonSecurePhysicalTimerInterrupt == .privatePeripheral(
              number: 14,
              trigger: .levelHigh,
              processorMask: 0
          ), platform.nonSecurePhysicalTimerInterrupt?
              .architecturalInterruptID == 30,
          platform.nonSecurePhysicalTimerInterrupt?.deviceTreeFlags == 4
    else {
        return 14
    }
    guard platform.virtioTransportWindow == DeviceResource(
        baseAddress: 0x0a00_0000,
        length: 0x4000
    ) else {
        return 11
    }
    guard platform.virtioTransport(at: 0) != nil,
          platform.virtioTransport(at: 31) != nil,
          platform.virtioTransport(at: 32) == nil,
          platform.virtioTransportIsDMACoherent(at: 0),
          platform.virtioTransportIsDMACoherent(at: 31)
    else {
        return 12
    }
    guard platform.usbDeviceController == nil else { return 13 }
    guard case let .gicV3(distributor, redistributor) = platform.interruptController,
          distributor.baseAddress == 0x0800_0000,
          redistributor.baseAddress == 0x080a_0000
    else {
        return 6
    }
    return 0
}
