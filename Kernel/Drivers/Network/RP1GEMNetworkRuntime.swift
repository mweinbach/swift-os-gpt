private typealias RP1GEMBootPreparation = RP1GEMBoardPreparation<
    RP1GEMBoardMMIOAccess
>
private typealias RP1GEMBootBoard = RP1GEMBoardControl<
    RP1GEMBootPreparation,
    RP1GEMConfigurationMMIORegisterAccess
>
private typealias RP1GEMBootLink = CadenceGEMNetworkDevice<
    RP1GEMMMIORegisterAccess,
    RP1GEMSoftwareManagedDMAAccess,
    RP1GEMBootBoard
>

private enum RP1GEMNetworkBootPolicy {
    static let boardPreparationMaximumPollCount: UInt64 = 100_000_000
    /// At roughly two Clause 22 transactions per autonegotiation poll, this
    /// remains long enough for link training while independently bounding a
    /// stopped or unexpectedly fast architectural counter.
    static let deviceMaximumPollCount: UInt64 = 200_000
    static let hardwareWaitSeconds: UInt64 = 12
    /// RP1's 200-MHz SYS clock divided by 96 remains below Clause 22's
    /// 2.5-MHz MDC ceiling.
    static let mdcClockDividerEncoding: UInt8 = 5
    static let bootstrapDeadlineSeconds: UInt64 = 12
}

/// Owns the concrete Pi network link while exposing only board-neutral boot
/// and cooperative-service entry points to `KernelMain`.
enum RP1GEMNetworkRuntime {
    private nonisolated(unsafe) static var activeService:
        PollingNetworkService<RP1GEMBootLink>?
    private nonisolated(unsafe) static var faulted = false
    private nonisolated(unsafe) static var console: EarlyConsole?
    private nonisolated(unsafe) static var reportedConfiguration = false
    private nonisolated(unsafe) static var pendingPlatform: Platform?
    private nonisolated(unsafe) static var deferredActivation:
        RP1GEMDeferredActivationGate?

    /// Records physical-network work for the cooperative monitor loop. No RP1
    /// MMIO is touched here, so HDMI presentation, USB gadget initialization,
    /// and the serial READY marker all precede potentially blocking PHY work.
    static func scheduleActivation(
        console: EarlyConsole,
        platform: Platform
    ) {
        guard case .raspberryPi5 = platform.kind,
              activeService == nil,
              pendingPlatform == nil,
              deferredActivation == nil,
              !faulted
        else {
            return
        }
        let frequency = AArch64.counterFrequency
        guard let gate = RP1GEMDeferredActivationPolicy.makeGate(
                  counterFrequency: frequency
              )
        else {
            console.write("SWIFTOS:RP1_NET_DEFER_INVALID\n")
            return
        }

        self.console = console
        pendingPlatform = platform
        deferredActivation = gate
        console.write("SWIFTOS:RP1_NET_DEFERRED\n")
    }

    /// Binds RP1 GEM to the same polling IPv4 service used by QEMU. Every
    /// address comes from linker ownership plus the live boot FDT.
    private static func activate(console: EarlyConsole, platform: Platform) {
        guard activeService == nil, !faulted else { return }
        guard let description = platform.networkDeviceCandidate(at: 0),
              description.controller == .rp1GEM,
              description.dma.addressing == .translatedByParentBus,
              description.dma.coherency == .softwareManaged,
              case .rp1GEM(let boardResources)? = description.boardResources,
              boardResources.gemRegisters == description.registers
        else {
            console.write("SWIFTOS:RP1_NET_UNAVAILABLE\n")
            return
        }

        let workspaceRegion = KernelLinkerLayout.rp1GEMWorkspace
        guard workspaceRegion.length
                == RP1GEMBootstrapMemory.workspaceByteCount,
              let workspaceMapping = platform.networkDMAMapping(
                  forCandidateAt: 0,
                  cpuPhysicalAddress: workspaceRegion.start,
                  byteCount: workspaceRegion.length,
                  deviceAddressWidth: .bits32
              ), workspaceMapping.cpuPhysicalAddress == workspaceRegion.start,
              workspaceMapping.byteCount == workspaceRegion.length,
              workspaceMapping.deviceAddressWidth == .bits32,
              workspaceMapping.coherency == .softwareManaged,
              let workspace = RP1GEMBootstrapMemory(
                  cpuBaseAddress: workspaceRegion.start,
                  byteCount: workspaceRegion.length,
                  deviceBaseAddress: workspaceMapping.deviceAddress,
                  deviceAddressWidth: .bits32
              )
        else {
            console.write("SWIFTOS:RP1_NET_DMA_INVALID\n")
            return
        }

        guard let registers = RP1GEMMMIORegisterAccess(
                  resource: description.registers
              ), let statusRegisters = RP1GEMConfigurationMMIORegisterAccess(
                  resource: boardResources.ethernetConfigurationRegisters
              )
        else {
            console.write("SWIFTOS:RP1_NET_MMIO_INVALID\n")
            return
        }

        console.write("SWIFTOS:RP1_NET_PREPARING\n")
        var preparation = RP1GEMBootPreparation(
            resources: boardResources,
            access: RP1GEMBoardMMIOAccess()
        )
        switch preparation.prepareRP1Ethernet(
            maximumPollCount:
                RP1GEMNetworkBootPolicy.boardPreparationMaximumPollCount
        ) {
        case .ready:
            break
        case .timedOut:
            console.write("SWIFTOS:RP1_NET_BOARD_TIMEOUT\n")
            return
        case .failed:
            console.write("SWIFTOS:RP1_NET_BOARD_FAILED\n")
            return
        }

        let frequency = AArch64.counterFrequency
        guard frequency > 0,
              frequency <= UInt64.max / 300,
              RP1GEMNetworkBootPolicy.hardwareWaitSeconds
                <= UInt64.max / frequency,
              RP1GEMNetworkBootPolicy.bootstrapDeadlineSeconds
                <= UInt64.max / frequency
        else {
            console.write("SWIFTOS:RP1_NET_CLOCK_INVALID\n")
            return
        }

        guard let macAddress = CadenceGEMMACAddressSelector.select(
                  firmwareAddress: boardResources.localMACAddress,
                  registers: registers
              ), let phyAddress = UInt8(
                  exactly: boardResources.phy.clause22Address
              ), let configuration = CadenceGEMDeviceConfiguration(
                  macAddress: macAddress,
                  phyAddress: phyAddress,
                  mdcClockDividerEncoding:
                    RP1GEMNetworkBootPolicy.mdcClockDividerEncoding,
                  maximumPollCount:
                    RP1GEMNetworkBootPolicy.deviceMaximumPollCount,
                  maximumWaitTicks: frequency
                    * RP1GEMNetworkBootPolicy.hardwareWaitSeconds
              )
        else {
            console.write("SWIFTOS:RP1_NET_IDENTITY_INVALID\n")
            return
        }

        let board = RP1GEMBootBoard(
            preparation: preparation,
            statusRegisters: statusRegisters
        )
        var device = RP1GEMBootLink(
            registers: registers,
            dma: RP1GEMSoftwareManagedDMAAccess(),
            board: board,
            storage: workspace.storage,
            configuration: configuration
        )
        console.write("SWIFTOS:RP1_NET_AUTONEGOTIATING\n")
        let initialization = device.initialize()
        guard initialization == .ready else {
            writeInitializationFailure(initialization, console: console)
            return
        }

        let startTicks = AArch64.counterValue
        guard var service = NetworkBootCoordinator.makeService(
                  link: device,
                  receiveScratchAddress: workspace.receiveScratchAddress,
                  transmitScratchAddress: workspace.transmitScratchAddress,
                  scratchByteCount: RP1GEMBootstrapMemory.scratchByteCount,
                  counterFrequency: frequency,
                  startTicks: startTicks
              )
        else {
            console.write("SWIFTOS:RP1_NET_SERVICE_INVALID\n")
            return
        }

        console.write("SWIFTOS:RP1_NET_READY\n")
        console.write("SWIFTOS:RP1_NET_MAC=")
        console.writeHex(
            NetworkBootCoordinator.packedMACAddress(macAddress)
        )
        console.write("\n")
        console.write("SWIFTOS:RP1_NET_BOOT_POLLING\n")
        var clock = AArch64NetworkBootClock()
        let outcome = NetworkBootCoordinator.poll(
            service: &service,
            startTicks: startTicks,
            deadlineDeltaTicks: frequency
                * RP1GEMNetworkBootPolicy.bootstrapDeadlineSeconds,
            linkDownPolicy: .recoverable,
            clock: &clock
        )

        switch outcome {
        case .configured:
            retain(service, console: console, reported: true)
            console.write("SWIFTOS:DHCP_BOUND\n")
            if let network = service.networkConfiguration {
                writeAddress(network.address, console: console)
            }
        case .timedOut:
            // Once hardware initialization has established a link, the
            // monitor loop keeps servicing DHCP and later link reconnection.
            // Cold boot without a trained PHY still exits above with a
            // bounded initialization timeout.
            retain(service, console: console, reported: false)
            console.write("SWIFTOS:DHCP_TIMEOUT\n")
        case .fault(let pollingFault):
            faulted = true
            writePollingFault(pollingFault, console: console)
        }
    }

    static func cooperativeServiceHook(
        for board: BoardKind
    ) -> KernelMonitorServiceHook? {
        guard case .raspberryPi5 = board,
              activeService != nil || deferredActivation != nil,
              !faulted
        else {
            return nil
        }
        return swiftOSServiceRP1Network
    }

    static func serviceOnce() {
        if var gate = deferredActivation {
            guard gate.poll(nowTicks: AArch64.counterValue) else {
                deferredActivation = gate
                return
            }
            deferredActivation = nil
            guard let platform = pendingPlatform,
                  let console = self.console
            else {
                pendingPlatform = nil
                faulted = true
                return
            }
            pendingPlatform = nil
            console.write("SWIFTOS:RP1_NET_STARTING\n")
            activate(console: console, platform: platform)
            return
        }

        guard var service = activeService else { return }
        let event = service.poll(nowTicks: AArch64.counterValue)
        if let pollingFault = NetworkBootCoordinator.pollingFault(
            for: event,
            linkDownPolicy: .recoverable
        ) {
            activeService = nil
            faulted = true
            if let console {
                writePollingFault(pollingFault, console: console)
            }
            return
        }

        activeService = service
        if !reportedConfiguration,
           let network = service.networkConfiguration,
           let console {
            reportedConfiguration = true
            console.write("SWIFTOS:DHCP_BOUND\n")
            writeAddress(network.address, console: console)
        }
    }

    private static func retain(
        _ service: PollingNetworkService<RP1GEMBootLink>,
        console: EarlyConsole,
        reported: Bool
    ) {
        activeService = service
        self.console = console
        reportedConfiguration = reported
    }

    private static func writeAddress(
        _ address: IPv4Address,
        console: EarlyConsole
    ) {
        console.write("SWIFTOS:RP1_NET_IPV4=")
        console.writeHex(UInt64(address.rawValue))
        console.write("\n")
    }

    private static func writeInitializationFailure(
        _ result: CadenceGEMInitializationResult,
        console: EarlyConsole
    ) {
        switch result {
        case .ready:
            return
        case .invalidState:
            console.write("SWIFTOS:RP1_NET_INIT_STATE_INVALID\n")
        case .boardPreparationTimedOut:
            console.write("SWIFTOS:RP1_NET_INIT_BOARD_TIMEOUT\n")
        case .boardPreparationFailed:
            console.write("SWIFTOS:RP1_NET_INIT_BOARD_FAILED\n")
        case .dmaCacheMaintenanceFailed:
            console.write("SWIFTOS:RP1_NET_INIT_DMA_FAILED\n")
        case .mdioTimedOut:
            console.write("SWIFTOS:RP1_NET_INIT_MDIO_TIMEOUT\n")
        case .phyNotFound(let identifier1, let identifier2):
            console.write("SWIFTOS:RP1_NET_INIT_PHY_NOT_FOUND=")
            console.writeHex(UInt64(identifier1))
            console.write(":")
            console.writeHex(UInt64(identifier2))
            console.write("\n")
        case .phyAutonegotiationTimedOut:
            console.write("SWIFTOS:RP1_NET_INIT_AUTONEG_TIMEOUT\n")
        case .linkModeUnavailable:
            console.write("SWIFTOS:RP1_NET_INIT_LINK_MODE_INVALID\n")
        }
    }

    private static func writePollingFault(
        _ pollingFault: NetworkPollingFault,
        console: EarlyConsole
    ) {
        switch pollingFault {
        case .device:
            console.write("SWIFTOS:RP1_NET_DEVICE_FAULT\n")
        case .identity:
            console.write("SWIFTOS:RP1_NET_IDENTITY_FAULT\n")
        case .scratch:
            console.write("SWIFTOS:RP1_NET_SCRATCH_FAULT\n")
        case .transmitLinkDown:
            console.write("SWIFTOS:RP1_NET_TX_LINK_DOWN\n")
        case .invalidTransmitFrame:
            console.write("SWIFTOS:RP1_NET_TX_FRAME_INVALID\n")
        case .transmitTimeout:
            console.write("SWIFTOS:RP1_NET_TX_TIMEOUT\n")
        case .transmitDevice:
            console.write("SWIFTOS:RP1_NET_TX_DEVICE_FAULT\n")
        }
    }
}

@_cdecl("swiftos_service_rp1_network")
func swiftOSServiceRP1Network() {
    RP1GEMNetworkRuntime.serviceOnce()
}
