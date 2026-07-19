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

typealias RaspberryPi5SharedSDCardBlockDevice =
    BorrowedBlockDeviceRegion<RaspberryPi5SDCardBlockDevice>
typealias RaspberryPi5UserFileSystemProvider =
    SwiftFSPersistentProvider<RaspberryPi5SharedSDCardBlockDevice>

private typealias RaspberryPi5PersistentLogService =
    DeferredPersistentLogService<
        RaspberryPi5SharedSDCardBlockDevice,
        RuntimeRetainedKernelLogSource
    >
private typealias RaspberryPi5UserFileSystemBootstrap =
    SwiftFSIncrementalVolumeBootstrap<
        RaspberryPi5SharedSDCardBlockDevice
    >

private nonisolated(unsafe) var raspberryPi5SDDeviceAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var raspberryPi5SwiftFSScratchAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var raspberryPi5SwiftFSProviderAllocation:
    ClassifiedPageAllocationToken?
private nonisolated(unsafe) var raspberryPi5SDDevice:
    UnsafeMutablePointer<RaspberryPi5SDCardBlockDevice>?
private nonisolated(unsafe) var raspberryPi5UserFileSystemProvider:
    UnsafeMutablePointer<RaspberryPi5UserFileSystemProvider>?

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
    private nonisolated(unsafe) static var pendingUserFileSystemBootstrap:
        RaspberryPi5UserFileSystemBootstrap?
    private nonisolated(unsafe) static var userFileSystemBootstrapResolved =
        false

    /// Board-specific transport type behind the same mounted-provider seam as
    /// QEMU. Callers must enter it only through the serialized storage owner;
    /// copies of its borrowed block-device view alias the one SD controller.
    static var mountedProvider:
        UnsafeMutablePointer<RaspberryPi5UserFileSystemProvider>? {
        raspberryPi5UserFileSystemProvider
    }

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
        if case .superblockReady = event {
            prepareUserFileSystemBootstrap(from: service)
        }
    }

    /// One recovery block or one durable 48-byte append per cooperative pass.
    static func serviceRecoveryOrFlushOnce() {
        if RaspberryPi5SwiftFSStoragePolicy.steadyStateAction(
            userFileSystemBootstrapPending:
                pendingUserFileSystemBootstrap != nil
        ) == .bootstrapUserFileSystem {
            serviceUserFileSystemBootstrapOnce()
            return
        }
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
        guard let coldDevice = RaspberryPi5SDCardTransport.coldDevice(
                  description: description
              )
        else {
            disable(marker: "SWIFTOS:SD_INIT_INVALID\n")
            return
        }
        guard let deviceAllocation = allocate(
                  pageCount: 1,
                  capabilities: .cpuAccessible
              )
        else {
            disable(marker: "SWIFTOS:STORAGE_DISABLED_MEMORY\n")
            return
        }
        guard let devicePointer = pointer(
                  in: deviceAllocation,
                  to: RaspberryPi5SDCardBlockDevice.self
              )
        else {
            _ = KernelMemoryRuntime.releaseClassifiedPages(deviceAllocation)
            disable(marker: "SWIFTOS:STORAGE_DISABLED_MEMORY\n")
            return
        }
        devicePointer.initialize(to: coldDevice)

        let initialized = devicePointer.pointee.initialize()
        guard initialized == .ready else {
            devicePointer.deinitialize(count: 1)
            _ = KernelMemoryRuntime.releaseClassifiedPages(deviceAllocation)
            reportInitializationFailure(initialized, console: console)
            faulted = true
            return
        }
        console.write("SWIFTOS:SD_INIT_READY_BLOCKS=")
        console.writeHex(devicePointer.pointee.geometry.logicalBlockCount)
        console.write("\n")

        let workspace = KernelLinkerLayout.storageScratch
        guard workspace.start <= UInt64(UInt.max),
              workspace.length >= UInt64(
                  devicePointer.pointee.geometry.logicalBlockByteCount
              ),
              workspace.length <= UInt64(Int.max),
              let pointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(workspace.start)
              ), let fullRange = BlockDeviceRange(
                  startBlock: 0,
                  blockCount:
                    devicePointer.pointee.geometry.logicalBlockCount,
                  within: devicePointer.pointee.geometry.logicalBlockCount
              ), let sharedDevice = RaspberryPi5SharedSDCardBlockDevice(
                  borrowing: devicePointer,
                  partitionRange: fullRange
              ), let service = RaspberryPi5PersistentLogService(
                  device: sharedDevice,
                  source: RuntimeRetainedKernelLogSource(),
                  scratch: UnsafeMutableRawBufferPointer(
                      start: pointer,
                      count: Int(workspace.length)
                  )
              )
        else {
            devicePointer.deinitialize(count: 1)
            _ = KernelMemoryRuntime.releaseClassifiedPages(deviceAllocation)
            disable(marker: "SWIFTOS:STORAGE_DISABLED_SCRATCH\n")
            return
        }
        // Publish the record only after the service holds its first borrowed
        // alias. From this point forward the allocation remains kernel-owned.
        raspberryPi5SDDeviceAllocation = deviceAllocation
        raspberryPi5SDDevice = devicePointer
        activeService = service
        allocateUserFileSystemResources(
            logicalBlockByteCount:
                devicePointer.pointee.geometry.logicalBlockByteCount
        )
    }

    private static func prepareUserFileSystemBootstrap(
        from service: RaspberryPi5PersistentLogService
    ) {
        guard !userFileSystemBootstrapResolved else { return }
        userFileSystemBootstrapResolved = true
        guard let devicePointer = raspberryPi5SDDevice,
              let dataPartition = service.selectedDataPartitionRange,
              let dataVolume = service.signedDataVolumeLayout,
              raspberryPi5SwiftFSScratchAllocation != nil,
              raspberryPi5SwiftFSProviderAllocation != nil
        else {
            reportUserFileSystemUnavailable()
            return
        }
        let planned = RaspberryPi5SwiftFSStoragePolicy.regionPlan(
            deviceGeometry: devicePointer.pointee.geometry,
            dataPartition: dataPartition,
            dataVolume: dataVolume,
            nodeCapacity:
                SwiftOSUserFileSystemConfiguration.initialNodeCapacity
        )
        switch planned {
        case .plan(let plan):
            guard let scratchAllocation =
                      raspberryPi5SwiftFSScratchAllocation,
                  let scratch = rawBuffer(for: scratchAllocation),
                  let userDevice = RaspberryPi5SharedSDCardBlockDevice(
                      borrowing: devicePointer,
                      partitionRange: plan.userFileSystem
                  )
            else {
                reportUserFileSystemUnavailable()
                return
            }
            pendingUserFileSystemBootstrap =
                RaspberryPi5UserFileSystemBootstrap(
                    device: userDevice,
                    volumeIdentifier:
                        SwiftOSUserFileSystemConfiguration.volumeIdentifier,
                    nodeCapacity:
                        SwiftOSUserFileSystemConfiguration
                            .initialNodeCapacity,
                    scratch: scratch
                )
        case .failure:
            reportUserFileSystemUnavailable()
        }
    }

    /// Advances only one incremental filesystem phase. A phase may perform one
    /// block read, one block write, one synchronize, or CPU-only validation;
    /// the persistent-log service never shares the same cooperative pass.
    private static func serviceUserFileSystemBootstrapOnce() {
        guard var bootstrap = pendingUserFileSystemBootstrap else { return }
        let step = bootstrap.serviceOnce()
        switch step {
        case .advanced:
            pendingUserFileSystemBootstrap = bootstrap
        case .ready(let provider, let state):
            pendingUserFileSystemBootstrap = nil
            guard let providerAllocation =
                      raspberryPi5SwiftFSProviderAllocation,
                  let providerPointer = pointer(
                      in: providerAllocation,
                      to: RaspberryPi5UserFileSystemProvider.self
                  )
            else {
                reportUserFileSystemUnavailable()
                return
            }
            providerPointer.initialize(to: provider)
            raspberryPi5UserFileSystemProvider = providerPointer
            switch state {
            case .formatted:
                console?.write("SWIFTOS:SWIFTFS_FORMATTED\n")
            case .mounted:
                console?.write("SWIFTOS:SWIFTFS_REMOUNTED\n")
            }
            console?.write("SWIFTOS:SWIFTFS_READY\n")
        case .failure:
            pendingUserFileSystemBootstrap = nil
            reportUserFileSystemUnavailable()
        }
    }

    private static func allocateUserFileSystemResources(
        logicalBlockByteCount: Int
    ) {
        guard logicalBlockByteCount > 0,
              UInt64(logicalBlockByteCount) <= UInt64.max / 2
        else { return }
        let scratchByteCount = UInt64(logicalBlockByteCount) * 2
        guard scratchByteCount <= UInt64.max - MemoryPageGeometry.pageMask
        else { return }
        let scratchPageCount = (
            scratchByteCount + MemoryPageGeometry.pageMask
        ) / MemoryPageGeometry.pageSize
        guard let scratch = allocate(
                  pageCount: scratchPageCount,
                  capabilities: .cpuAccessible
              )
        else { return }
        guard let provider = allocate(
                  pageCount: 1,
                  capabilities: .cpuAccessible
              )
        else {
            _ = KernelMemoryRuntime.releaseClassifiedPages(scratch)
            return
        }
        guard pointer(
                  in: provider,
                  to: RaspberryPi5UserFileSystemProvider.self
              ) != nil,
              let scratchBuffer = rawBuffer(for: scratch),
              scratchBuffer.count >= logicalBlockByteCount * 2
        else {
            _ = KernelMemoryRuntime.releaseClassifiedPages(provider)
            _ = KernelMemoryRuntime.releaseClassifiedPages(scratch)
            return
        }
        raspberryPi5SwiftFSScratchAllocation = scratch
        raspberryPi5SwiftFSProviderAllocation = provider
    }

    private static func allocate(
        pageCount: UInt64,
        capabilities: PhysicalMemoryCapabilities
    ) -> ClassifiedPageAllocationToken? {
        let result = KernelMemoryRuntime.allocateClassifiedPages(
            ClassifiedPageAllocationConstraints(
                pageCount: pageCount,
                requiredCapabilities: capabilities,
                domainSelection: .preferred(
                    KernelMemoryRuntime.defaultSystemMemoryDomain,
                    fallback: .disallowed
                )
            )
        )
        guard case .allocated(let token) = result else { return nil }
        return token
    }

    private static func pointer<Value>(
        in allocation: ClassifiedPageAllocationToken,
        to type: Value.Type
    ) -> UnsafeMutablePointer<Value>? {
        guard UInt64(MemoryLayout<Value>.stride) <= allocation.range.byteCount,
              allocation.range.baseAddress <= UInt64(UInt.max),
              allocation.range.baseAddress
                & UInt64(MemoryLayout<Value>.alignment - 1) == 0,
              let raw = UnsafeMutableRawPointer(
                  bitPattern: UInt(allocation.range.baseAddress)
              )
        else { return nil }
        return raw.assumingMemoryBound(to: Value.self)
    }

    private static func rawBuffer(
        for allocation: ClassifiedPageAllocationToken
    ) -> UnsafeMutableRawBufferPointer? {
        guard allocation.range.baseAddress <= UInt64(UInt.max),
              allocation.range.byteCount <= UInt64(Int.max),
              let pointer = UnsafeMutableRawPointer(
                  bitPattern: UInt(allocation.range.baseAddress)
              )
        else { return nil }
        return UnsafeMutableRawBufferPointer(
            start: pointer,
            count: Int(allocation.range.byteCount)
        )
    }

    private static func reportUserFileSystemUnavailable() {
        raspberryPi5UserFileSystemProvider = nil
        releaseUnpublishedUserFileSystemResources()
        console?.write("SWIFTOS:SWIFTFS_UNAVAILABLE\n")
    }

    private static func releaseUnpublishedUserFileSystemResources() {
        // Once a provider is published it borrows scratch for its full
        // lifetime, so neither page may be recycled even if another service
        // later faults and hides the provider seam.
        guard raspberryPi5UserFileSystemProvider == nil else { return }
        if let provider = raspberryPi5SwiftFSProviderAllocation {
            _ = KernelMemoryRuntime.releaseClassifiedPages(provider)
            raspberryPi5SwiftFSProviderAllocation = nil
        }
        if let scratch = raspberryPi5SwiftFSScratchAllocation {
            _ = KernelMemoryRuntime.releaseClassifiedPages(scratch)
            raspberryPi5SwiftFSScratchAllocation = nil
        }
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
            pendingUserFileSystemBootstrap = nil
            releaseUnpublishedUserFileSystemResources()
            raspberryPi5UserFileSystemProvider = nil
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
        pendingUserFileSystemBootstrap = nil
        releaseUnpublishedUserFileSystemResources()
        raspberryPi5UserFileSystemProvider = nil
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
