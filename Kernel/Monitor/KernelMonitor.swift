struct KernelMonitor {
    private static let lineStorageOffset: UInt = 7168
    private static let maximumLineLength = 127

    private var terminal: KernelTerminal
    private var display: ActiveDisplayBackend
    private let serial: PL011
    private let lineStorageAddress: UInt
    private var lineLength = 0
    private var lastInputWasCarriageReturn = false

    init(
        framebuffer: LinearFramebuffer,
        display: ActiveDisplayBackend,
        storageAddress: UInt64,
        serial: PL011
    ) {
        terminal = KernelTerminal(
            framebuffer: framebuffer,
            storageAddress: storageAddress
        )
        self.display = display
        self.serial = serial
        lineStorageAddress = UInt(storageAddress) + Self.lineStorageOffset
    }

    mutating func start() -> Bool {
        terminal.clear()
        emit("SWIFTOS KERNEL MONITOR\n", color: KernelTerminal.cyan)
        emit("QEMU VIRT AARCH64  EMBEDDED SWIFT\n", color: KernelTerminal.muted)
        emit("TYPE HELP FOR COMMANDS\n\n", color: KernelTerminal.muted)
        prompt()
        return display.presentFullFrame()
    }

    mutating func run() -> Never {
        while true {
            if let byte = serial.readByteIfAvailable() {
                let submittedCommand = handle(byte)
                guard display.presentFullFrame() else {
                    serialWrite("SWIFTOS:PANIC:DISPLAY_PRESENT\n")
                    while true { AArch64.waitForEvent() }
                }
                if submittedCommand && display.kind == .virtIOGPU {
                    serialWrite("SWIFTOS:DISPLAY_UPDATE_OK\n")
                }
            } else {
                AArch64.spinHint()
            }
        }
    }

    private mutating func handle(_ byte: UInt8) -> Bool {
        if byte == 13 {
            lastInputWasCarriageReturn = true
            submitLine()
            return true
        }
        if byte == 10 {
            if lastInputWasCarriageReturn {
                lastInputWasCarriageReturn = false
                return false
            }
            submitLine()
            return true
        }
        lastInputWasCarriageReturn = false

        if byte == 8 || byte == 127 {
            guard lineLength > 0 else { return false }
            lineLength -= 1
            terminal.backspace()
            serial.write(byte: 8)
            serial.write(byte: 32)
            serial.write(byte: 8)
            return false
        }

        guard byte >= 32,
              byte <= 126,
              lineLength < Self.maximumLineLength,
              let line = linePointer
        else {
            return false
        }
        line[lineLength] = byte
        lineLength += 1
        terminal.write(byte: byte, color: KernelTerminal.cyan)
        serial.write(byte: byte)
        return false
    }

    private mutating func submitLine() {
        emit("\n")
        executeCurrentLine()
        lineLength = 0
        prompt()
    }

    private mutating func executeCurrentLine() {
        guard let line = linePointer else {
            emit("MONITOR STORAGE UNAVAILABLE\n", color: KernelTerminal.red)
            return
        }
        let command = MonitorCommand.parse(
            UnsafeBufferPointer(start: line, count: lineLength)
        )

        switch command {
        case .empty:
            return

        case .help:
            emit("COMMANDS: HELP UNAME STATUS CLEAR ABOUT UPTIME\n")

        case .uname:
            emit("SWIFTOS 0.1 AARCH64 EMBEDDED-SWIFT\n", color: KernelTerminal.green)

        case .status:
            emit("EL: ", color: KernelTerminal.muted)
            emitUnsigned(AArch64.currentExceptionLevel, color: KernelTerminal.white)
            emit("\nSCTLR: ", color: KernelTerminal.muted)
            emitHex(AArch64.systemControl, color: KernelTerminal.white)
            emit("\nFRAMEBUFFER: 800X600 XRGB8888\n", color: KernelTerminal.green)
            emit("DEVICE TREE: DISCOVERED\n", color: KernelTerminal.green)

        case .clear:
            terminal.clear()
            serialWrite("[SCREEN CLEARED]\n")

        case .about:
            emit("KERNEL POLICY DRIVERS RENDERER MONITOR IN SWIFT\n")
            emit("NO DARWIN OR APPLE FRAMEWORKS UNDER THIS MONITOR\n", color: KernelTerminal.muted)

        case .uptime:
            let frequency = AArch64.counterFrequency
            emit("SECONDS: ", color: KernelTerminal.muted)
            emitUnsigned(
                frequency == 0 ? 0 : AArch64.counterValue / frequency,
                color: KernelTerminal.white
            )
            emit("\n")

        case .unknown:
            emit("COMMAND NOT FOUND: ", color: KernelTerminal.red)
            var index = 0
            while index < lineLength {
                emitByte(line[index], color: KernelTerminal.red)
                index += 1
            }
            emit("\n")
        }
    }

    private mutating func prompt() {
        emit("SWIFT@QEMU:~> ", color: KernelTerminal.cyan)
    }

    private mutating func emit(
        _ text: StaticString,
        color: UInt8 = KernelTerminal.white
    ) {
        terminal.write(text, color: color)
        serialWrite(text)
    }

    private mutating func emitByte(_ byte: UInt8, color: UInt8) {
        terminal.write(byte: byte, color: color)
        serial.write(byte: byte)
    }

    private mutating func emitUnsigned(_ value: UInt64, color: UInt8) {
        terminal.writeUnsigned(value, color: color)
        serialWriteUnsigned(value)
    }

    private mutating func emitHex(_ value: UInt64, color: UInt8) {
        terminal.writeHex(value, color: color)
        serialWrite("0X")
        var shift = 60
        while shift >= 0 {
            let nibble = UInt8(truncatingIfNeeded: value >> UInt64(shift)) & 0xf
            serial.write(byte: nibble < 10 ? 48 + nibble : 55 + nibble)
            shift -= 4
        }
    }

    private func serialWrite(_ text: StaticString) {
        text.withUTF8Buffer { bytes in
            for byte in bytes {
                if byte == 10 {
                    serial.write(byte: 13)
                }
                serial.write(byte: byte)
            }
        }
    }

    private func serialWriteUnsigned(_ value: UInt64) {
        if value >= 10 {
            serialWriteUnsigned(value / 10)
        }
        serial.write(byte: 48 + UInt8(value % 10))
    }

    private var linePointer: UnsafeMutablePointer<UInt8>? {
        UnsafeMutableRawPointer(bitPattern: lineStorageAddress)?
            .assumingMemoryBound(to: UInt8.self)
    }
}
