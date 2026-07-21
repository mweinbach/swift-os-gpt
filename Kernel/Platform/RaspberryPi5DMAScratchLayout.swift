/// Non-overlapping ownership within the linker-reserved Pi DMA scratch page.
/// DWC2 retains its prefix for the lifetime of the USB gadget; firmware
/// property calls use only the aligned tail and can therefore remain available
/// for a later transactional reboot.
enum RaspberryPi5DMAScratchLayout {
    static let pageByteCount: UInt64 = 4_096
    static let gadgetByteCount: UInt64 = 4_032
    static let firmwareMailboxOffset: UInt64 = gadgetByteCount
    static let firmwareMailboxByteCount: UInt64 = 64

    static func firmwareMailboxAddress(
        pageBaseAddress: UInt64
    ) -> UInt64? {
        guard pageBaseAddress & 0xfff == 0,
              pageBaseAddress <= UInt64.max - firmwareMailboxOffset
        else { return nil }
        let address = pageBaseAddress + firmwareMailboxOffset
        guard address & 0xf == 0,
              firmwareMailboxOffset + firmwareMailboxByteCount
                == pageByteCount
        else { return nil }
        return address
    }
}
