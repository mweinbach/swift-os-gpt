struct EarlyConsole {
    private let uart: PL011

    init(uart: PL011) {
        self.uart = uart
    }

    func write(_ text: StaticString) {
        KernelDebugLogRuntime.write(
            text,
            to: uart,
            source: .earlyConsole
        )
    }

    func writeHex(_ value: UInt64) {
        write("0x")
        var shift = 60
        while shift >= 0 {
            let nibble = UInt8(truncatingIfNeeded: value >> UInt64(shift)) & 0xf
            let byte = nibble < 10 ? 48 + nibble : 87 + nibble
            KernelDebugLogRuntime.write(
                byte: byte,
                to: uart,
                source: .earlyConsole
            )
            shift -= 4
        }
    }
}
