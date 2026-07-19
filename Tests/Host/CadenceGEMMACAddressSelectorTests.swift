#if CADENCE_GEM_MAC_SELECTOR_STANDALONE_TEST
/// Shape-compatible stand-in used only when this focused test is compiled
/// without the platform discovery module.
struct PlatformMACAddressBytes: Equatable {
    let byte0: UInt8
    let byte1: UInt8
    let byte2: UInt8
    let byte3: UInt8
    let byte4: UInt8
    let byte5: UInt8
}
#endif

private final class MACSelectionRegisters: CadenceGEMRegisterAccess {
    private var words = [UInt: UInt32]()
    private(set) var reads = [UInt]()

    func setStationAddress(
        slot: Int,
        bottom: UInt32,
        top: UInt32
    ) {
        let offset = UInt(slot) * 8
        words[CadenceGEMRegisterLayout.specificAddress1Bottom + offset] = bottom
        words[CadenceGEMRegisterLayout.specificAddress1Top + offset] = top
    }

    func read32(at offset: UInt) -> UInt32 {
        reads.append(offset)
        return words[offset, default: 0]
    }

    func write32(_ value: UInt32, at offset: UInt) {
        words[offset] = value
    }

    func counterValue() -> UInt64 { 0 }

    func spinWaitHint() {}
}

@main
struct CadenceGEMMACAddressSelectorTests {
    static func main() {
        prefersUsableFirmwareAddressWithoutReadingHardware()
        fallsBackWhenFirmwareAddressIsNotUsable()
        decodesStationAddressRegisterByteOrder()
        returnsFirstUsableStationAddressAcrossAllFourSlots()
        rejectsAnEntirelyInvalidAddressSet()
        print("Cadence GEM MAC address selector: 5 groups passed")
    }

    private static func prefersUsableFirmwareAddressWithoutReadingHardware() {
        let registers = MACSelectionRegisters()
        registers.setStationAddress(
            slot: 0,
            bottom: 0x4433_2210,
            top: 0x0000_6655
        )
        let firmware = PlatformMACAddressBytes(
            byte0: 0x02,
            byte1: 0x11,
            byte2: 0x22,
            byte3: 0x33,
            byte4: 0x44,
            byte5: 0x55
        )

        expect(
            CadenceGEMMACAddressSelector.select(
                firmwareAddress: firmware,
                registers: registers
            ) == MACAddress(0x02, 0x11, 0x22, 0x33, 0x44, 0x55),
            "usable firmware address was not preferred"
        )
        expect(
            registers.reads.isEmpty,
            "hardware registers were read despite usable firmware address"
        )
    }

    private static func fallsBackWhenFirmwareAddressIsNotUsable() {
        let multicastFirmware = PlatformMACAddressBytes(
            byte0: 0x01,
            byte1: 0,
            byte2: 0,
            byte3: 0,
            byte4: 0,
            byte5: 1
        )
        let multicastRegisters = MACSelectionRegisters()
        multicastRegisters.setStationAddress(
            slot: 0,
            bottom: 0x3322_1102,
            top: 0x0000_5544
        )
        expect(
            CadenceGEMMACAddressSelector.select(
                firmwareAddress: multicastFirmware,
                registers: multicastRegisters
            ) == MACAddress(0x02, 0x11, 0x22, 0x33, 0x44, 0x55),
            "multicast firmware address prevented register fallback"
        )

        let zeroFirmware = PlatformMACAddressBytes(
            byte0: 0,
            byte1: 0,
            byte2: 0,
            byte3: 0,
            byte4: 0,
            byte5: 0
        )
        let zeroRegisters = MACSelectionRegisters()
        zeroRegisters.setStationAddress(
            slot: 0,
            bottom: 0x7654_3202,
            top: 0x0000_ba98
        )
        expect(
            CadenceGEMMACAddressSelector.select(
                firmwareAddress: zeroFirmware,
                registers: zeroRegisters
            ) == MACAddress(0x02, 0x32, 0x54, 0x76, 0x98, 0xba),
            "zero firmware placeholder prevented register fallback"
        )
    }

    private static func decodesStationAddressRegisterByteOrder() {
        let registers = MACSelectionRegisters()
        registers.setStationAddress(
            slot: 0,
            bottom: 0xa976_4212,
            top: 0xcafe_d0bc
        )

        expect(
            CadenceGEMMACAddressSelector.select(
                firmwareAddress: nil,
                registers: registers
            ) == MACAddress(0x12, 0x42, 0x76, 0xa9, 0xbc, 0xd0),
            "station register octets were not decoded least-significant first"
        )
    }

    private static func returnsFirstUsableStationAddressAcrossAllFourSlots() {
        let registers = MACSelectionRegisters()
        registers.setStationAddress(slot: 0, bottom: 0, top: 0)
        registers.setStationAddress(
            slot: 1,
            bottom: 0x0300_0001,
            top: 0x0000_0004
        )
        registers.setStationAddress(
            slot: 2,
            bottom: 0xffff_ffff,
            top: 0xffff_ffff
        )
        registers.setStationAddress(
            slot: 3,
            bottom: 0x6745_2302,
            top: 0xabcd_ab89
        )

        expect(
            CadenceGEMMACAddressSelector.select(
                firmwareAddress: nil,
                registers: registers
            ) == MACAddress(0x02, 0x23, 0x45, 0x67, 0x89, 0xab),
            "fourth station address was not selected after invalid slots"
        )
        expect(
            registers.reads == [
                0x088, 0x08c,
                0x090, 0x094,
                0x098, 0x09c,
                0x0a0, 0x0a4,
            ],
            "station register scan exceeded or skipped the four-slot bound"
        )
    }

    private static func rejectsAnEntirelyInvalidAddressSet() {
        let registers = MACSelectionRegisters()
        registers.setStationAddress(slot: 0, bottom: 0, top: 0)
        registers.setStationAddress(
            slot: 1,
            bottom: 0x0000_0001,
            top: 0
        )
        registers.setStationAddress(
            slot: 2,
            bottom: 0xffff_ffff,
            top: 0xffff_ffff
        )
        registers.setStationAddress(
            slot: 3,
            bottom: 0x7856_3403,
            top: 0x0000_bc9a
        )

        expect(
            CadenceGEMMACAddressSelector.select(
                firmwareAddress: nil,
                registers: registers
            ) == nil,
            "zero or multicast station address was accepted"
        )
        expect(registers.reads.count == 8, "invalid scan did not remain bounded")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("\(message)")
    }
}
