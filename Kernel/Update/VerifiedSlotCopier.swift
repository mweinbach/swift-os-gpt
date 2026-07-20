struct VerifiedSlotCopyPlan: Equatable {
    let source: BlockDeviceRange
    let destination: BlockDeviceRange

    init?(source: BlockDeviceRange, destination: BlockDeviceRange) {
        guard source.blockCount == destination.blockCount,
              !source.overlaps(destination)
        else { return nil }
        self.source = source
        self.destination = destination
    }

    var blockCount: UInt64 { source.blockCount }
}

enum VerifiedSlotCopyFailure: Equatable {
    case invalidScratch
    case invalidCursor
    case invalidChunkLimit
    case readSource(block: UInt64, result: BlockDeviceIOResult)
    case writeDestination(block: UInt64, result: BlockDeviceIOResult)
    case synchronize(BlockDeviceIOResult)
    case readbackSource(block: UInt64, result: BlockDeviceIOResult)
    case readbackDestination(block: UInt64, result: BlockDeviceIOResult)
    case verificationMismatch(block: UInt64)
}

enum VerifiedSlotCopyResult: Equatable {
    case advanced(nextBlock: UInt64, isComplete: Bool)
    case failure(VerifiedSlotCopyFailure)
}

/// Copies one bounded chunk between disjoint ranges on a single block device,
/// synchronizes it, then compares every source and destination byte. The
/// caller journals the returned cursor only after success. Replaying an
/// unjournaled chunk after power loss is therefore harmless and idempotent.
enum VerifiedSlotCopier {
    /// One MiB at 512-byte sectors. Callers may choose a smaller cooperative
    /// quantum, but cannot turn one invocation into an unbounded card copy.
    static let maximumBlocksPerChunk: UInt64 = 2_048

    static func copyNextChunk<Device: BlockDevice>(
        on device: inout Device,
        plan: VerifiedSlotCopyPlan,
        nextBlock: UInt64,
        maximumBlockCount: UInt64,
        scratch: UnsafeMutableRawBufferPointer
    ) -> VerifiedSlotCopyResult {
        let blockBytes = device.geometry.logicalBlockByteCount
        guard blockBytes <= Int.max / 2,
              scratch.count >= blockBytes * 2,
              let base = scratch.baseAddress
        else { return .failure(.invalidScratch) }
        guard nextBlock < plan.blockCount else {
            return .failure(.invalidCursor)
        }
        guard plan.source.endBlock <= device.geometry.logicalBlockCount,
              plan.destination.endBlock <= device.geometry.logicalBlockCount
        else { return .failure(.invalidCursor) }
        guard maximumBlockCount != 0,
              maximumBlockCount <= maximumBlocksPerChunk
        else {
            return .failure(.invalidChunkLimit)
        }
        let remaining = plan.blockCount - nextBlock
        let count = maximumBlockCount < remaining
            ? maximumBlockCount : remaining
        let first = UnsafeMutableRawBufferPointer(
            start: base,
            count: blockBytes
        )
        let second = UnsafeMutableRawBufferPointer(
            start: base.advanced(by: blockBytes),
            count: blockBytes
        )

        var offset: UInt64 = 0
        while offset < count {
            let relative = nextBlock + offset
            let sourceBlock = plan.source.startBlock + relative
            let destinationBlock = plan.destination.startBlock + relative
            let read = device.readBlock(at: sourceBlock, into: first)
            guard read == .success else {
                return .failure(.readSource(block: sourceBlock, result: read))
            }
            let write = device.writeBlock(
                at: destinationBlock,
                from: UnsafeRawBufferPointer(
                    start: first.baseAddress,
                    count: blockBytes
                )
            )
            guard write == .success else {
                return .failure(.writeDestination(
                    block: destinationBlock,
                    result: write
                ))
            }
            offset += 1
        }
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .failure(.synchronize(synchronized))
        }

        offset = 0
        while offset < count {
            let relative = nextBlock + offset
            let sourceBlock = plan.source.startBlock + relative
            let destinationBlock = plan.destination.startBlock + relative
            let sourceRead = device.readBlock(at: sourceBlock, into: first)
            guard sourceRead == .success else {
                return .failure(.readbackSource(
                    block: sourceBlock,
                    result: sourceRead
                ))
            }
            let destinationRead = device.readBlock(
                at: destinationBlock,
                into: second
            )
            guard destinationRead == .success else {
                return .failure(.readbackDestination(
                    block: destinationBlock,
                    result: destinationRead
                ))
            }
            var byte = 0
            while byte < blockBytes {
                if first[byte] != second[byte] {
                    return .failure(.verificationMismatch(
                        block: destinationBlock
                    ))
                }
                byte += 1
            }
            offset += 1
        }
        let advanced = nextBlock + count
        return .advanced(
            nextBlock: advanced,
            isComplete: advanced == plan.blockCount
        )
    }
}
