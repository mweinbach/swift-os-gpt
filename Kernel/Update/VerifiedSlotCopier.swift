/// Describes the small set of bytes that are physically different between two
/// semantically identical boot slots. Content digests normalize these bytes;
/// copies validate the source value and encode the destination value. Boards
/// without location-specific metadata retain exact byte semantics.
enum BootSlotMetadataPolicy: Equatable {
    case none
    case fat32HiddenSectors(
        primaryBootBlock: UInt64,
        backupBootBlock: UInt64
    )

    private static let fat32HiddenSectorsOffset = 28

    func isValid(blockCount: UInt64) -> Bool {
        switch self {
        case .none:
            return true
        case .fat32HiddenSectors(let primary, let backup):
            return primary < blockCount
                && backup < blockCount
                && primary != backup
        }
    }

    /// Location-specific FAT metadata is safe only when the sectors carrying
    /// it are also the two activation commits. The backup must be published
    /// first and the primary last; direct, reversed, or partially matching
    /// policies could expose a bootable slot with stale physical metadata.
    func isCompatible(with writePolicy: BootSlotWritePolicy) -> Bool {
        switch self {
        case .none:
            return true
        case .fat32HiddenSectors(let primary, let backup):
            guard case .deferredActivation(let first, let last) = writePolicy
            else { return false }
            return first == backup && last == primary
        }
    }

    /// Validates the source's physical metadata and rewrites it for the
    /// destination before a copied block is written or compared.
    func relocateForCopy(
        relativeBlock: UInt64,
        sourceStartBlock: UInt64,
        destinationStartBlock: UInt64,
        bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        switch self {
        case .none:
            return true
        case .fat32HiddenSectors(let primary, let backup):
            guard relativeBlock == primary || relativeBlock == backup else {
                return true
            }
            guard sourceStartBlock <= UInt64(UInt32.max),
                  destinationStartBlock <= UInt64(UInt32.max),
                  Self.readLE32(
                      bytes,
                      at: Self.fat32HiddenSectorsOffset
                  ) == UInt32(sourceStartBlock)
            else { return false }
            return Self.writeLE32(
                UInt32(destinationStartBlock),
                into: bytes,
                at: Self.fat32HiddenSectorsOffset
            )
        }
    }

    /// Produces the location-neutral byte stream used by release and journal
    /// identities, while still rejecting a slot whose BPB names another LBA.
    func normalizeForContentDigest(
        relativeBlock: UInt64,
        slotStartBlock: UInt64,
        bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        switch self {
        case .none:
            return true
        case .fat32HiddenSectors(let primary, let backup):
            guard relativeBlock == primary || relativeBlock == backup else {
                return true
            }
            guard slotStartBlock <= UInt64(UInt32.max),
                  Self.readLE32(
                      bytes,
                      at: Self.fat32HiddenSectorsOffset
                  ) == UInt32(slotStartBlock)
            else { return false }
            return Self.writeLE32(
                0,
                into: bytes,
                at: Self.fat32HiddenSectorsOffset
            )
        }
    }

    private static func readLE32(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func writeLE32(
        _ value: UInt32,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> Bool {
        guard offset >= 0, offset <= bytes.count - 4 else { return false }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        return true
    }
}

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
    let metadataPolicy: BootSlotMetadataPolicy

    init?(
        source: BlockDeviceRange,
        destination: BlockDeviceRange,
        writePolicy: BootSlotWritePolicy = .direct,
        metadataPolicy: BootSlotMetadataPolicy = .none
    ) {
        guard source.blockCount == destination.blockCount,
              !source.overlaps(destination),
              writePolicy.isValid(blockCount: source.blockCount),
              metadataPolicy.isValid(blockCount: source.blockCount),
              metadataPolicy.isCompatible(with: writePolicy)
        else { return nil }
        self.source = source
        self.destination = destination
        self.writePolicy = writePolicy
        self.metadataPolicy = metadataPolicy
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
    case sourceMetadataMismatch(block: UInt64)
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
                if let failure = preflightSourceActivationBlocks(
                    on: &device,
                    plan: plan,
                    activation: activation,
                    scratch: first
                ) {
                    return .failure(failure)
                }
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
                    plan: plan,
                    relativeBlock: activation.first,
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
            guard plan.metadataPolicy.relocateForCopy(
                      relativeBlock: relative,
                      sourceStartBlock: plan.source.startBlock,
                      destinationStartBlock: plan.destination.startBlock,
                      bytes: first
                  )
            else {
                return .failure(.sourceMetadataMismatch(block: sourceBlock))
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
            guard plan.metadataPolicy.relocateForCopy(
                      relativeBlock: relative,
                      sourceStartBlock: plan.source.startBlock,
                      destinationStartBlock: plan.destination.startBlock,
                      bytes: first
                  )
            else {
                return .failure(.sourceMetadataMismatch(block: sourceBlock))
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

    /// Reads and validates both source activation sectors before invalidating
    /// either destination sector. In particular, a malformed backup or primary
    /// BPB must leave a previously bootable destination byte-for-byte intact.
    private static func preflightSourceActivationBlocks<Device: BlockDevice>(
        on device: inout Device,
        plan: VerifiedSlotCopyPlan,
        activation: (first: UInt64, last: UInt64),
        scratch: UnsafeMutableRawBufferPointer
    ) -> VerifiedSlotCopyFailure? {
        let relativeBlocks = (activation.first, activation.last)
        var index = 0
        while index < 2 {
            let relative = index == 0
                ? relativeBlocks.0
                : relativeBlocks.1
            let sourceBlock = plan.source.startBlock + relative
            let read = device.readBlock(at: sourceBlock, into: scratch)
            guard read == .success else {
                return .readSource(block: sourceBlock, result: read)
            }
            guard plan.metadataPolicy.relocateForCopy(
                      relativeBlock: relative,
                      sourceStartBlock: plan.source.startBlock,
                      destinationStartBlock: plan.destination.startBlock,
                      bytes: scratch
                  )
            else {
                return .sourceMetadataMismatch(block: sourceBlock)
            }
            index += 1
        }
        return nil
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
        plan: VerifiedSlotCopyPlan,
        relativeBlock: UInt64,
        sourceBlock: UInt64,
        destinationBlock: UInt64,
        source: UnsafeMutableRawBufferPointer,
        destination: UnsafeMutableRawBufferPointer
    ) -> VerifiedSlotCopyFailure? {
        let sourceRead = device.readBlock(at: sourceBlock, into: source)
        guard sourceRead == .success else {
            return .readSource(block: sourceBlock, result: sourceRead)
        }
        guard plan.metadataPolicy.relocateForCopy(
                  relativeBlock: relativeBlock,
                  sourceStartBlock: plan.source.startBlock,
                  destinationStartBlock: plan.destination.startBlock,
                  bytes: source
              )
        else { return .sourceMetadataMismatch(block: sourceBlock) }
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
