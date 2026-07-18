struct PL011 {
    private let baseAddress: UInt

    private static let dataOffset: UInt = 0x00
    private static let flagOffset: UInt = 0x18
    private static let transmitFIFOFull: UInt32 = 1 << 5
    private static let receiveFIFOEmpty: UInt32 = 1 << 4

    init(baseAddress: UInt) {
        self.baseAddress = baseAddress
    }

    func write(byte: UInt8) {
        while MMIO.load32(at: baseAddress + Self.flagOffset)
            & Self.transmitFIFOFull != 0 {}
        MMIO.store8(byte, at: baseAddress + Self.dataOffset)
    }

    func readByteIfAvailable() -> UInt8? {
        if MMIO.load32(at: baseAddress + Self.flagOffset)
            & Self.receiveFIFOEmpty != 0 {
            return nil
        }
        return UInt8(truncatingIfNeeded: MMIO.load32(at: baseAddress + Self.dataOffset))
    }
}
