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
    return 0
}
