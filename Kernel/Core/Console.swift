struct EarlyConsole {
    private let uart: PL011

    init(uart: PL011) {
        self.uart = uart
    }

    func write(_ text: StaticString) {
        text.withUTF8Buffer { bytes in
            for byte in bytes {
                if byte == 10 {
                    uart.write(byte: 13)
                }
                uart.write(byte: byte)
            }
        }
    }

    func writeHex(_ value: UInt64) {
        write("0x")
        var shift = 60
        while shift >= 0 {
            let nibble = UInt8(truncatingIfNeeded: value >> UInt64(shift)) & 0xf
            uart.write(byte: nibble < 10 ? 48 + nibble : 87 + nibble)
            shift -= 4
        }
    }
}

