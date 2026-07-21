/// Board-neutral ordering policy for media whose firmware recognizes a small
/// set of blocks as the bootability commit point. Direct layouts copy in block
/// order. Deferred layouts keep both activation blocks zero while payload data
/// is staged, then synchronize the first commit block and the last commit block
/// in separate operations. Raspberry Pi FAT32 uses backup sector 6 first and
/// primary sector 0 last; another board may provide different offsets.
enum BootSlotWritePolicy: Equatable {
    case direct
    case deferredActivation(
        firstCommitBlock: UInt64,
        lastCommitBlock: UInt64
    )

    func isValid(blockCount: UInt64) -> Bool {
        switch self {
        case .direct:
            return blockCount != 0
        case .deferredActivation(let first, let last):
            return blockCount > 2
                && first < blockCount
                && last < blockCount
                && first != last
        }
    }

    func relativeBlock(
        atProgress progress: UInt64,
        blockCount: UInt64
    ) -> UInt64? {
        guard isValid(blockCount: blockCount), progress < blockCount else {
            return nil
        }
        switch self {
        case .direct:
            return progress
        case .deferredActivation(let first, let last):
            let payloadCount = blockCount - 2
            if progress == payloadCount { return first }
            if progress == payloadCount + 1 { return last }
            let low = first < last ? first : last
            let high = first < last ? last : first
            var relative = progress
            if relative >= low { relative += 1 }
            if relative >= high { relative += 1 }
            return relative
        }
    }

    func boundedOperationCount(
        atProgress progress: UInt64,
        blockCount: UInt64,
        requested: UInt64
    ) -> UInt64? {
        guard isValid(blockCount: blockCount), progress < blockCount,
              requested != 0
        else { return nil }
        switch self {
        case .direct:
            let remaining = blockCount - progress
            return requested < remaining ? requested : remaining
        case .deferredActivation:
            let payloadCount = blockCount - 2
            guard progress < payloadCount else { return 1 }
            let remaining = payloadCount - progress
            return requested < remaining ? requested : remaining
        }
    }

    var activationBlocks: (first: UInt64, last: UInt64)? {
        switch self {
        case .direct: return nil
        case .deferredActivation(let first, let last):
            return (first, last)
        }
    }
}

struct VerifiedSlotCopyPlan: Equatable {
    let source: BlockDeviceRange
    let destination: BlockDeviceRange
    let writePolicy: BootSlotWritePolicy

    init?(
        source: BlockDeviceRange,
        destination: BlockDeviceRange,
        writePolicy: BootSlotWritePolicy = .direct
    ) {
        guard source.blockCount == destination.blockCount,
              !source.overlaps(destination),
              writePolicy.isValid(blockCount: source.blockCount)
        else { return nil }
        self.source = source
        self.destination = destination
        self.writePolicy = writePolicy
    }

    var blockCount: UInt64 { source.blockCount }
}

enum VerifiedSlotCopyFailure: Equatable {
    case invalidScratch
    case invalidCursor
    case invalidChunkLimit
    case invalidateDestination(block: UInt64, result: BlockDeviceIOResult)
    case activationStateMismatch(block: UInt64)
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
        guard let count = plan.writePolicy.boundedOperationCount(
                  atProgress: nextBlock,
                  blockCount: plan.blockCount,
                  requested: maximumBlockCount
              )
        else { return .failure(.invalidCursor) }
        let first = UnsafeMutableRawBufferPointer(
            start: base,
            count: blockBytes
        )
        let second = UnsafeMutableRawBufferPointer(
            start: base.advanced(by: blockBytes),
            count: blockBytes
        )

        if let activation = plan.writePolicy.activationBlocks {
            let payloadCount = plan.blockCount - 2
            if nextBlock == 0 {
                if let failure = invalidateActivationBlocks(
                    on: &device,
                    destination: plan.destination,
                    activation: activation,
                    zero: first,
                    readback: second
                ) {
                    return .failure(failure)
                }
            } else if nextBlock < payloadCount {
                if let failure = requireInvalidActivationBlocks(
                    on: &device,
                    destination: plan.destination,
                    activation: activation,
                    scratch: first
                ) {
                    return .failure(failure)
                }
            } else if nextBlock == payloadCount {
                if let failure = requireZeroBlock(
                    on: &device,
                    block: plan.destination.startBlock + activation.last,
                    scratch: first
                ) {
                    return .failure(failure)
                }
            } else {
                if let failure = requireSourceMatch(
                    on: &device,
                    sourceBlock: plan.source.startBlock + activation.first,
                    destinationBlock:
                        plan.destination.startBlock + activation.first,
                    source: first,
                    destination: second
                ) {
                    return .failure(failure)
                }
            }
        }

        var offset: UInt64 = 0
        while offset < count {
            guard let relative = plan.writePolicy.relativeBlock(
                      atProgress: nextBlock + offset,
                      blockCount: plan.blockCount
                  )
            else { return .failure(.invalidCursor) }
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
            guard let relative = plan.writePolicy.relativeBlock(
                      atProgress: nextBlock + offset,
                      blockCount: plan.blockCount
                  )
            else { return .failure(.invalidCursor) }
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

    private static func invalidateActivationBlocks<Device: BlockDevice>(
        on device: inout Device,
        destination: BlockDeviceRange,
        activation: (first: UInt64, last: UInt64),
        zero: UnsafeMutableRawBufferPointer,
        readback: UnsafeMutableRawBufferPointer
    ) -> VerifiedSlotCopyFailure? {
        var index = 0
        while index < zero.count {
            zero[index] = 0
            index += 1
        }
        let firstBlock = destination.startBlock + activation.first
        let lastBlock = destination.startBlock + activation.last
        let input = UnsafeRawBufferPointer(
            start: zero.baseAddress,
            count: zero.count
        )
        var result = device.writeBlock(at: firstBlock, from: input)
        guard result == .success else {
            return .invalidateDestination(block: firstBlock, result: result)
        }
        result = device.writeBlock(at: lastBlock, from: input)
        guard result == .success else {
            return .invalidateDestination(block: lastBlock, result: result)
        }
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .synchronize(synchronized)
        }
        var read = device.readBlock(at: firstBlock, into: readback)
        guard read == .success else {
            return .readbackDestination(block: firstBlock, result: read)
        }
        guard isZero(readback) else {
            return .activationStateMismatch(block: firstBlock)
        }
        read = device.readBlock(at: lastBlock, into: readback)
        guard read == .success else {
            return .readbackDestination(block: lastBlock, result: read)
        }
        guard isZero(readback) else {
            return .activationStateMismatch(block: lastBlock)
        }
        return nil
    }

    private static func requireInvalidActivationBlocks<Device: BlockDevice>(
        on device: inout Device,
        destination: BlockDeviceRange,
        activation: (first: UInt64, last: UInt64),
        scratch: UnsafeMutableRawBufferPointer
    ) -> VerifiedSlotCopyFailure? {
        if let failure = requireZeroBlock(
            on: &device,
            block: destination.startBlock + activation.last,
            scratch: scratch
        ) {
            return failure
        }
        return requireZeroBlock(
            on: &device,
            block: destination.startBlock + activation.first,
            scratch: scratch
        )
    }

    private static func requireZeroBlock<Device: BlockDevice>(
        on device: inout Device,
        block: UInt64,
        scratch: UnsafeMutableRawBufferPointer
    ) -> VerifiedSlotCopyFailure? {
        let result = device.readBlock(at: block, into: scratch)
        guard result == .success else {
            return .readbackDestination(block: block, result: result)
        }
        return isZero(scratch) ? nil : .activationStateMismatch(block: block)
    }

    private static func requireSourceMatch<Device: BlockDevice>(
        on device: inout Device,
        sourceBlock: UInt64,
        destinationBlock: UInt64,
        source: UnsafeMutableRawBufferPointer,
        destination: UnsafeMutableRawBufferPointer
    ) -> VerifiedSlotCopyFailure? {
        let sourceRead = device.readBlock(at: sourceBlock, into: source)
        guard sourceRead == .success else {
            return .readSource(block: sourceBlock, result: sourceRead)
        }
        let destinationRead = device.readBlock(
            at: destinationBlock,
            into: destination
        )
        guard destinationRead == .success else {
            return .readbackDestination(
                block: destinationBlock,
                result: destinationRead
            )
        }
        var index = 0
        while index < source.count {
            if source[index] != destination[index] {
                return .activationStateMismatch(block: destinationBlock)
            }
            index += 1
        }
        return nil
    }

    private static func isZero(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        var index = 0
        while index < bytes.count {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }
}
