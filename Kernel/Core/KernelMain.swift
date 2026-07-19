private nonisolated(unsafe) var zeroProbe: UInt64 = 0
private nonisolated(unsafe) var dataProbe: UInt64 = 0x5357_4946_544f_5301
private nonisolated(unsafe) var activeVirtIOGPU3DSession:
    VirtIOGPU3DSession?
private nonisolated(unsafe) var activeVirtIOGPU3DAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var activeKernelUpdateAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var activeVirtIONetworkAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var activeVirtIONetworkService:
    PollingNetworkService<VirtIONetworkMMIODevice>?

@_cdecl("swiftos_main")
func swiftOSMain(_ deviceTreeAddress: UInt64) {
    guard let platform = Platform.discover(
        deviceTreeAddress: deviceTreeAddress
    ), platform.serial.baseAddress <= UInt64(UInt.max),
       platform.serial.length >= 0x30
    else {
        park()
    }
    KernelDebugLogRuntime.initialize()
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

    var retainedDriverResources = drivers.resources
    guard PlatformNetworkBootResources.appendDiscoveredResources(
              platform: platform,
              to: &retainedDriverResources
          )
    else {
        console.write("SWIFTOS:PANIC:NETWORK_RESOURCES\n")
        park()
    }

    guard PlatformStorageBootResources.appendDiscoveredResources(
              platform: platform,
              to: &retainedDriverResources
          )
    else {
        console.write("SWIFTOS:PANIC:STORAGE_RESOURCES\n")
        park()
    }

    guard let memory = KernelMemoryRuntime.activate(
        platform: platform,
        console: console,
        driverResources: retainedDriverResources
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
        RaspberryPi5CooperativeRuntime.scheduleActivation(
            console: console,
            platform: platform
        )
        if let display = drivers.display {
            console.write(SimpleFramebufferDisplayDriver.readyMarker)
            runPlatformDesktop(
                console: console,
                platform: platform,
                memory: memory,
                driver: display
            )
        }
        if platform.usbDeviceController != nil {
            runRaspberryPiUSBDesktop(
                console: console,
                platform: platform,
                memory: memory
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

/// Starts the same renderer and monitor used by physical scanout on a
/// kernel-owned surface. USB device mode therefore remains independently
/// debuggable when HDMI firmware did not hand over a simple-framebuffer.
private func runRaspberryPiUSBDesktop(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation
) -> Never {
    guard let mode = DisplayMode(
              widthInPixels: UInt32(RamFramebuffer.width),
              heightInPixels: UInt32(RamFramebuffer.height),
              refreshRateMilliHertz: nil,
              pixelFormat: .xrgb8888
          ), let mapping = DMAMapping(
              cpuPhysicalAddress: AArch64.framebufferAddress,
              deviceAddress: AArch64.framebufferAddress,
              byteCount: mode.minimumByteCount,
              deviceAddressWidth: .bits64,
              coherency: .hardwareCoherent
          ), let surface = ScanoutBuffer(
              mode: mode,
              bytesPerRow: mode.minimumBytesPerRow,
              mapping: mapping
          )
    else {
        console.write("SWIFTOS:PANIC:USB_DISPLAY_MEMORY\n")
        park()
    }
    console.write("SWIFTOS:GRAPHICS_DIAGNOSTIC\n")
    console.write("SWIFTOS:USB_DISPLAY_SURFACE\n")
    runDesktopSession(
        console: console,
        platform: platform,
        memory: memory,
        scanout: surface,
        display: .memorySurface(mode: mode)
    )
}

/// Brings up the optional QEMU VirtIO Ethernet device without making network
/// presence part of the existing boot contract. Candidate inspection is
/// read-only until a modern network device is identified, so GPU and empty
/// VirtIO MMIO transports are not reset or negotiated by this path.
private func activateQEMUVirtIONetwork(
    console: EarlyConsole,
    platform: Platform
) {
    guard activeVirtIONetworkAllocation == nil,
          activeVirtIONetworkService == nil,
          let description = qemuVirtIONetworkDescription(platform: platform)
    else {
        return
    }

    let requiredCapabilities = PhysicalMemoryCapabilities.cpuAccessible
        .union(.deviceAccessible)
        .union(.cacheCoherent)
    let allocationResult = KernelMemoryRuntime.allocateClassifiedPages(
        ClassifiedPageAllocationConstraints(
            pageCount: VirtIONetworkBootstrapMemory.pageCount,
            requiredCapabilities: requiredCapabilities,
            domainSelection: .preferred(
                KernelMemoryRuntime.defaultSystemMemoryDomain,
                fallback: .disallowed
            )
        )
    )
    guard case .allocated(let allocation) = allocationResult else {
        console.write("SWIFTOS:VIRTIO_NET_MEMORY_UNAVAILABLE\n")
        return
    }
    guard let workspace = VirtIONetworkBootstrapMemory(
              allocation: allocation,
              deviceBaseAddress: allocation.range.baseAddress,
              deviceAddressWidth: .bits64,
              coherency: .hardwareCoherent
          ), var device = VirtIONetworkMMIODevice(
              resource: description.registers,
              storage: workspace.storage
          )
    else {
        _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
        console.write("SWIFTOS:VIRTIO_NET_MEMORY_INVALID\n")
        return
    }

    let initialization = device.initialize()
    guard initialization == .ready else {
        switch initialization {
        case .invalidState, .invalidPollLimit, .wrongDevice, .legacyTransport:
            _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
        case .ready:
            break
        case .deviceResetFailed, .missingRequiredFeature,
             .featureNegotiationFailed, .queueUnavailable,
             .invalidDeviceConfiguration:
            // Initialization may already have published one queue address.
            // Keep the allocator capability alive so memory potentially
            // retained by the device is never returned to another owner.
            activeVirtIONetworkAllocation = allocation
        }
        console.write("SWIFTOS:VIRTIO_NET_INIT_FAILED\n")
        return
    }

    let frequency = AArch64.counterFrequency
    guard frequency > 0, frequency <= UInt64.max / 300 else {
        activeVirtIONetworkAllocation = allocation
        console.write("SWIFTOS:VIRTIO_NET_CLOCK_INVALID\n")
        return
    }
    let startTicks = AArch64.counterValue
    let packedMAC = NetworkBootCoordinator.packedMACAddress(device.macAddress)
    guard var service = NetworkBootCoordinator.makeService(
              link: device,
              receiveScratchAddress: workspace.receiveScratchAddress,
              transmitScratchAddress: workspace.transmitScratchAddress,
              scratchByteCount: workspace.scratchByteCount,
              counterFrequency: frequency,
              startTicks: startTicks
          )
    else {
        activeVirtIONetworkAllocation = allocation
        console.write("SWIFTOS:VIRTIO_NET_SERVICE_INVALID\n")
        return
    }

    // This bounded bootstrap poll proves the link and DHCP path. The retained
    // service is the ownership foundation for a later scheduled network
    // worker; this boot milestone does not claim continuous lease servicing.
    console.write("SWIFTOS:VIRTIO_NET_BOOT_POLLING\n")
    console.write("SWIFTOS:VIRTIO_NET_READY\n")
    console.write("SWIFTOS:VIRTIO_NET_MAC=")
    console.writeHex(packedMAC)
    console.write("\n")

    var clock = AArch64NetworkBootClock()
    let outcome = NetworkBootCoordinator.poll(
        service: &service,
        startTicks: startTicks,
        deadlineDeltaTicks: frequency * 3,
        linkDownPolicy: .fault,
        clock: &clock
    )

    activeVirtIONetworkAllocation = allocation
    activeVirtIONetworkService = service
    switch outcome {
    case .configured:
        console.write("SWIFTOS:DHCP_BOUND\n")
        if let configuration = service.networkConfiguration {
            console.write("SWIFTOS:VIRTIO_NET_IPV4=")
            console.writeHex(UInt64(configuration.address.rawValue))
            console.write("\n")
        }
    case .timedOut:
        console.write("SWIFTOS:DHCP_TIMEOUT\n")
    case .fault(let fault):
        writeVirtIONetworkFault(fault, console: console)
        console.write("SWIFTOS:VIRTIO_NET_FAULT\n")
    }
}

private func writeVirtIONetworkFault(
    _ fault: NetworkPollingFault,
    console: EarlyConsole
) {
    switch fault {
    case .device:
        console.write("SWIFTOS:VIRTIO_NET_DEVICE_FAULT\n")
    case .identity:
        console.write("SWIFTOS:VIRTIO_NET_IDENTITY_FAULT\n")
    case .scratch:
        console.write("SWIFTOS:VIRTIO_NET_SCRATCH_FAULT\n")
    case .transmitLinkDown:
        console.write("SWIFTOS:VIRTIO_NET_TX_LINK_DOWN\n")
    case .invalidTransmitFrame:
        console.write("SWIFTOS:VIRTIO_NET_TX_FRAME_INVALID\n")
    case .transmitTimeout:
        console.write("SWIFTOS:VIRTIO_NET_TX_TIMEOUT\n")
    case .transmitDevice:
        console.write("SWIFTOS:VIRTIO_NET_TX_DEVICE_FAULT\n")
    }
}

private func qemuVirtIONetworkDescription(
    platform: Platform
) -> PlatformNetworkDeviceDescription? {
    var index = 0
    while index < PlatformNetworkDeviceDiscovery.maximumCandidateCount {
        defer { index += 1 }
        guard let description = platform.networkDeviceCandidate(at: index),
              description.controller == .virtioMMIOCandidate,
              description.dma.addressing == .directSystemPhysical,
              description.dma.coherency == .hardwareCoherent,
              let transport = VirtIOMMIOTransport(
                  resource: description.registers
              ),
              transport.hasVirtIOMagic,
              transport.identity.version == VirtIOMMIOTransport.modernVersion,
              transport.identity.deviceID
                == VirtIONetworkMMIODevice.networkDeviceID
        else {
            continue
        }
        return description
    }
    return nil
}

private func runQEMUDesktop(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation
) -> Never {
    activateQEMUVirtIONetwork(console: console, platform: platform)

    switch activateVirtIOGPU3D(platform: platform) {
    case .ready(let configuration):
        runQEMUAcceleratedDesktop(
            console: console,
            platform: platform,
            memory: memory,
            configuration: configuration
        )
    case .failed:
        console.write("SWIFTOS:PANIC:VIRTIO_GPU_3D\n")
        park()
    case .unavailable:
        // The existing framebuffer renderer is an explicit bring-up and smoke
        // diagnostic. It is never entered after an accelerated device starts
        // a session and then fails.
        console.write("SWIFTOS:GRAPHICS_DIAGNOSTIC\n")
    }

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

private enum VirtIOGPU3DActivationResult {
    case ready(VirtIOGPU3DSessionConfiguration)
    case unavailable
    case failed
}

/// Crosses from backend-neutral allocator/DMA contracts into one VirtIO/VirGL
/// session. QEMU's transport consumes identity system-bus addresses; another
/// platform or IOMMU can construct the same workspace with translated device
/// addresses without changing the session itself.
private func activateVirtIOGPU3D(
    platform: Platform
) -> VirtIOGPU3DActivationResult {
    guard activeVirtIOGPU3DSession == nil,
          activeVirtIOGPU3DAllocation == nil
    else {
        return .failed
    }

    let requiredCapabilities = PhysicalMemoryCapabilities.cpuAccessible
        .union(.deviceAccessible)
        .union(.cacheCoherent)
    let allocationResult = KernelMemoryRuntime.allocateClassifiedPages(
        ClassifiedPageAllocationConstraints(
            pageCount: VirtIOGPU3DBootstrapMemory.pageCount,
            requiredCapabilities: requiredCapabilities,
            domainSelection: .preferred(
                KernelMemoryRuntime.defaultSystemMemoryDomain,
                fallback: .disallowed
            )
        )
    )
    guard case .allocated(let allocation) = allocationResult else {
        return .unavailable
    }
    guard let workspace = VirtIOGPU3DBootstrapMemory(
              allocation: allocation,
              deviceBaseAddress: allocation.range.baseAddress,
              deviceAddressWidth: .bits64,
              coherency: .hardwareCoherent
          ),
          let queueMapping = DMAMapping(
              cpuPhysicalAddress: AArch64.dmaScratchAddress,
              deviceAddress: AArch64.dmaScratchAddress,
              byteCount: MemoryPageGeometry.pageSize,
              deviceAddressWidth: .bits64,
              coherency: .hardwareCoherent
          )
    else {
        _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
        return .unavailable
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
                    VirtIOGPU3DFeatures.acceleratedRequestMask
              ) == .ready
        else {
            continue
        }

        guard transport.negotiatedFeatures
                & VirtIOGPU3DFeatures.baseline3DRequestMask
                == VirtIOGPU3DFeatures.baseline3DRequestMask
        else {
            continue
        }

        var session = VirtIOGPU3DSession(
            transport: transport,
            commandArenaMapping: workspace.commandArena,
            requestMapping: workspace.request,
            responseMapping: workspace.response,
            protectedQueueMapping: queueMapping
        )
        switch session.configureAndRenderDesktop() {
        case .configured(let configuration):
            activeVirtIOGPU3DAllocation = allocation
            activeVirtIOGPU3DSession = session
            return .ready(configuration)
        case .failed:
            // The session may have timed out. Preserve its pages and queue
            // ownership rather than allowing another device or the CPU
            // diagnostic path to reuse memory that could still be referenced.
            activeVirtIOGPU3DAllocation = allocation
            activeVirtIOGPU3DSession = session
            return .failed
        }
    }

    _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
    return .unavailable
}

private func runQEMUAcceleratedDesktop(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation,
    configuration: VirtIOGPU3DSessionConfiguration
) -> Never {
    console.write(VirtIOGPU.transportReadyMarker)
    console.write(VirtIOGPU3DSession.readyMarker)
    console.write("SWIFTOS:GPU_MODE=")
    console.writeHex(UInt64(configuration.width))
    console.write("x")
    console.writeHex(UInt64(configuration.height))
    console.write("\n")
    console.write("SWIFTOS:GPU_FRAME_READY\n")
    console.write("SWIFTOS:SWIFT_OK\n")

    proveTimerInterrupts(console: console)
    runScheduledOrPark(
        console: console,
        platform: platform,
        memory: memory
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
    let kernelUpdateStaging = activateKernelUpdateStaging(
        console: console,
        platform: platform,
        memory: memory
    )
    let usbDebug = activateUSBDebugGadget(
        console: console,
        platform: platform,
        memory: memory,
        scanout: scanout,
        viewport: viewport,
        kernelUpdateStaging: kernelUpdateStaging
    )
    var monitor = KernelMonitor(
        canvas: canvas,
        display: display,
        platform: platform,
        kernelUpdateDestination: memory.kernelUpdateDestination,
        kernelUpdateStaging: kernelUpdateStaging,
        storageAddress: AArch64.terminalStorageAddress,
        serial: PL011(baseAddress: UInt(platform.serial.baseAddress)),
        usbDebug: usbDebug,
        cooperativeServiceHook: RaspberryPi5CooperativeRuntime.cooperativeServiceHook(
            for: platform.kind
        )
    )
    guard monitor.start() else {
        console.write("SWIFTOS:PANIC:DISPLAY_PRESENT\n")
        park()
    }
    switch displayKind {
    case .memorySurface:
        console.write("SWIFTOS:USB_DISPLAY_READY\n")
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
    // QEMU currently hands its BSP to the preemptive EL0 scheduler. Until Pi
    // service work has its own kernel thread, keep the Pi BSP in the monitor
    // loop so polled USB and display presentation continue making progress.
    if platform.kind == .qemuVirt && platform.processorCount > 1 {
        runScheduledOrPark(
            console: console,
            platform: platform,
            memory: memory
        )
    }
    console.write("SWIFTOS:READY\n")
    monitor.run()
}

private func activateUSBDebugGadget(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation,
    scanout: ScanoutBuffer,
    viewport: DisplayViewport,
    kernelUpdateStaging: KernelUpdateStagingLayout?
) -> RaspberryPiUSBDebugGadget? {
    guard case .raspberryPi5 = platform.kind,
          case .dwc2(let resource)? = platform.usbDeviceController,
          viewport.scale > 0,
          viewport.scale <= Int(UInt16.max)
    else {
        return nil
    }
    let scratchAddress = AArch64.dmaScratchAddress
    guard powerOnRaspberryPiUSB(
              console: console,
              platform: platform,
              scratchAddress: scratchAddress
          )
    else {
        return nil
    }
    guard platform.processorCount > 0,
          platform.processorCount <= Int(UInt16.max),
          memory.usablePageCount
            <= UInt64.max / MemoryPageGeometry.pageSize,
          let bootIdentity = KernelBootIdentityRuntime.create(
              deviceTreeAddress: platform.deviceTreeAddress,
              machineDiscriminator: UInt64(platform.kind.rawValue) + 1
          ), let kernelDescription = USBDebugKernelDescription(
              bootIdentity: bootIdentity,
              configuredProcessorCount: UInt16(platform.processorCount),
              managedMemoryByteCount: memory.usablePageCount
                  * MemoryPageGeometry.pageSize
          )
    else {
        console.write("SWIFTOS:USB_DEBUG_IDENTITY_INVALID\n")
        return nil
    }
    let updateStagingRegion: USBKernelUpdateRAMStagingRegion?
    if let kernelUpdateStaging {
        guard let region = USBKernelUpdateRAMStagingRegion(
                  baseAddress: kernelUpdateStaging.image.baseAddress,
                  byteCount: kernelUpdateStaging.image.byteCount
              )
        else {
            console.write("SWIFTOS:USB_UPDATE_STAGING_INVALID\n")
            return nil
        }
        updateStagingRegion = region
    } else {
        updateStagingRegion = nil
    }
    guard let gadget = RaspberryPiUSBDebugGadget(
              resource: resource,
              scratchBaseAddress: scratchAddress,
              scratchByteCount: 4_096,
              scanout: scanout,
              viewportScale: UInt16(viewport.scale),
              kernelDescription: kernelDescription,
              updateTargetMachine: .raspberryPi5,
              updateStagingRegion: updateStagingRegion
          )
    else {
        console.write("SWIFTOS:USB_DEBUG_UNAVAILABLE\n")
        return nil
    }
    console.write(
        DWC2USBDebugGadget<DWC2MMIORegisterAccess>.readyMarker
    )
    if updateStagingRegion != nil {
        console.write("SWIFTOS:USB_UPDATE_READY\n")
    }
    return gadget
}

/// Reserves one transport-neutral high-memory update workspace. The running
/// Pi image destination was excluded earlier during memory bootstrap; this
/// separate allocation holds only the incoming raw image, copied DTB,
/// trampoline, and transition stack.
private func activateKernelUpdateStaging(
    console: EarlyConsole,
    platform: Platform,
    memory: KernelMemoryActivation
) -> KernelUpdateStagingLayout? {
    guard platform.kind == .raspberryPi5 else {
        return nil
    }
    guard memory.kernelUpdateDestination
            == RaspberryPiKernelUpdateContract.destinationWindow,
          activeKernelUpdateAllocation == nil,
          KernelUpdateStagingLimits.allocationByteCount
            % MemoryPageGeometry.pageSize == 0
    else {
        console.write("SWIFTOS:USB_UPDATE_STAGING_UNAVAILABLE\n")
        return nil
    }
    let pageCount = KernelUpdateStagingLimits.allocationByteCount
        / MemoryPageGeometry.pageSize
    let alignmentInPages = UInt64(2 * 1_024 * 1_024)
        / MemoryPageGeometry.pageSize
    let allocationResult = KernelMemoryRuntime.allocateClassifiedPages(
        ClassifiedPageAllocationConstraints(
            pageCount: pageCount,
            alignmentInPages: alignmentInPages,
            minimumAddress: KernelUpdateStagingLimits.minimumStagingAddress,
            requiredCapabilities: .cpuAccessible,
            domainSelection: .preferred(
                KernelMemoryRuntime.defaultSystemMemoryDomain,
                fallback: .disallowed
            )
        )
    )
    guard case .allocated(let allocation) = allocationResult else {
        console.write("SWIFTOS:USB_UPDATE_STAGING_UNAVAILABLE\n")
        return nil
    }
    guard let layout = KernelUpdateStagingLayout(
              baseAddress: allocation.range.baseAddress,
              byteCount: allocation.range.byteCount
          ) else {
        _ = KernelMemoryRuntime.releaseClassifiedPages(allocation)
        console.write("SWIFTOS:USB_UPDATE_STAGING_UNAVAILABLE\n")
        return nil
    }
    activeKernelUpdateAllocation = allocation
    console.write("SWIFTOS:USB_UPDATE_STAGING_READY\n")
    return layout
}

/// Transfers the linker-owned scratch prefix to firmware long enough to power
/// the DWC2 domain. A failure disables only the optional USB debug path; HDMI,
/// serial, scheduling, and the QEMU platform continue independently.
private func powerOnRaspberryPiUSB(
    console: EarlyConsole,
    platform: Platform,
    scratchAddress: UInt64
) -> Bool {
    guard let mailboxResource = platform.firmwareMailbox else {
        console.write("SWIFTOS:USB_POWER_NO_MAILBOX\n")
        return false
    }
    guard let registers = FirmwareMailboxMMIORegisterAccess(
              resource: mailboxResource
          )
    else {
        console.write("SWIFTOS:USB_POWER_MAILBOX_RESOURCE\n")
        return false
    }
    guard var mailbox = FirmwarePropertyMailbox(
              registers: registers,
              cache: AArch64FirmwareMailboxCacheMaintenance(),
              bufferCPUAddress: scratchAddress,
              // SwiftOS keeps its kernel and DMA scratch identity-mapped.
              // Property channel 8 consumes the ARM physical address.
              bufferPhysicalAddress: scratchAddress,
              bufferByteCount: 4_096
          )
    else {
        console.write("SWIFTOS:USB_POWER_MAILBOX_BUFFER\n")
        return false
    }

    let result = mailbox.setPowerState(
        deviceID: FirmwareMailboxPowerDevice.usb,
        poweredOn: true,
        waitUntilStable: true,
        maximumPollCount: 100_000
    )
    switch result {
    case .completed:
        console.write("SWIFTOS:USB_POWER_READY\n")
        return true
    case .invalidPollLimit:
        console.write("SWIFTOS:USB_POWER_POLL_LIMIT\n")
    case .cacheCleanFailed:
        console.write("SWIFTOS:USB_POWER_CACHE_CLEAN\n")
    case .writeTimedOut:
        console.write("SWIFTOS:USB_POWER_WRITE_TIMEOUT\n")
    case .responseTimedOut:
        console.write("SWIFTOS:USB_POWER_RESPONSE_TIMEOUT\n")
    case .cacheInvalidationFailed:
        console.write("SWIFTOS:USB_POWER_CACHE_INVALIDATE\n")
    case .malformedResponse(let error):
        console.write(usbPowerResponseMarker(for: error))
    }
    return false
}

private func usbPowerResponseMarker(
    for error: FirmwareMailboxPowerResponseError
) -> StaticString {
    switch error {
    case .bufferSize:
        return "SWIFTOS:USB_POWER_RESPONSE_SIZE\n"
    case .messageResponseCode:
        return "SWIFTOS:USB_POWER_RESPONSE_CODE\n"
    case .tagIdentifier:
        return "SWIFTOS:USB_POWER_TAG_ID\n"
    case .tagBufferSize:
        return "SWIFTOS:USB_POWER_TAG_SIZE\n"
    case .tagResponseLength:
        return "SWIFTOS:USB_POWER_TAG_LENGTH\n"
    case .deviceIdentifier:
        return "SWIFTOS:USB_POWER_DEVICE_ID\n"
    case .powerState:
        return "SWIFTOS:USB_POWER_STATE\n"
    case .endTag:
        return "SWIFTOS:USB_POWER_END_TAG\n"
    }
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
              case let .ready(configuration) =
                transport.readGPUDeviceConfiguration(),
              configuration.capsetCount > 0
                || transport.negotiatedFeatures
                    & VirtIOGPU3DFeatures.baseline3DRequestMask == 0,
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
    // A headless physical board still needs its bounded service work to make
    // progress when both display and USB discovery fail. This path deliberately
    // keeps the BSP observable instead of parking or handing it to EL0.
    if let cooperativeService = RaspberryPi5CooperativeRuntime.cooperativeServiceHook(
        for: platform.kind
    ) {
        console.write("SWIFTOS:READY\n")
        while true {
            cooperativeService()
            AArch64.spinHint()
        }
    }
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
