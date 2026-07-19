private struct RuntimeRetainedKernelLogSource: RetainedKernelLogSource {
    mutating func retainedLogStatistics() -> KernelLogStatistics? {
        KernelDebugLogRuntime.statistics
    }

    mutating func retainedLogEntry(
        sequence: UInt64
    ) -> KernelLogLookupResult? {
        KernelDebugLogRuntime.entry(sequence: sequence)
    }
}

private typealias RaspberryPi5PersistentLogService =
    DeferredPersistentLogService<
        RaspberryPi5SDCardBlockDevice,
        RuntimeRetainedKernelLogSource
    >

/// Owns physical SD activation and the board-neutral persistent-log service.
/// The composite Pi hook below chooses when each bounded stage may execute.
enum RaspberryPi5StorageRuntime {
    private nonisolated(unsafe) static var activeService:
        RaspberryPi5PersistentLogService?
    private nonisolated(unsafe) static var pendingDescription:
        PlatformStorageDeviceDescription?
    private nonisolated(unsafe) static var deferredActivation:
        PlatformDeferredActivationGate?
    private nonisolated(unsafe) static var console: EarlyConsole?
    private nonisolated(unsafe) static var faulted = false
    private nonisolated(unsafe) static var reportingPolicy =
        RaspberryPi5StorageReportingPolicy()

    static var signedVolumeBootstrapResolved: Bool {
        faulted || activeService?.signedVolumeBootstrapResolved == true
    }

    static var hasCooperativeWork: Bool {
        !faulted && (
            activeService != nil
                || pendingDescription != nil
                || deferredActivation != nil
        )
    }

    static func scheduleActivation(
        console: EarlyConsole,
        platform: Platform
    ) {
        guard case .raspberryPi5 = platform.kind,
              activeService == nil,
              pendingDescription == nil,
              deferredActivation == nil,
              !faulted
        else { return }
        guard let description = platform.systemStorageDevice else {
            faulted = true
            console.write("SWIFTOS:STORAGE_DISABLED_DISCOVERY\n")
            return
        }
        let frequency = AArch64.counterFrequency
        guard let gate = PlatformLocalObservationPolicy.makeGate(
                  counterFrequency: frequency
              )
        else {
            faulted = true
            console.write("SWIFTOS:STORAGE_DISABLED_CLOCK\n")
            return
        }
        self.console = console
        pendingDescription = description
        deferredActivation = gate
        console.write("SWIFTOS:STORAGE_DEFERRED\n")
    }

    /// Runs only SD initialization, MBR selection, or signed-superblock open.
    /// Recovery scanning is deliberately reserved until network bootstrap has
    /// had its one blocking pass.
    static func serviceBootstrapOnce() {
        if var gate = deferredActivation {
            guard gate.poll(nowTicks: AArch64.counterValue) else {
                deferredActivation = gate
                return
            }
            deferredActivation = nil
            initializeTransport()
            return
        }
        guard var service = activeService,
              !service.signedVolumeBootstrapResolved
        else { return }
        let event = service.serviceOnce(
            allowRecovery: false,
            maximumRecoveryBlockCount: 1,
            maximumAppendCount: 0
        )
        activeService = service
        report(event)
    }

    /// One recovery block or one durable 48-byte append per cooperative pass.
    static func serviceRecoveryOrFlushOnce() {
        guard var service = activeService,
              service.signedVolumeBootstrapResolved
        else { return }
        let event = service.serviceOnce(
            allowRecovery: true,
            maximumRecoveryBlockCount: 1,
            maximumAppendCount: 1
        )
        activeService = service
        report(event)
    }

    private static func initializeTransport() {
        guard let console, let description = pendingDescription else {
            disable(marker: "SWIFTOS:STORAGE_DISABLED_STATE\n")
            return
        }
        pendingDescription = nil
        console.write("SWIFTOS:SD_INIT_START\n")
        guard var device = RaspberryPi5SDCardTransport.coldDevice(
                  description: description
              )
        else {
            disable(marker: "SWIFTOS:SD_INIT_INVALID\n")
            return
        }
        let initialized = device.initialize()
        guard initialized == .ready else {
            reportInitializationFailure(initialized, console: console)
            faulted = true
            return
        }
        console.write("SWIFTOS:SD_INIT_READY_BLOCKS=")
        console.writeHex(device.geometry.logicalBlockCount)
        console.write("\n")

        let workspace = KernelLinkerLayout.storageScratch
        guard workspace.start <= UInt64(UInt.max),
              workspace.length >= UInt64(device.geometry.logicalBlockByteCount),
              workspace.length <= UInt64(Int.max),
              let pointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(workspace.start)
              ), let service = RaspberryPi5PersistentLogService(
                  device: device,
                  source: RuntimeRetainedKernelLogSource(),
                  scratch: UnsafeMutableRawBufferPointer(
                      start: pointer,
                      count: Int(workspace.length)
                  )
              )
        else {
            disable(marker: "SWIFTOS:STORAGE_DISABLED_SCRATCH\n")
            return
        }
        activeService = service
    }

    private static func report(_ event: DeferredPersistentLogEvent) {
        guard let console else { return }
        switch event {
        case .idle, .recoveryProgress:
            return
        case .partitionReady(let start, let count):
            console.write("SWIFTOS:STORAGE_MBR_READY\n")
            console.write("SWIFTOS:STORAGE_DATA_PARTITION=")
            console.writeHex(start)
            console.write(":")
            console.writeHex(count)
            console.write("\n")
        case .superblockReady(let logBlocks):
            console.write("SWIFTOS:STORAGE_SUPERBLOCK_READY=")
            console.writeHex(logBlocks)
            console.write("\n")
        case .recoveryReady(let newest):
            console.write("SWIFTOS:STORAGE_LOG_RECOVERY_READY=")
            console.writeHex(newest ?? 0)
            console.write("\n")
        case .volatileEntriesLost(let oldest):
            guard reportingPolicy.shouldReportFirstVolatileLoss() else {
                return
            }
            console.write("SWIFTOS:STORAGE_LOG_SOURCE_LOST=")
            console.writeHex(oldest)
            console.write("\n")
        case .flushed(_, let persistentSequence):
            // Exactly one marker: printing per append would itself create an
            // unbounded retained-log feedback loop.
            guard reportingPolicy.shouldReportFirstFlush() else { return }
            console.write("SWIFTOS:STORAGE_LOG_FLUSH_OK=")
            console.writeHex(persistentSequence)
            console.write("\n")
        case .disabled(let failure):
            reportFailure(failure, console: console)
            activeService = nil
            faulted = true
        }
    }

    private static func reportInitializationFailure(
        _ result: SDHCIInitializationResult,
        console: EarlyConsole
    ) {
        switch result {
        case .ready:
            return
        case .invalidState:
            console.write("SWIFTOS:SD_INIT_STATE_INVALID\n")
        case .cardAbsent:
            console.write("SWIFTOS:SD_INIT_CARD_ABSENT\n")
        case .boardPreparationTimedOut:
            console.write("SWIFTOS:SD_INIT_BOARD_TIMEOUT\n")
        case .boardPreparationFailed:
            console.write("SWIFTOS:SD_INIT_BOARD_FAILED\n")
        case .unsupportedHost:
            console.write("SWIFTOS:SD_INIT_HOST_UNSUPPORTED\n")
        case .hostResetTimedOut:
            console.write("SWIFTOS:SD_INIT_RESET_TIMEOUT\n")
        case .clockTimedOut:
            console.write("SWIFTOS:SD_INIT_CLOCK_TIMEOUT\n")
        case .cardInitializationTimedOut:
            console.write("SWIFTOS:SD_INIT_CARD_TIMEOUT\n")
        case .cardRejectedCommand(let command):
            console.write("SWIFTOS:SD_INIT_COMMAND_FAILED=")
            console.writeHex(UInt64(command))
            console.write("\n")
        case .unsupportedCard:
            console.write("SWIFTOS:SD_INIT_CARD_UNSUPPORTED\n")
        }
    }

    private static func reportFailure(
        _ failure: DeferredPersistentLogFailure,
        console: EarlyConsole
    ) {
        switch failure {
        case .partitionTable(let detail):
            console.write("SWIFTOS:STORAGE_DISABLED_MBR=")
            writePartitionFailure(detail, console: console)
        case .mediaLayout(let detail):
            console.write("SWIFTOS:STORAGE_DISABLED_LAYOUT=")
            writeLayoutFailure(detail, console: console)
        case .partitionBounds:
            console.write("SWIFTOS:STORAGE_DISABLED_PARTITION_BOUNDS\n")
        case .signedVolume(let detail):
            console.write("SWIFTOS:STORAGE_DISABLED_SUPERBLOCK=")
            writeVolumeFailure(detail, console: console)
        case .retainedLogUnavailable:
            console.write("SWIFTOS:STORAGE_DISABLED_LOG_SOURCE\n")
        case .append:
            console.write("SWIFTOS:STORAGE_DISABLED_LOG_WRITE\n")
        }
    }

    private static func writePartitionFailure(
        _ failure: MBRPartitionDiscoveryFailure,
        console: EarlyConsole
    ) {
        switch failure {
        case .invalidGeometry: console.write("GEOMETRY\n")
        case .invalidScratch: console.write("SCRATCH\n")
        case .readFailed: console.write("READ\n")
        case .missingSignature: console.write("SIGNATURE\n")
        case .invalidStatus: console.write("STATUS\n")
        case .emptyTypedEntry: console.write("EMPTY_ENTRY\n")
        case .startsAtPartitionTable: console.write("START\n")
        case .outOfBounds: console.write("BOUNDS\n")
        case .overlappingEntries: console.write("OVERLAP\n")
        case .protectiveGPTUnsupported: console.write("GPT\n")
        }
    }

    private static func writeLayoutFailure(
        _ failure: SwiftOSMediaLayoutFailure,
        console: EarlyConsole
    ) {
        switch failure {
        case .missingBootPartition: console.write("BOOT_MISSING\n")
        case .duplicateBootPartition: console.write("BOOT_DUPLICATE\n")
        case .missingDataPartition: console.write("DATA_MISSING\n")
        case .duplicateDataPartition: console.write("DATA_DUPLICATE\n")
        case .bootMustPrecedeData: console.write("ORDER\n")
        }
    }

    private static func writeVolumeFailure(
        _ failure: PersistentLogStoreOpenFailure,
        console: EarlyConsole
    ) {
        switch failure {
        case .readFailed:
            console.write("LOG_READ\n")
        case .volume(let volume):
            switch volume {
            case .invalidScratch: console.write("SCRATCH\n")
            case .readFailed: console.write("READ\n")
            case .missingSuperblock: console.write("MISSING\n")
            case .conflictingSuperblocks: console.write("CONFLICT\n")
            }
        }
    }

    private static func disable(marker: StaticString) {
        console?.write(marker)
        pendingDescription = nil
        deferredActivation = nil
        activeService = nil
        faulted = true
    }
}

/// One physical-board cooperative hook. USB remains first in KernelMonitor;
/// storage validates signed media, then RP1 receives its single potentially
/// blocking bootstrap pass, after which light network polling can coexist with
/// one storage recovery/append operation.
enum RaspberryPi5CooperativeRuntime {
    static func scheduleActivation(
        console: EarlyConsole,
        platform: Platform
    ) {
        RaspberryPi5StorageRuntime.scheduleActivation(
            console: console,
            platform: platform
        )
        RP1GEMNetworkRuntime.scheduleActivation(
            console: console,
            platform: platform
        )
    }

    static func cooperativeServiceHook(
        for board: BoardKind
    ) -> KernelMonitorServiceHook? {
        guard case .raspberryPi5 = board,
              RaspberryPi5StorageRuntime.hasCooperativeWork
                || RP1GEMNetworkRuntime.hasCooperativeWork
        else { return nil }
        return swiftOSServiceRaspberryPi5DeferredWork
    }

    static func serviceOnce() {
        // Storage and Ethernet share the first USB-serviced pass as the origin
        // of their observation windows even though policy serializes their
        // later blocking bootstrap work.
        RP1GEMNetworkRuntime.armDeferredBootstrapObservation()
        let action = RaspberryPi5CooperativePolicy.action(
            storageBootstrapResolved:
                RaspberryPi5StorageRuntime.signedVolumeBootstrapResolved,
            storageHasWork: RaspberryPi5StorageRuntime.hasCooperativeWork,
            networkBootstrapDeferred:
                RP1GEMNetworkRuntime.hasDeferredBootstrap,
            networkHasWork: RP1GEMNetworkRuntime.hasCooperativeWork
        )
        switch action {
        case .storageBootstrap:
            RP1GEMNetworkRuntime.advanceDeferredGateWithoutStarting()
            RaspberryPi5StorageRuntime.serviceBootstrapOnce()
        case .networkBootstrap:
            RP1GEMNetworkRuntime.serviceOnce()
        case .steadyState:
            RP1GEMNetworkRuntime.serviceOnce()
            RaspberryPi5StorageRuntime.serviceRecoveryOrFlushOnce()
        case .idle:
            return
        }
    }
}

@_cdecl("swiftos_service_raspberry_pi_5_deferred_work")
func swiftOSServiceRaspberryPi5DeferredWork() {
    RaspberryPi5CooperativeRuntime.serviceOnce()
}
