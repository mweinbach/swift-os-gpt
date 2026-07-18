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

    guard let drivers = PlatformDriverBootstrap.discover(
              platform: platform
          )
    else {
        console.write("SWIFTOS:PANIC:DRIVER_RESOURCES\n")
        park()
    }

    guard let memory = KernelMemoryRuntime.activate(
        platform: platform,
        console: console,
        driverResources: drivers.resources
    ) else {
        console.write("SWIFTOS:PANIC:MEMORY\n")
        park()
    }

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
        runQEMUDesktop(
            console: console,
            platform: platform,
            memory: memory
        )
    case .raspberryPi5:
        if let display = drivers.display {
            console.write(SimpleFramebufferDisplayDriver.readyMarker)
            runPlatformDesktop(
                console: console,
                platform: platform,
                memory: memory,
                driver: display
            )
        }
        console.write("SWIFTOS:SERIAL_ONLY\n")
        console.write("SWIFTOS:SWIFT_OK\n")
        proveTimerInterrupts(console: console)
        runScheduledOrPark(
            console: console,
            platform: platform,
            memory: memory
        )
    }
}

private func runQEMUDesktop(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation
) -> Never {
    guard let firmwareConfiguration = platform.firmwareConfiguration else {
        console.write("SWIFTOS:PANIC:FW_CFG\n")
        park()
    }
    guard let mode = DisplayMode(
              widthInPixels: UInt32(RamFramebuffer.width),
              heightInPixels: UInt32(RamFramebuffer.height),
              refreshRateMilliHertz: 60_000,
              pixelFormat: .xrgb8888
          ),
          let framebufferMapping = DMAMapping(
              cpuPhysicalAddress: AArch64.framebufferAddress,
              deviceAddress: AArch64.framebufferAddress,
              byteCount: mode.minimumByteCount,
              deviceAddressWidth: .bits64,
              coherency: .hardwareCoherent
          ),
          let scanout = ScanoutBuffer(
              mode: mode,
              bytesPerRow: UInt64(RamFramebuffer.stride),
              mapping: framebufferMapping
          ),
          scanout.mapping.cpuPhysicalAddress <= UInt64(UInt.max)
    else {
        console.write("SWIFTOS:PANIC:DISPLAY_MEMORY\n")
        park()
    }
    let firmware = FirmwareConfiguration(
        baseAddress: firmwareConfiguration.baseAddress
    )
    guard let display = activateQEMUDisplay(
              policy: .automatic,
              platform: platform,
              firmware: firmware,
              scanout: scanout
          )
    else {
        console.write("SWIFTOS:PANIC:DISPLAY_BACKEND\n")
        park()
    }
    runDesktopSession(
        console: console,
        platform: platform,
        memory: memory,
        scanout: scanout,
        display: display
    )
}

private func runPlatformDesktop(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation,
    driver: SimpleFramebufferDisplayDriver
) -> Never {
    runDesktopSession(
        console: console,
        platform: platform,
        memory: memory,
        scanout: driver.scanout,
        display: .platformFramebuffer(
            mode: driver.scanout.mode,
            driver: driver
        )
    )
}

private func runDesktopSession(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation,
    scanout: ScanoutBuffer,
    display initialDisplay: ActiveDisplayBackend
) -> Never {
    let mode = scanout.mode
    let strideInPixels = scanout.bytesPerRow
        / mode.pixelFormat.bytesPerPixel
    guard scanout.mapping.cpuPhysicalAddress <= UInt64(UInt.max),
          strideInPixels <= UInt64(Int.max)
    else {
        console.write("SWIFTOS:PANIC:DISPLAY_MEMORY\n")
        park()
    }
    let framebuffer = LinearFramebuffer(
        baseAddress: UInt(scanout.mapping.cpuPhysicalAddress),
        width: Int(mode.widthInPixels),
        height: Int(mode.heightInPixels),
        strideInPixels: Int(strideInPixels),
        pixelFormat: mode.pixelFormat
    )
    guard let viewport = DisplayViewport(mode: mode),
          let canvas = ScaledFramebufferCanvas(
              framebuffer: framebuffer,
              viewport: viewport
          )
    else {
        console.write("SWIFTOS:PANIC:DISPLAY_VIEWPORT\n")
        park()
    }
    DesktopRenderer.render(on: canvas)
    let display = initialDisplay
    let displayKind = display.kind
    var monitor = KernelMonitor(
        canvas: canvas,
        display: display,
        boardKind: platform.kind,
        storageAddress: AArch64.terminalStorageAddress,
        serial: PL011(baseAddress: UInt(platform.serial.baseAddress))
    )
    guard monitor.start() else {
        console.write("SWIFTOS:PANIC:DISPLAY_PRESENT\n")
        park()
    }
    switch displayKind {
    case .virtIOGPU:
        console.write(VirtIOGPU.transportReadyMarker)
        console.write(VirtIOGPU.readyMarker)
    case .firmwareRAMFramebuffer:
        console.write("SWIFTOS:RAMFB_OK\n")
    case .platformFramebuffer:
        console.write("SWIFTOS:PLATFORM_FB_OK\n")
    }
    console.write("SWIFTOS:FRAMEBUFFER_READY\n")
    console.write("SWIFTOS:SWIFT_OK\n")

    proveTimerInterrupts(console: console)
    if platform.processorCount > 1 {
        runScheduledOrPark(
            console: console,
            platform: platform,
            memory: memory
        )
    }
    console.write("SWIFTOS:READY\n")
    monitor.run()
}

private func activateQEMUDisplay(
    policy: DisplayBackendSelectionPolicy,
    platform: Platform,
    firmware: FirmwareConfiguration,
    scanout: ScanoutBuffer
) -> ActiveDisplayBackend? {
    let gpuPriority = policy.priority(for: .virtIOGPU)
    let ramPriority = policy.priority(for: .firmwareRAMFramebuffer)

    if let gpuPriority, let ramPriority {
        if gpuPriority <= ramPriority {
            return activateVirtIOGPU(platform: platform, scanout: scanout)
                ?? activateRAMFramebuffer(firmware: firmware, mode: scanout.mode)
        }
        return activateRAMFramebuffer(firmware: firmware, mode: scanout.mode)
            ?? activateVirtIOGPU(platform: platform, scanout: scanout)
    }
    if gpuPriority != nil {
        return activateVirtIOGPU(platform: platform, scanout: scanout)
    }
    if ramPriority != nil {
        return activateRAMFramebuffer(firmware: firmware, mode: scanout.mode)
    }
    return nil
}

private func activateRAMFramebuffer(
    firmware: FirmwareConfiguration,
    mode: DisplayMode
) -> ActiveDisplayBackend? {
    guard RamFramebuffer.publish(using: firmware) else { return nil }
    return .firmwareRAMFramebuffer(mode: mode)
}

private func activateVirtIOGPU(
    platform: Platform,
    scanout: ScanoutBuffer
) -> ActiveDisplayBackend? {
    guard let queueMapping = DMAMapping(
        cpuPhysicalAddress: AArch64.dmaScratchAddress,
        deviceAddress: AArch64.dmaScratchAddress,
        byteCount: 4096,
        deviceAddressWidth: .bits64,
        coherency: .hardwareCoherent
    ) else {
        return nil
    }

    var index = 0
    while index < 64, let resource = platform.virtioTransport(at: index) {
        defer { index += 1 }
        guard platform.virtioTransportIsDMACoherent(at: index),
              var transport = VirtIOMMIOTransport(resource: resource),
              transport.hasVirtIOMagic,
              transport.identity.version == VirtIOMMIOTransport.modernVersion,
              transport.identity.deviceID == VirtIOMMIOTransport.gpuDeviceID,
              transport.initializeModernGPU(
                  queueMapping: queueMapping,
                  requestedDeviceFeatures:
                    VirtIOGPU3DFeatures.baseline3DRequestMask
              ) == .ready,
              var gpu = VirtIOGPU(transport: transport, scanout: scanout),
              gpu.configure()
        else {
            continue
        }
        return .virtIOGPU(mode: scanout.mode, driver: gpu)
    }
    return nil
}

private func runScheduledOrPark(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation
) -> Never {
    guard platform.processorCount > 1 else {
        console.write("SWIFTOS:READY\n")
        park()
    }
    guard KernelSMP.start(platform: platform, console: console) else {
        console.write("SWIFTOS:PANIC:SMP\n")
        park()
    }
    let frequency = AArch64.counterFrequency
    let period = frequency / 100
    guard period > 0 else {
        console.write("SWIFTOS:PANIC:TIMER_PERIOD\n")
        park()
    }
    console.write("SWIFTOS:READY\n")
    KernelEL0Runtime.launch(
        console: console,
        mappings: memory.userMappings,
        timerPeriodTicks: period
    )
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
    InterruptSubsystem.stopPhysicalTimer()
}

private func park() -> Never {
    while true {
        AArch64.waitForEvent()
    }
}
