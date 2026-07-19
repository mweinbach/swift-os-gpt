struct PL011 {
    private let baseAddress: UInt

    private static let dataOffset: UInt = 0x00
    private static let flagOffset: UInt = 0x18
    private static let transmitFIFOFull: UInt32 = 1 << 5
    private static let receiveFIFOEmpty: UInt32 = 1 << 4

    init(baseAddress: UInt) {
        self.baseAddress = baseAddress
    }

    @discardableResult
    func write(byte: UInt8) -> Bool {
        var registers = PL011MMIOTransmitRegisterAccess(
            baseAddress: baseAddress,
            dataOffset: Self.dataOffset,
            flagOffset: Self.flagOffset
        )
        return transmitPL011Byte(
            byte,
            registers: &registers,
            transmitFIFOFullMask: Self.transmitFIFOFull
        )
    }

    func readByteIfAvailable() -> UInt8? {
        if MMIO.load32(at: baseAddress + Self.flagOffset)
            & Self.receiveFIFOEmpty != 0 {
            return nil
        }
        return UInt8(truncatingIfNeeded: MMIO.load32(at: baseAddress + Self.dataOffset))
    }
}

private struct PL011MMIOTransmitRegisterAccess:
    PL011TransmitRegisterAccess {
    let baseAddress: UInt
    let dataOffset: UInt
    let flagOffset: UInt

    mutating func readTransmitFlags() -> UInt32 {
        MMIO.load32(at: baseAddress + flagOffset)
    }

    mutating func writeTransmitData(_ byte: UInt8) {
        MMIO.store8(byte, at: baseAddress + dataOffset)
    }

    mutating func relaxTransmitPoll() {
        AArch64.spinHint()
    }
}
