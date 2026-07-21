struct BCM2712PMWatchdogMMIORegisterAccess:
    BCM2712PMWatchdogRegisterAccess {
    private let baseAddress: UInt

    init?(resource: DeviceResource) {
        guard resource.baseAddress <= UInt64(UInt.max),
              resource.baseAddress & 0x3 == 0,
              resource.length >= 0x28,
              resource.length <= UInt64.max - resource.baseAddress
        else { return nil }
        baseAddress = UInt(resource.baseAddress)
    }

    mutating func read32(at offset: UInt) -> UInt32 {
        MMIO.load32(at: baseAddress + offset)
    }

    mutating func write32(_ value: UInt32, at offset: UInt) {
        MMIO.store32(value, at: baseAddress + offset)
    }
}
