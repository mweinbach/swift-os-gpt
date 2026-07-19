enum BlockDeviceBlankProbeResult: Equatable {
    case blank
    case containsData
    case invalidScratch
    case readFailed(block: UInt64, result: BlockDeviceIOResult)
}

/// Reads a bounded prefix before any formatter is allowed to claim media.
/// A missing or damaged superblock is not proof that a device is disposable;
/// automatic initialization is permitted only when every inspected byte is
/// zero. Board and transport runtimes share this policy.
enum BlockDeviceBlankProbe {
    static func firstBlocks<Device: BlockDevice>(
        _ device: inout Device,
        blockCount: UInt64,
        scratch: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceBlankProbeResult {
        guard blockCount > 0,
              blockCount <= device.geometry.logicalBlockCount,
              scratch.count >= device.geometry.logicalBlockByteCount
        else { return .invalidScratch }

        var block: UInt64 = 0
        while block < blockCount {
            let read = device.readBlock(at: block, into: scratch)
            guard read == .success else {
                return .readFailed(block: block, result: read)
            }
            var byteIndex = 0
            while byteIndex < device.geometry.logicalBlockByteCount {
                if scratch[byteIndex] != 0 { return .containsData }
                byteIndex += 1
            }
            block += 1
        }
        return .blank
    }
}

enum SwiftOSDataVolumeBootstrapFailure: Equatable {
    case open(SwiftOSDataVolumeOpenFailure)
    case nonblankMediaWithoutValidSuperblock
    case blankProbe(BlockDeviceBlankProbeResult)
    case format(SwiftOSDataVolumeFormatResult)
}

enum SwiftOSDataVolumeBootstrapResult: Equatable {
    case opened(SwiftOSDataVolumeLayout)
    case initialized(SwiftOSDataVolumeLayout)
    case failure(SwiftOSDataVolumeBootstrapFailure)
}

/// Safely opens the signed data-volume container or initializes a provably
/// blank device. This is deliberately transport-neutral: QEMU may pass a raw
/// data disk while Raspberry Pi passes the MBR-bounded 0xDA partition.
enum SwiftOSDataVolumeBootstrap {
    static func openOrInitializeBlank<Device: BlockDevice>(
        _ device: inout Device,
        kernelLogBlockCount: UInt64,
        scratch: UnsafeMutableRawBufferPointer
    ) -> SwiftOSDataVolumeBootstrapResult {
        switch SwiftOSDataVolume.open(&device, scratch: scratch) {
        case .volume(let layout):
            return .opened(layout)
        case .failure(let failure):
            guard failure == .missingSuperblock else {
                return .failure(.open(failure))
            }
        }

        switch BlockDeviceBlankProbe.firstBlocks(
            &device,
            blockCount: SwiftOSDataVolumeLayout.superblockCount,
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

        let formatted = SwiftOSDataVolume.initializeEmpty(
            &device,
            kernelLogBlockCount: kernelLogBlockCount,
            scratch: scratch
        )
        switch formatted {
        case .formatted(let layout):
            return .initialized(layout)
        default:
            return .failure(.format(formatted))
        }
    }
}
