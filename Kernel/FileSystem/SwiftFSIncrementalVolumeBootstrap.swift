enum SwiftFSIncrementalVolumeBootstrapStep<Device: BlockDevice> {
    /// The caller should schedule exactly one later cooperative pass.
    case advanced
    case ready(
        provider: SwiftFSPersistentProvider<Device>,
        state: SwiftFSPersistentVolumeState
    )
    case failure(SwiftFSPersistentVolumeBootstrapFailure)
}

private enum SwiftFSIncrementalVolumeBootstrapPhase {
    case checkConfiguration
    case readSuperblock(UInt8)
    case selectSuperblock
    case validateMetadata(UInt32)
    case validateData(
        record: SwiftFSNodeRecord,
        fileBlockIndex: UInt64,
        nextSlot: UInt32,
        packedDataBlockAfterFile: UInt64
    )
    case validateHierarchyCurrent(UInt32)
    case validateHierarchyParent(SwiftFSNodeRecord)
    case validateHierarchyAncestor(
        record: SwiftFSNodeRecord,
        ancestor: UInt32,
        depth: UInt32
    )
    case validateHierarchySibling(
        record: SwiftFSNodeRecord,
        otherSlot: UInt32
    )
    case publishProvider
    case prepareFormat
    case formatInvalidateSuperblock(UInt8)
    case formatSynchronizeInvalidation
    case formatMetadata(UInt32)
    case formatSynchronizeSnapshot
    case formatPublishSuperblock
    case formatSynchronizePublication
    case resolved
}

/// Resumable, allocation-free SwiftFS mount/blank-format bootstrap.
///
/// Every call to `serviceOnce()` performs at most one `BlockDevice` operation:
/// one block read, one block write, or one synchronize. Snapshot validation is
/// equivalent to the synchronous provider mount: it validates both
/// superblocks, falls back from a torn newest snapshot, checks every metadata
/// and file-data block, and verifies hierarchy, cycles, and sibling-name
/// uniqueness. A caller must stop servicing after a terminal ready/failure
/// event and keep `scratch` alive for the lifetime of a ready provider.
struct SwiftFSIncrementalVolumeBootstrap<Device: BlockDevice> {
    private var device: Device
    private let volumeIdentifier: VFSVolumeIdentifier
    private let nodeCapacity: UInt32
    private let accessMode: SwiftFSAccessMode
    private let scratch: UnsafeMutableRawBufferPointer
    private var phase: SwiftFSIncrementalVolumeBootstrapPhase =
        .checkConfiguration
    private var firstCandidate: SwiftFSSuperblock?
    private var secondCandidate: SwiftFSSuperblock?
    private var activeCandidate: SwiftFSSuperblock?
    private var fallbackCandidate: SwiftFSSuperblock?
    private var mediaPrefixIsBlank = true
    private var packedDataBlock: UInt64 = 0
    private var formatLayout: SwiftFSLayout?
    private var didFormat = false

    init(
        device: Device,
        volumeIdentifier: VFSVolumeIdentifier,
        nodeCapacity: UInt32,
        accessMode: SwiftFSAccessMode = .readWrite,
        scratch: UnsafeMutableRawBufferPointer
    ) {
        self.device = device
        self.volumeIdentifier = volumeIdentifier
        self.nodeCapacity = nodeCapacity
        self.accessMode = accessMode
        self.scratch = scratch
    }

    mutating func serviceOnce()
        -> SwiftFSIncrementalVolumeBootstrapStep<Device>
    {
        switch phase {
        case .checkConfiguration:
            guard scratch.count
                    / device.geometry.logicalBlockByteCount >= 2,
                  scratch.baseAddress != nil
            else { return failMount(.invalidScratch) }
            phase = .readSuperblock(0)
            return .advanced

        case .readSuperblock(let block):
            return readSuperblock(block)

        case .selectSuperblock:
            return selectSuperblock()

        case .validateMetadata(let slot):
            return validateMetadata(slot: slot)

        case .validateData(
            let record,
            let fileBlockIndex,
            let nextSlot,
            let packedDataBlockAfterFile
        ):
            return validateData(
                record: record,
                fileBlockIndex: fileBlockIndex,
                nextSlot: nextSlot,
                packedDataBlockAfterFile: packedDataBlockAfterFile
            )

        case .validateHierarchyCurrent(let slot):
            return validateHierarchyCurrent(slot: slot)

        case .validateHierarchyParent(let record):
            return validateHierarchyParent(record: record)

        case .validateHierarchyAncestor(
            let record,
            let ancestor,
            let depth
        ):
            return validateHierarchyAncestor(
                record: record,
                ancestor: ancestor,
                depth: depth
            )

        case .validateHierarchySibling(let record, let otherSlot):
            return validateHierarchySibling(
                record: record,
                otherSlot: otherSlot
            )

        case .publishProvider:
            return publishProvider()

        case .prepareFormat:
            guard let layout = SwiftFSLayout(
                      geometry: device.geometry,
                      nodeCapacity: nodeCapacity
                  )
            else { return fail(.format(.invalidLayout)) }
            formatLayout = layout
            phase = .formatInvalidateSuperblock(0)
            return .advanced

        case .formatInvalidateSuperblock(let block):
            SwiftFSOnDisk.zero(firstScratch)
            let result = writeFirstScratch(to: UInt64(block))
            guard result == .success else {
                return fail(
                    .format(
                        .writeFailed(block: UInt64(block), result: result)
                    )
                )
            }
            phase = block == 0
                ? .formatInvalidateSuperblock(1)
                : .formatSynchronizeInvalidation
            return .advanced

        case .formatSynchronizeInvalidation:
            let result = device.synchronize()
            guard result == .success else {
                return fail(.format(.synchronizeFailed(result)))
            }
            phase = .formatMetadata(1)
            return .advanced

        case .formatMetadata(let slot):
            return formatMetadata(slot: slot)

        case .formatSynchronizeSnapshot:
            let result = device.synchronize()
            guard result == .success else {
                return fail(.format(.synchronizeFailed(result)))
            }
            phase = .formatPublishSuperblock
            return .advanced

        case .formatPublishSuperblock:
            guard let layout = formatLayout else {
                return fail(.format(.invalidLayout))
            }
            SwiftFSOnDisk.encodeSuperblock(
                SwiftFSSuperblock(
                    layout: layout,
                    volumeIdentifier: volumeIdentifier,
                    sequence: 1,
                    activeBank: 0
                ),
                into: firstScratch
            )
            let result = writeFirstScratch(to: 0)
            guard result == .success else {
                return fail(
                    .format(.writeFailed(block: 0, result: result))
                )
            }
            phase = .formatSynchronizePublication
            return .advanced

        case .formatSynchronizePublication:
            let result = device.synchronize()
            guard result == .success else {
                return fail(.format(.synchronizeFailed(result)))
            }
            didFormat = true
            firstCandidate = nil
            secondCandidate = nil
            activeCandidate = nil
            fallbackCandidate = nil
            mediaPrefixIsBlank = true
            formatLayout = nil
            phase = .readSuperblock(0)
            return .advanced

        case .resolved:
            return .advanced
        }
    }

    private var firstScratch: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: scratch.baseAddress!,
            count: device.geometry.logicalBlockByteCount
        )
    }

    private var secondScratch: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: scratch.baseAddress!.advanced(
                by: device.geometry.logicalBlockByteCount
            ),
            count: device.geometry.logicalBlockByteCount
        )
    }

    private mutating func readSuperblock(
        _ block: UInt8
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        let logicalBlock = UInt64(block)
        let result = device.readBlock(
            at: logicalBlock,
            into: firstScratch
        )
        guard result == .success else {
            return failMount(
                .readFailed(block: logicalBlock, result: result)
            )
        }
        if !blockIsZero(firstScratch) { mediaPrefixIsBlank = false }
        let decoded = SwiftFSOnDisk.decodeSuperblock(
            firstScratch,
            geometry: device.geometry
        )
        let positioned = decoded?.activeBank == block ? decoded : nil
        if block == 0 {
            firstCandidate = positioned
            phase = .readSuperblock(1)
        } else {
            secondCandidate = positioned
            phase = .selectSuperblock
        }
        return .advanced
    }

    private mutating func selectSuperblock()
        -> SwiftFSIncrementalVolumeBootstrapStep<Device>
    {
        guard firstCandidate != nil || secondCandidate != nil else {
            if didFormat { return failMount(.noValidSuperblock) }
            guard mediaPrefixIsBlank else {
                return fail(.nonblankMediaWithoutValidSuperblock)
            }
            phase = .prepareFormat
            return .advanced
        }
        if let firstCandidate, let secondCandidate {
            guard firstCandidate.layout == secondCandidate.layout,
                  firstCandidate.volumeIdentifier
                    == secondCandidate.volumeIdentifier,
                  firstCandidate.sequence != secondCandidate.sequence
                    || firstCandidate == secondCandidate
            else { return failMount(.conflictingSuperblocks) }
        }

        switch (firstCandidate, secondCandidate) {
        case (.some(let first), .some(let second)):
            if first.sequence >= second.sequence {
                activeCandidate = first
                fallbackCandidate = second.sequence == first.sequence
                    ? nil
                    : second
            } else {
                activeCandidate = second
                fallbackCandidate = first
            }
        case (.some(let only), .none):
            activeCandidate = only
            fallbackCandidate = nil
        case (.none, .some(let only)):
            activeCandidate = only
            fallbackCandidate = nil
        case (.none, .none):
            return failMount(.noValidSuperblock)
        }

        guard activeCandidate?.volumeIdentifier == volumeIdentifier else {
            return failMount(
                .unexpectedVolume(
                    found: activeCandidate!.volumeIdentifier
                )
            )
        }
        packedDataBlock = 0
        phase = .validateMetadata(1)
        return .advanced
    }

    private mutating func validateMetadata(
        slot: UInt32
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        guard let superblock = activeCandidate else {
            return rejectActiveSnapshot()
        }
        guard slot <= superblock.layout.nodeCapacity else {
            phase = .validateHierarchyCurrent(2)
            return .advanced
        }
        guard let block = superblock.layout.metadataBlock(
                  for: slot,
                  bank: superblock.activeBank
              )
        else { return rejectActiveSnapshot() }
        let read = device.readBlock(at: block, into: secondScratch)
        guard read == .success,
              let decoded = SwiftFSOnDisk.decodeNode(
                  secondScratch,
                  expectedSlot: slot,
                  layout: superblock.layout
              )
        else { return rejectActiveSnapshot() }

        switch decoded {
        case .empty:
            guard slot != SwiftFSOnDisk.rootSlot else {
                return rejectActiveSnapshot()
            }
            phase = .validateMetadata(slot + 1)
        case .node(let record):
            if slot == SwiftFSOnDisk.rootSlot {
                guard record.kind == .directory,
                      record.parentSlot == SwiftFSOnDisk.rootSlot
                else { return rejectActiveSnapshot() }
            }
            guard record.kind == .regularFile else {
                phase = .validateMetadata(slot + 1)
                return .advanced
            }
            if record.dataBlockCount == 0 {
                guard record.firstDataBlock == 0 else {
                    return rejectActiveSnapshot()
                }
                phase = .validateMetadata(slot + 1)
                return .advanced
            }
            guard record.firstDataBlock == packedDataBlock,
                  record.dataBlockCount
                    <= superblock.layout.dataBankBlockCount
                        - packedDataBlock
            else { return rejectActiveSnapshot() }
            phase = .validateData(
                record: record,
                fileBlockIndex: 0,
                nextSlot: slot + 1,
                packedDataBlockAfterFile:
                    packedDataBlock + record.dataBlockCount
            )
        }
        return .advanced
    }

    private mutating func validateData(
        record: SwiftFSNodeRecord,
        fileBlockIndex: UInt64,
        nextSlot: UInt32,
        packedDataBlockAfterFile: UInt64
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        guard let superblock = activeCandidate,
              fileBlockIndex < record.dataBlockCount,
              record.firstDataBlock <= UInt64.max - fileBlockIndex,
              let block = superblock.layout.dataBlock(
                  relativeBlock: record.firstDataBlock + fileBlockIndex,
                  bank: superblock.activeBank
              ),
              let expectedPayload = SwiftFSOnDisk.payloadByteCount(
                  fileByteCount: record.byteCount,
                  fileBlockIndex: fileBlockIndex,
                  layout: superblock.layout
              )
        else { return rejectActiveSnapshot() }
        let read = device.readBlock(at: block, into: firstScratch)
        guard read == .success,
              SwiftFSOnDisk.validateDataBlock(
                  firstScratch,
                  nodeSlot: record.slot,
                  fileBlockIndex: fileBlockIndex,
                  nodeGeneration: record.generation,
                  expectedPayloadByteCount: expectedPayload,
                  layout: superblock.layout
              )
        else { return rejectActiveSnapshot() }
        let nextDataBlock = fileBlockIndex + 1
        if nextDataBlock < record.dataBlockCount {
            phase = .validateData(
                record: record,
                fileBlockIndex: nextDataBlock,
                nextSlot: nextSlot,
                packedDataBlockAfterFile: packedDataBlockAfterFile
            )
        } else {
            packedDataBlock = packedDataBlockAfterFile
            phase = .validateMetadata(nextSlot)
        }
        return .advanced
    }

    private mutating func validateHierarchyCurrent(
        slot: UInt32
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        guard let superblock = activeCandidate else {
            return rejectActiveSnapshot()
        }
        guard slot <= superblock.layout.nodeCapacity else {
            phase = .publishProvider
            return .advanced
        }
        guard let block = superblock.layout.metadataBlock(
                  for: slot,
                  bank: superblock.activeBank
              )
        else { return rejectActiveSnapshot() }
        let read = device.readBlock(at: block, into: firstScratch)
        guard read == .success,
              let decoded = SwiftFSOnDisk.decodeNode(
                  firstScratch,
                  expectedSlot: slot,
                  layout: superblock.layout
              )
        else { return rejectActiveSnapshot() }
        switch decoded {
        case .empty:
            phase = .validateHierarchyCurrent(slot + 1)
        case .node(let record):
            phase = .validateHierarchyParent(record)
        }
        return .advanced
    }

    private mutating func validateHierarchyParent(
        record: SwiftFSNodeRecord
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        guard let superblock = activeCandidate,
              let block = superblock.layout.metadataBlock(
                  for: record.parentSlot,
                  bank: superblock.activeBank
              )
        else { return rejectActiveSnapshot() }
        let read = device.readBlock(at: block, into: secondScratch)
        guard read == .success,
              let decoded = SwiftFSOnDisk.decodeNode(
                  secondScratch,
                  expectedSlot: record.parentSlot,
                  layout: superblock.layout
              ),
              case .node(let parent) = decoded,
              parent.kind == .directory
        else { return rejectActiveSnapshot() }
        phase = .validateHierarchyAncestor(
            record: record,
            ancestor: record.parentSlot,
            depth: 0
        )
        return .advanced
    }

    private mutating func validateHierarchyAncestor(
        record: SwiftFSNodeRecord,
        ancestor: UInt32,
        depth: UInt32
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        guard let superblock = activeCandidate else {
            return rejectActiveSnapshot()
        }
        guard ancestor != SwiftFSOnDisk.rootSlot else {
            phase = .validateHierarchySibling(
                record: record,
                otherSlot: record.slot + 1
            )
            return .advanced
        }
        guard ancestor != record.slot,
              depth < superblock.layout.nodeCapacity,
              let block = superblock.layout.metadataBlock(
                  for: ancestor,
                  bank: superblock.activeBank
              )
        else { return rejectActiveSnapshot() }
        let read = device.readBlock(at: block, into: secondScratch)
        guard read == .success,
              let decoded = SwiftFSOnDisk.decodeNode(
                  secondScratch,
                  expectedSlot: ancestor,
                  layout: superblock.layout
              ),
              case .node(let parent) = decoded,
              parent.kind == .directory
        else { return rejectActiveSnapshot() }
        phase = .validateHierarchyAncestor(
            record: record,
            ancestor: parent.parentSlot,
            depth: depth + 1
        )
        return .advanced
    }

    private mutating func validateHierarchySibling(
        record: SwiftFSNodeRecord,
        otherSlot: UInt32
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        guard let superblock = activeCandidate else {
            return rejectActiveSnapshot()
        }
        guard otherSlot <= superblock.layout.nodeCapacity else {
            phase = .validateHierarchyCurrent(record.slot + 1)
            return .advanced
        }
        guard let block = superblock.layout.metadataBlock(
                  for: otherSlot,
                  bank: superblock.activeBank
              )
        else { return rejectActiveSnapshot() }
        let read = device.readBlock(at: block, into: secondScratch)
        guard read == .success,
              let decoded = SwiftFSOnDisk.decodeNode(
                  secondScratch,
                  expectedSlot: otherSlot,
                  layout: superblock.layout
              )
        else { return rejectActiveSnapshot() }
        if case .node(let other) = decoded,
           other.parentSlot == record.parentSlot,
           SwiftFSOnDisk.namesAreEqual(
               firstScratch,
               first: record,
               secondScratch,
               second: other
           ) {
            return rejectActiveSnapshot()
        }
        phase = .validateHierarchySibling(
            record: record,
            otherSlot: otherSlot + 1
        )
        return .advanced
    }

    private mutating func publishProvider()
        -> SwiftFSIncrementalVolumeBootstrapStep<Device>
    {
        guard let superblock = activeCandidate,
              let provider = SwiftFSPersistentProvider<Device>
                .mountedValidatedSnapshot(
                    device: device,
                    superblock: superblock,
                    accessMode: accessMode,
                    scratch: scratch
                )
        else { return rejectActiveSnapshot() }
        phase = .resolved
        return .ready(
            provider: provider,
            state: didFormat ? .formatted : .mounted
        )
    }

    private mutating func formatMetadata(
        slot: UInt32
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        guard let layout = formatLayout,
              let block = layout.metadataBlock(for: slot, bank: 0)
        else { return fail(.format(.invalidLayout)) }
        if slot == SwiftFSOnDisk.rootSlot {
            SwiftFSOnDisk.encodeNode(
                SwiftFSOnDisk.initialRootRecord(),
                name: nil,
                into: firstScratch
            )
        } else {
            SwiftFSOnDisk.zero(firstScratch)
        }
        let result = writeFirstScratch(to: block)
        guard result == .success else {
            return fail(
                .format(.writeFailed(block: block, result: result))
            )
        }
        phase = slot < layout.nodeCapacity
            ? .formatMetadata(slot + 1)
            : .formatSynchronizeSnapshot
        return .advanced
    }

    private mutating func writeFirstScratch(
        to block: UInt64
    ) -> BlockDeviceIOResult {
        device.writeBlock(
            at: block,
            from: UnsafeRawBufferPointer(
                start: firstScratch.baseAddress,
                count: device.geometry.logicalBlockByteCount
            )
        )
    }

    private func blockIsZero(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        var index = 0
        while index < device.geometry.logicalBlockByteCount {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    private mutating func rejectActiveSnapshot()
        -> SwiftFSIncrementalVolumeBootstrapStep<Device>
    {
        if let fallbackCandidate {
            activeCandidate = fallbackCandidate
            self.fallbackCandidate = nil
            packedDataBlock = 0
            phase = .validateMetadata(1)
            return .advanced
        }
        return failMount(.noValidSnapshot)
    }

    private mutating func failMount(
        _ failure: SwiftFSMountFailure
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        if didFormat {
            return fail(.postFormatMount(failure))
        }
        return fail(.mount(failure))
    }

    private mutating func fail(
        _ failure: SwiftFSPersistentVolumeBootstrapFailure
    ) -> SwiftFSIncrementalVolumeBootstrapStep<Device> {
        phase = .resolved
        return .failure(failure)
    }
}
