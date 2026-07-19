enum SwiftFSPersistentVolumeState: UInt8, Equatable {
    case mounted = 1
    case formatted = 2
}

enum SwiftFSPersistentVolumeBootstrapFailure: Equatable {
    case mount(SwiftFSMountFailure)
    case nonblankMediaWithoutValidSuperblock
    case blankProbe(BlockDeviceBlankProbeResult)
    case format(SwiftFSFormatFailure)
    case postFormatMount(SwiftFSMountFailure)
}

enum SwiftFSPersistentVolumeBootstrapResult<Device: BlockDevice> {
    case ready(
        provider: SwiftFSPersistentProvider<Device>,
        state: SwiftFSPersistentVolumeState
    )
    case failure(SwiftFSPersistentVolumeBootstrapFailure)
}

/// Opens one bounded filesystem authority and formats it only if both SwiftFS
/// superblock positions are all zero. The same routine is used regardless of
/// whether `Device` ultimately reaches VirtIO, SDHCI, RAM, or another block
/// transport.
enum SwiftFSPersistentVolumeBootstrap {
    static func openOrFormatBlank<Device: BlockDevice>(
        _ suppliedDevice: Device,
        volumeIdentifier: VFSVolumeIdentifier,
        nodeCapacity: UInt32,
        accessMode: SwiftFSAccessMode = .readWrite,
        scratch: UnsafeMutableRawBufferPointer
    ) -> SwiftFSPersistentVolumeBootstrapResult<Device> {
        switch SwiftFSPersistentProvider<Device>.mount(
            suppliedDevice,
            expectedVolumeIdentifier: volumeIdentifier,
            accessMode: accessMode,
            scratch: scratch
        ) {
        case .mounted(let provider):
            return .ready(provider: provider, state: .mounted)
        case .failure(let failure):
            guard failure == .noValidSuperblock else {
                return .failure(.mount(failure))
            }
        }

        var device = suppliedDevice
        switch BlockDeviceBlankProbe.firstBlocks(
            &device,
            blockCount: SwiftFSLayout.superblockCount,
            scratch: scratch
        ) {
        case .blank:
            break
        case .containsData:
            return .failure(.nonblankMediaWithoutValidSuperblock)
        case .invalidScratch:
            return .failure(.blankProbe(.invalidScratch))
        case .readFailed(let block, let result):
            return .failure(
                .blankProbe(.readFailed(block: block, result: result))
            )
        }

        switch SwiftFSPersistentProvider<Device>.format(
            &device,
            volumeIdentifier: volumeIdentifier,
            nodeCapacity: nodeCapacity,
            scratch: scratch
        ) {
        case .formatted:
            break
        case .failure(let failure):
            return .failure(.format(failure))
        }

        switch SwiftFSPersistentProvider<Device>.mount(
            device,
            expectedVolumeIdentifier: volumeIdentifier,
            accessMode: accessMode,
            scratch: scratch
        ) {
        case .mounted(let provider):
            return .ready(provider: provider, state: .formatted)
        case .failure(let failure):
            return .failure(.postFormatMount(failure))
        }
    }
}
