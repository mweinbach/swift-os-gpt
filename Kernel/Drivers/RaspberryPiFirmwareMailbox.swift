/// Volatile access to one already-discovered and identity-mapped firmware
/// mailbox aperture. No Raspberry Pi address is embedded in this adapter.
struct FirmwareMailboxMMIORegisterAccess: FirmwareMailboxRegisterAccess {
    private let baseAddress: UInt

    init?(resource: DeviceResource) {
        guard resource.length
                >= FirmwareMailboxRegisterLayout.minimumApertureLength,
              resource.baseAddress <= UInt64(UInt.max),
              resource.length <= UInt64.max - resource.baseAddress,
              resource.baseAddress + resource.length - 1
                <= UInt64(UInt.max)
        else {
            return nil
        }
        baseAddress = UInt(resource.baseAddress)
    }

    @inline(__always)
    mutating func read32(at offset: UInt) -> UInt32 {
        MMIO.load32(at: baseAddress + offset)
    }

    @inline(__always)
    mutating func write32(_ value: UInt32, at offset: UInt) {
        MMIO.store32(value, at: baseAddress + offset)
    }
}

struct AArch64FirmwareMailboxCacheMaintenance:
    FirmwareMailboxCacheMaintenance {
    mutating func clean(address: UInt64, byteCount: UInt64) -> Bool {
        AArch64.cleanDataCache(address: address, byteCount: byteCount)
    }

    mutating func invalidate(address: UInt64, byteCount: UInt64) -> Bool {
        AArch64.invalidateDataCache(address: address, byteCount: byteCount)
    }
}
