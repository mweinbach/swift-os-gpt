private nonisolated(unsafe) var zeroProbe: UInt64 = 0
private nonisolated(unsafe) var dataProbe: UInt64 = 0x5357_4946_544f_5301

@_cdecl("swiftos_main")
func swiftOSMain(_ deviceTreeAddress: UInt64) {
    guard let platform = Platform.discover(
        deviceTreeAddress: deviceTreeAddress
    ), platform.serial.baseAddress <= UInt64(UInt.max),
       platform.serial.length >= 0x30
    else {
        park()
    }
    let console = EarlyConsole(
        uart: PL011(baseAddress: UInt(platform.serial.baseAddress))
    )

    console.write("SWIFTOS:BOOT\n")

    guard AArch64.currentExceptionLevel == 1 else {
        console.write("SWIFTOS:PANIC:BAD_EL\n")
        park()
    }
    console.write("SWIFTOS:EL1\n")

    guard zeroProbe == 0 else {
        console.write("SWIFTOS:PANIC:BSS\n")
        park()
    }
    zeroProbe = 0x4253_535f_4f4b
    guard zeroProbe == 0x4253_535f_4f4b else {
        console.write("SWIFTOS:PANIC:BSS_WRITE\n")
        park()
    }
    console.write("SWIFTOS:BSS_OK\n")

    guard dataProbe == 0x5357_4946_544f_5301 else {
        console.write("SWIFTOS:PANIC:DATA\n")
        park()
    }
    dataProbe &+= 1
    guard dataProbe == 0x5357_4946_544f_5302 else {
        console.write("SWIFTOS:PANIC:DATA_WRITE\n")
        park()
    }
    console.write("SWIFTOS:DATA_OK\n")

    guard AArch64.stackPointer & 0xf == 0 else {
        console.write("SWIFTOS:PANIC:STACK_ALIGNMENT\n")
        park()
    }
    guard AArch64.systemControl & 0x1005 == 0x1005 else {
        console.write("SWIFTOS:PANIC:MMU_CACHE\n")
        park()
    }

    console.write("SWIFTOS:DTB=")
    console.writeHex(deviceTreeAddress)
    console.write("\n")

    switch platform.kind {
    case .qemuVirt:
        guard platform.serial.baseAddress == 0x0900_0000,
              let firmware = platform.firmwareConfiguration,
              firmware.length >= 0x18
        else {
            console.write("SWIFTOS:PANIC:FDT\n")
            park()
        }
    case .raspberryPi5:
        guard platform.serial.baseAddress >= 0x1_0000_0000 else {
            console.write("SWIFTOS:PANIC:FDT\n")
            park()
        }
    }
    console.write("SWIFTOS:FDT_OK\n")

    guard InterruptSubsystem.exceptionVectorsInstalled else {
        console.write("SWIFTOS:PANIC:VECTORS\n")
        park()
    }
    console.write(InterruptSubsystem.exceptionsReadyMarker)

    guard InterruptSubsystem.configure(platform.interruptController) else {
        console.write("SWIFTOS:PANIC:GIC\n")
        park()
    }
    console.write(InterruptSubsystem.controllerReadyMarker)

    switch platform.kind {
    case .qemuVirt:
        runQEMUDesktop(console: console, platform: platform)
    case .raspberryPi5:
        console.write("SWIFTOS:SERIAL_ONLY\n")
        proveTimerInterrupts(console: console)
        console.write("SWIFTOS:SWIFT_OK\n")
        console.write("SWIFTOS:READY\n")
        park()
    }
}

private func runQEMUDesktop(console: EarlyConsole, platform: Platform) -> Never {
    guard let firmwareConfiguration = platform.firmwareConfiguration else {
        console.write("SWIFTOS:PANIC:FW_CFG\n")
        park()
    }
    let framebuffer = LinearFramebuffer(
        baseAddress: UInt(AArch64.framebufferAddress),
        width: RamFramebuffer.width,
        height: RamFramebuffer.height,
        strideInPixels: RamFramebuffer.stride / RamFramebuffer.bytesPerPixel
    )
    DesktopRenderer.render(into: framebuffer)
    var monitor = KernelMonitor(
        framebuffer: framebuffer,
        storageAddress: AArch64.terminalStorageAddress,
        serial: PL011(baseAddress: UInt(platform.serial.baseAddress))
    )
    monitor.start()
    let firmware = FirmwareConfiguration(
        baseAddress: firmwareConfiguration.baseAddress
    )
    guard RamFramebuffer.publish(using: firmware) else {
        console.write("SWIFTOS:PANIC:RAMFB\n")
        park()
    }
    console.write("SWIFTOS:RAMFB_OK\n")
    console.write("SWIFTOS:FRAMEBUFFER_READY\n")
    console.write("SWIFTOS:SWIFT_OK\n")

    proveTimerInterrupts(console: console)
    console.write("SWIFTOS:READY\n")
    monitor.run()
}

private func proveTimerInterrupts(console: EarlyConsole) {
    let frequency = AArch64.counterFrequency
    guard frequency > 0 else {
        console.write("SWIFTOS:PANIC:TIMER_FREQUENCY\n")
        park()
    }
    let period = frequency / 100
    guard period > 0,
          InterruptSubsystem.startPhysicalTimer(periodTicks: period)
    else {
        console.write("SWIFTOS:PANIC:TIMER_START\n")
        park()
    }

    console.write(InterruptSubsystem.timerInterruptMarker)
    var reported: UInt64 = 0
    while reported < 3 {
        let delivered = InterruptSubsystem.timerInterruptCount
        while reported < delivered, reported < 3 {
            reported += 1
            switch reported {
            case 1: console.write("SWIFTOS:TIMER_1\n")
            case 2: console.write("SWIFTOS:TIMER_2\n")
            default: console.write("SWIFTOS:TIMER_3\n")
            }
        }
        if reported < 3 { AArch64.waitForInterrupt() }
    }
}

private func park() -> Never {
    while true {
        AArch64.waitForEvent()
    }
}
