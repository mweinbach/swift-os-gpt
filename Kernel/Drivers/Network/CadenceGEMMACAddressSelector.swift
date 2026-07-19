/// Selects the first usable hardware address without retaining firmware or
/// register-backed storage. Firmware owns the preferred address; station
/// address registers provide a bounded fallback when firmware leaves a
/// placeholder in the Device Tree.
enum CadenceGEMMACAddressSelector {
    private static let stationAddressCount = 4
    private static let stationAddressStride: UInt = 8

    static func select<Registers: CadenceGEMRegisterAccess>(
        firmwareAddress: PlatformMACAddressBytes?,
        registers: Registers
    ) -> MACAddress? {
        if let firmwareAddress {
            let address = MACAddress(
                firmwareAddress.byte0,
                firmwareAddress.byte1,
                firmwareAddress.byte2,
                firmwareAddress.byte3,
                firmwareAddress.byte4,
                firmwareAddress.byte5
            )
            if address.isUnicast {
                return address
            }
        }

        var index = 0
        while index < stationAddressCount {
            let offset = UInt(index) * stationAddressStride
            let bottom = registers.read32(
                at: CadenceGEMRegisterLayout.specificAddress1Bottom + offset
            )
            let top = registers.read32(
                at: CadenceGEMRegisterLayout.specificAddress1Top + offset
            )
            let address = MACAddress(
                UInt8(truncatingIfNeeded: bottom),
                UInt8(truncatingIfNeeded: bottom >> 8),
                UInt8(truncatingIfNeeded: bottom >> 16),
                UInt8(truncatingIfNeeded: bottom >> 24),
                UInt8(truncatingIfNeeded: top),
                UInt8(truncatingIfNeeded: top >> 8)
            )
            if address.isUnicast {
                return address
            }
            index += 1
        }
        return nil
    }
}
