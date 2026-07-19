struct KernelMonitor {
    private static let lineStorageOffset: UInt = 7168
    private static let maximumLineLength = 127

    private var terminal: KernelTerminal
    private var display: ActiveDisplayBackend
    private let canvas: ScaledFramebufferCanvas
    private let serial: PL011
    private let boardKind: BoardKind
    private let mode: DisplayMode
    private var statusIndicator: AnimatedStatusIndicator?
    private var wroteAnimationFrameMarker = false
    private var wroteAnimationPeakMarker = false
    private var wroteUSBConfiguredMarker = false
    private var wroteUSBFrameMarker = false
    private var usbDebug: RaspberryPiUSBDebugGadget?
    private let lineStorageAddress: UInt
    private var lineLength = 0
    private var lastInputWasCarriageReturn = false

    init(
        canvas: ScaledFramebufferCanvas,
        display: ActiveDisplayBackend,
        boardKind: BoardKind,
        storageAddress: UInt64,
        serial: PL011,
        usbDebug: RaspberryPiUSBDebugGadget? = nil
    ) {
        terminal = KernelTerminal(
            canvas: canvas,
            storageAddress: storageAddress
        )
        self.canvas = canvas
        self.display = display
        self.boardKind = boardKind
        mode = display.mode
        statusIndicator = AnimatedStatusIndicator(
            logicalBounds: canvas.viewport.logicalBounds,
            counterFrequency: AArch64.counterFrequency,
            startingAt: AArch64.counterValue
        )
        self.serial = serial
        self.usbDebug = usbDebug
        lineStorageAddress = UInt(storageAddress) + Self.lineStorageOffset
    }

    mutating func start() -> Bool {
        terminal.clear()
        emit("SWIFTOS KERNEL MONITOR\n", color: KernelTerminal.cyan)
        switch boardKind {
        case .qemuVirt:
            emit("QEMU VIRT AARCH64  EMBEDDED SWIFT\n", color: KernelTerminal.muted)
        case .raspberryPi5:
            emit("RASPBERRY PI 5  EMBEDDED SWIFT\n", color: KernelTerminal.muted)
        }
        emit("TYPE HELP FOR COMMANDS\n\n", color: KernelTerminal.muted)
        prompt()
        guard statusIndicator?.renderInitial(on: canvas) == true,
              display.presentFullFrame()
        else {
            return false
        }
        usbDebug?.requestFullFrame()
        serialWrite("SWIFTOS:COMPOSITOR_READY\n")
        return true
    }

    mutating func run() -> Never {
        while true {
            serviceUSBDebug()
            guard let animationResult = statusIndicator?.renderIfDue(
                      counterTick: AArch64.counterValue,
                      on: canvas
                  )
            else {
                displayPanic()
            }
            switch animationResult {
            case .idle:
                break
            case .failed:
                displayPanic()
            case .rendered(let damage, _):
                guard let logicalDamage = damage.boundingRectangle else {
                    displayPanic()
                }
                // A valid logical layer can be completely cropped on a mode
                // smaller than the 800 x 600 desktop. Its retained state still
                // advances, but there is no physical damage to present.
                if let physicalDamage = canvas.damageRectangle(
                    for: logicalDamage,
                    mode: mode
                ) {
                    guard display.present(physicalDamage) else {
                        displayPanic()
                    }
                    usbDebug?.requestDamage(physicalDamage)
                }
                if !wroteAnimationFrameMarker {
                    serialWrite("SWIFTOS:ANIMATION_FRAME_OK\n")
                    wroteAnimationFrameMarker = true
                }
                if !wroteAnimationPeakMarker,
                   (statusIndicator?.currentOpacity ?? 0)
                    >= AnimatedStatusIndicator.peakMarkerOpacity {
                    serialWrite("SWIFTOS:ANIMATION_PEAK_OK\n")
                    wroteAnimationPeakMarker = true
                }
            }

            if let byte = serial.readByteIfAvailable() {
                let submittedCommand = handle(byte)
                guard display.presentFullFrame() else {
                    displayPanic()
                }
                usbDebug?.requestFullFrame()
                if submittedCommand && display.kind == .virtIOGPU {
                    serialWrite("SWIFTOS:DISPLAY_UPDATE_OK\n")
                }
            } else {
                AArch64.spinHint()
            }
        }
    }

    private mutating func serviceUSBDebug() {
        guard let event = usbDebug?.service() else { return }
        switch event {
        case .configured:
            if !wroteUSBConfiguredMarker {
                serialWrite(DWC2USBDebugGadget<DWC2MMIORegisterAccess>
                    .configuredMarker)
                wroteUSBConfiguredMarker = true
            }
        case .frameCompleted:
            if !wroteUSBFrameMarker {
                serialWrite(DWC2USBDebugGadget<DWC2MMIORegisterAccess>
                    .frameMarker)
                wroteUSBFrameMarker = true
            }
        case .faulted:
            serialWrite("SWIFTOS:USB_DEBUG_FAULT\n")
            usbDebug = nil
        case .none, .busReset, .enumerated, .deconfigured:
            break
        }
    }

    private func displayPanic() -> Never {
        serialWrite("SWIFTOS:PANIC:DISPLAY_PRESENT\n")
        while true { AArch64.waitForEvent() }
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
            emit("\nFRAMEBUFFER: ", color: KernelTerminal.muted)
            emitUnsigned(UInt64(mode.widthInPixels), color: KernelTerminal.green)
            emit("X", color: KernelTerminal.green)
            emitUnsigned(UInt64(mode.heightInPixels), color: KernelTerminal.green)
            switch mode.pixelFormat {
            case .b8g8r8x8:
                emit(" XRGB8888\n", color: KernelTerminal.green)
            case .b8g8r8a8:
                emit(" ARGB8888\n", color: KernelTerminal.green)
            }
            emit("REFRESH_MHZ: ", color: KernelTerminal.muted)
            if let refresh = mode.refreshRateMilliHertz {
                emitUnsigned(UInt64(refresh), color: KernelTerminal.green)
            } else {
                emit("UNKNOWN", color: KernelTerminal.yellow)
            }
            emit("\n")
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
        emit("SWIFT@HOST:~> ", color: KernelTerminal.cyan)
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
