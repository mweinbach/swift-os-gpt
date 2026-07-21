protocol RetainedKernelLogSource {
    mutating func retainedLogStatistics() -> KernelLogStatistics?
    mutating func retainedLogEntry(
        sequence: UInt64
    ) -> KernelLogLookupResult?
}

enum DeferredPersistentLogFailure: Equatable {
    case partitionTable(MBRPartitionDiscoveryFailure)
    case mediaLayout(SwiftOSMediaLayoutFailure)
    case abMediaLayout(SwiftOSABMediaLayoutFailure)
    case partitionBounds
    case signedVolume(PersistentLogStoreOpenFailure)
    case retainedLogUnavailable
    case append(PersistentLogAppendResult)
}

enum DeferredPersistentLogEvent: Equatable {
    case idle
    case partitionReady(startBlock: UInt64, blockCount: UInt64)
    case superblockReady(kernelLogBlockCount: UInt64)
    case recoveryProgress(scannedBlockCount: UInt64, totalBlockCount: UInt64)
    case recoveryReady(newestPersistentSequence: UInt64?)
    case volatileEntriesLost(oldestAvailableSequence: UInt64)
    case flushed(
        volatileSequence: UInt64,
        persistentSequence: UInt64
    )
    case disabled(DeferredPersistentLogFailure)
}

private enum DeferredPersistentLogStage: UInt8 {
    case partitionTable
    case signedVolume
    case recovery
    case ready
    case disabled
}

/// Board-neutral, cooperative bridge from a sector device and retained kernel
/// ring to the signed 0xDA data volume. It never formats media. MBR selection,
/// superblock validation, recovery scanning, and appends are distinct passes;
/// any ambiguity permanently removes write authority from this value.
struct DeferredPersistentLogService<
    Device: BlockDevice,
    Source: RetainedKernelLogSource
> {
    private typealias Partition = PartitionBlockDevice<Device>

    private var rawDevice: Device?
    private var partitionDevice: Partition?
    private var recovery: PersistentLogStoreRecovery<Partition>?
    private var store: PersistentLogStore<Partition>?
    private var source: Source
    private let scratch: UnsafeMutableRawBufferPointer
    private var stage = DeferredPersistentLogStage.partitionTable
    private var nextVolatileSequence: UInt64?
    private var volatileSequenceSpaceConsumed = false

    /// The media ranges selected by the validated bootstrap stages. These are
    /// observations only: callers gain no storage authority from the values
    /// and must still create their own bounded `BlockDevice` view.
    private(set) var selectedDataPartitionRange: BlockDeviceRange?
    private(set) var signedDataVolumeLayout: SwiftOSDataVolumeLayout?

    init?(
        device: Device,
        source: Source,
        scratch: UnsafeMutableRawBufferPointer
    ) {
        guard scratch.baseAddress != nil,
              scratch.count >= device.geometry.logicalBlockByteCount
        else { return nil }
        self.rawDevice = device
        self.source = source
        self.scratch = scratch
    }

    /// True after the signed superblocks have either validated or caused a
    /// permanent nonfatal failure. A scheduler can use this boundary to run a
    /// pending network bootstrap before starting the potentially long scan.
    var signedVolumeBootstrapResolved: Bool {
        stage == .recovery || stage == .ready || stage == .disabled
    }

    var isPermanentlyDisabled: Bool { stage == .disabled }

    mutating func serviceOnce(
        allowRecovery: Bool,
        maximumRecoveryBlockCount: UInt64,
        maximumAppendCount: Int
    ) -> DeferredPersistentLogEvent {
        switch stage {
        case .partitionTable:
            return discoverPartition()
        case .signedVolume:
            return openSignedVolume()
        case .recovery:
            guard allowRecovery, maximumRecoveryBlockCount > 0 else {
                return .idle
            }
            return recover(maximumBlockCount: maximumRecoveryBlockCount)
        case .ready:
            guard maximumAppendCount > 0 else { return .idle }
            return flush(maximumAppendCount: maximumAppendCount)
        case .disabled:
            return .idle
        }
    }

    private mutating func discoverPartition() -> DeferredPersistentLogEvent {
        guard var device = rawDevice else {
            return disable(.partitionBounds)
        }
        let discovered = MBRPartitionDiscovery.read(
            from: &device,
            scratch: scratch
        )
        let table: MBRPartitionTable
        switch discovered {
        case .table(let value): table = value
        case .failure(let failure):
            return disable(.partitionTable(failure))
        }
        let dataPartition: MBRPartition
        if table.partition(at: 3) != nil {
            switch SwiftOSABMediaLayout.select(from: table) {
            case .layout(let media):
                dataPartition = media.data
            case .failure(let failure):
                return disable(.abMediaLayout(failure))
            }
        } else {
            switch SwiftOSMediaLayout.select(from: table) {
            case .layout(let media):
                dataPartition = media.data
            case .failure(let failure):
                return disable(.mediaLayout(failure))
            }
        }
        guard let partition = PartitionBlockDevice(
                  base: device,
                  partitionRange: dataPartition.range
              )
        else { return disable(.partitionBounds) }
        rawDevice = nil
        partitionDevice = partition
        selectedDataPartitionRange = dataPartition.range
        stage = .signedVolume
        return .partitionReady(
            startBlock: dataPartition.range.startBlock,
            blockCount: dataPartition.range.blockCount
        )
    }

    private mutating func openSignedVolume() -> DeferredPersistentLogEvent {
        guard let partition = partitionDevice else {
            return disable(.partitionBounds)
        }
        let started = PersistentLogStoreRecovery<Partition>.begin(
            device: partition,
            scratch: scratch
        )
        switch started {
        case .recovery(let value):
            partitionDevice = nil
            recovery = value
            signedDataVolumeLayout = value.volumeLayout
            stage = .recovery
            return .superblockReady(
                kernelLogBlockCount: value.volumeLayout.kernelLogBlockCount
            )
        case .failure(let failure):
            return disable(.signedVolume(failure))
        }
    }

    private mutating func recover(
        maximumBlockCount: UInt64
    ) -> DeferredPersistentLogEvent {
        guard var active = recovery else {
            return disable(.partitionBounds)
        }
        switch active.advance(maximumBlockCount: maximumBlockCount) {
        case .progress(let scanned, let total):
            recovery = active
            return .recoveryProgress(
                scannedBlockCount: scanned,
                totalBlockCount: total
            )
        case .store(let opened):
            recovery = nil
            let newest = opened.newestSequence
            store = opened
            stage = .ready
            return .recoveryReady(newestPersistentSequence: newest)
        case .failure(let failure):
            return disable(.signedVolume(failure))
        }
    }

    private mutating func flush(
        maximumAppendCount: Int
    ) -> DeferredPersistentLogEvent {
        guard !volatileSequenceSpaceConsumed,
              var activeStore = store,
              let statistics = source.retainedLogStatistics()
        else {
            if volatileSequenceSpaceConsumed { return .idle }
            return disable(.retainedLogUnavailable)
        }
        guard let oldest = statistics.oldestSequence,
              let newest = statistics.newestSequence
        else { return .idle }

        if nextVolatileSequence == nil { nextVolatileSequence = oldest }
        guard var sequence = nextVolatileSequence else { return .idle }
        if sequence < oldest {
            nextVolatileSequence = oldest
            return .volatileEntriesLost(oldestAvailableSequence: oldest)
        }
        guard sequence <= newest else { return .idle }

        var appendedCount = 0
        var lastEvent = DeferredPersistentLogEvent.idle
        while appendedCount < maximumAppendCount, sequence <= newest {
            guard let lookup = source.retainedLogEntry(sequence: sequence) else {
                return disable(.retainedLogUnavailable)
            }
            switch lookup {
            case .lost(let available):
                nextVolatileSequence = available
                store = activeStore
                return .volatileEntriesLost(
                    oldestAvailableSequence: available
                )
            case .notYetWritten:
                store = activeStore
                return lastEvent
            case .entry(let entry):
                let appended = activeStore.appendKernelLogEntry(entry)
                guard case .appended(let persistentSequence) = appended else {
                    return disable(.append(appended))
                }
                lastEvent = .flushed(
                    volatileSequence: sequence,
                    persistentSequence: persistentSequence
                )
                appendedCount += 1
                if sequence == UInt64.max {
                    volatileSequenceSpaceConsumed = true
                    break
                }
                sequence += 1
                nextVolatileSequence = sequence
            }
        }
        store = activeStore
        return lastEvent
    }

    private mutating func disable(
        _ failure: DeferredPersistentLogFailure
    ) -> DeferredPersistentLogEvent {
        // Drop every device-bearing value. Subsequent service calls are idle,
        // so no failed/ambiguous media path can regain write authority.
        rawDevice = nil
        partitionDevice = nil
        recovery = nil
        store = nil
        selectedDataPartitionRange = nil
        signedDataVolumeLayout = nil
        stage = .disabled
        return .disabled(failure)
    }
}
