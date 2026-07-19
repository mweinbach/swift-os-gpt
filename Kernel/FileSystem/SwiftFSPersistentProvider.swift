private enum SwiftFSNodeLoadResult {
    case empty
    case node(SwiftFSNodeRecord)
    case failure(VFSProviderFailure)
}

private enum SwiftFSChildSearchResult {
    case found(slot: UInt32, record: SwiftFSNodeRecord)
    case missing
    case failure(VFSProviderFailure)
}

private enum SwiftFSFreeSlotResult {
    case slot(UInt32)
    case full
    case failure(VFSProviderFailure)
}

private enum SwiftFSSnapshotMutation {
    case create(
        slot: UInt32,
        parentSlot: UInt32,
        kind: VFSNodeKind,
        name: VFSNameView,
        timestamp: VFSTimestamp
    )
    case remove(
        slot: UInt32,
        parentSlot: UInt32,
        timestamp: VFSTimestamp
    )
    case rename(
        slot: UInt32,
        sourceParentSlot: UInt32,
        destinationParentSlot: UInt32,
        destinationName: VFSNameView,
        timestamp: VFSTimestamp
    )
    case write(
        slot: UInt32,
        offset: UInt64,
        input: UnsafeRawBufferPointer,
        modifiedAt: VFSTimestamp?
    )
}

/// A persistent, allocation-free VFS provider over any synchronous block
/// transport. The provider owns the `Device` value and borrows two logical
/// blocks of caller-owned scratch memory until it is discarded.
///
/// The first implementation commits a complete copy-on-write snapshot for
/// every mutation. That is intentionally conservative: it gives the kernel a
/// small, auditable crash-consistency boundary before later work introduces a
/// journal or extent tree for performance.
struct SwiftFSPersistentProvider<Device: BlockDevice>: VFSNodeProvider {
    private(set) var device: Device
    let volumeIdentifier: VFSVolumeIdentifier
    let accessMode: SwiftFSAccessMode
    let layout: SwiftFSLayout
    private var sequence: UInt64
    private var activeBank: UInt8
    private let scratchBase: UnsafeMutableRawPointer
    private(set) var isAvailable = true

    var rootNodeIdentifier: VFSNodeIdentifier {
        VFSNodeIdentifier(
            volume: volumeIdentifier,
            localValue: UInt64(SwiftFSOnDisk.rootSlot)
        )!
    }

    /// Destructively initializes only the supplied block-device authority. A
    /// caller that wants partition isolation should pass a
    /// `PartitionBlockDevice`, never a whole transport.
    static func format(
        _ device: inout Device,
        volumeIdentifier: VFSVolumeIdentifier,
        nodeCapacity: UInt32,
        scratch: UnsafeMutableRawBufferPointer
    ) -> SwiftFSFormatResult {
        guard let layout = SwiftFSLayout(
            geometry: device.geometry,
            nodeCapacity: nodeCapacity
        ) else { return .failure(.invalidLayout) }
        guard let buffers = scratchBuffers(
            scratch,
            blockByteCount: layout.logicalBlockByteCount
        ) else { return .failure(.invalidScratch) }

        SwiftFSOnDisk.zero(buffers.first)
        var block: UInt64 = 0
        while block < SwiftFSLayout.superblockCount {
            let result = writeBlock(block, from: buffers.first, to: &device)
            guard result == .success else {
                return .failure(.writeFailed(block: block, result: result))
            }
            block += 1
        }
        let invalidationSync = device.synchronize()
        guard invalidationSync == .success else {
            return .failure(.synchronizeFailed(invalidationSync))
        }

        let epoch = VFSTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)!
        let root = SwiftFSNodeRecord(
            slot: SwiftFSOnDisk.rootSlot,
            kind: .directory,
            parentSlot: SwiftFSOnDisk.rootSlot,
            nameByteCount: 0,
            byteCount: 0,
            firstDataBlock: 0,
            dataBlockCount: 0,
            generation: 1,
            createdAt: epoch,
            modifiedAt: epoch,
            availableAccess: SwiftFSOnDisk.directoryAccess
        )
        var slot: UInt32 = 1
        while slot <= layout.nodeCapacity {
            if slot == SwiftFSOnDisk.rootSlot {
                SwiftFSOnDisk.encodeNode(root, name: nil, into: buffers.first)
            } else {
                SwiftFSOnDisk.zero(buffers.first)
            }
            let metadataBlock = layout.metadataBlock(for: slot, bank: 0)!
            let result = writeBlock(metadataBlock, from: buffers.first, to: &device)
            guard result == .success else {
                return .failure(
                    .writeFailed(block: metadataBlock, result: result)
                )
            }
            slot += 1
        }
        let snapshotSync = device.synchronize()
        guard snapshotSync == .success else {
            return .failure(.synchronizeFailed(snapshotSync))
        }

        let superblock = SwiftFSSuperblock(
            layout: layout,
            volumeIdentifier: volumeIdentifier,
            sequence: 1,
            activeBank: 0
        )
        SwiftFSOnDisk.encodeSuperblock(superblock, into: buffers.first)
        let published = writeBlock(0, from: buffers.first, to: &device)
        guard published == .success else {
            return .failure(.writeFailed(block: 0, result: published))
        }
        let publicationSync = device.synchronize()
        guard publicationSync == .success else {
            return .failure(.synchronizeFailed(publicationSync))
        }
        return .formatted(layout)
    }

    /// Opens the newest structurally and checksum-valid snapshot. If the newest
    /// superblock references a torn bank, mounting falls back to the older
    /// commit. Both superblocks must describe the same immutable layout.
    static func mount(
        _ suppliedDevice: Device,
        expectedVolumeIdentifier: VFSVolumeIdentifier? = nil,
        accessMode: SwiftFSAccessMode = .readWrite,
        scratch: UnsafeMutableRawBufferPointer
    ) -> SwiftFSMountResult<Device> {
        let geometry = suppliedDevice.geometry
        guard let buffers = scratchBuffers(
            scratch,
            blockByteCount: geometry.logicalBlockByteCount
        ) else { return .failure(.invalidScratch) }
        var device = suppliedDevice
        var candidates: (SwiftFSSuperblock?, SwiftFSSuperblock?) = (nil, nil)
        var block: UInt64 = 0
        while block < SwiftFSLayout.superblockCount {
            let result = device.readBlock(at: block, into: buffers.first)
            guard result == .success else {
                return .failure(.readFailed(block: block, result: result))
            }
            let decoded = SwiftFSOnDisk.decodeSuperblock(
                buffers.first,
                geometry: geometry
            )
            let positioned = decoded?.activeBank == UInt8(block) ? decoded : nil
            if block == 0 { candidates.0 = positioned } else { candidates.1 = positioned }
            block += 1
        }
        guard candidates.0 != nil || candidates.1 != nil else {
            return .failure(.noValidSuperblock)
        }
        if let first = candidates.0, let second = candidates.1 {
            guard first.layout == second.layout,
                  first.volumeIdentifier == second.volumeIdentifier,
                  first.sequence != second.sequence || first == second
            else { return .failure(.conflictingSuperblocks) }
        }

        let newest: SwiftFSSuperblock
        let older: SwiftFSSuperblock?
        switch (candidates.0, candidates.1) {
        case (.some(let first), .some(let second)):
            if first.sequence >= second.sequence {
                newest = first
                older = second.sequence == first.sequence ? nil : second
            } else {
                newest = second
                older = first
            }
        case (.some(let only), .none):
            newest = only
            older = nil
        case (.none, .some(let only)):
            newest = only
            older = nil
        case (.none, .none):
            return .failure(.noValidSuperblock)
        }

        if let expectedVolumeIdentifier,
           newest.volumeIdentifier != expectedVolumeIdentifier {
            return .failure(.unexpectedVolume(found: newest.volumeIdentifier))
        }
        var provider = Self(
            device: device,
            volumeIdentifier: newest.volumeIdentifier,
            accessMode: accessMode,
            layout: newest.layout,
            sequence: newest.sequence,
            activeBank: newest.activeBank,
            scratchBase: scratch.baseAddress!,
            isAvailable: true
        )
        if provider.validateActiveSnapshot() {
            return .mounted(provider)
        }
        if let older {
            provider.sequence = older.sequence
            provider.activeBank = older.activeBank
            provider.isAvailable = true
            if provider.validateActiveSnapshot() {
                return .mounted(provider)
            }
        }
        return .failure(.noValidSnapshot)
    }

    mutating func metadata(for node: VFSNodeIdentifier) -> VFSMetadataResult {
        guard isAvailable else { return .failure(.unavailable) }
        guard let slot = checkedSlot(for: node) else { return .failure(.notFound) }
        switch loadNode(slot: slot, into: ioScratch) {
        case .node(let record):
            guard let metadata = metadata(from: record) else {
                isAvailable = false
                return .failure(.corrupt)
            }
            return .metadata(metadata)
        case .empty:
            return .failure(.notFound)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    mutating func lookup(
        parent: VFSNodeIdentifier,
        name: VFSNameView
    ) -> VFSLookupResult {
        guard isAvailable else { return .failure(.unavailable) }
        guard let parentSlot = checkedSlot(for: parent) else {
            return .failure(.notFound)
        }
        switch requireDirectory(slot: parentSlot, into: auxiliaryScratch) {
        case .failure(let failure):
            return .failure(failure)
        case .empty:
            return .failure(.notFound)
        case .node:
            break
        }
        switch findChild(parentSlot: parentSlot, name: name, into: ioScratch) {
        case .found(_, let record):
            guard let value = metadata(from: record) else {
                isAvailable = false
                return .failure(.corrupt)
            }
            return .node(value)
        case .missing:
            return .failure(.notFound)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    mutating func readDirectory(
        node: VFSNodeIdentifier,
        after cookie: VFSDirectoryCookie,
        nameOutput: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult {
        guard isAvailable else { return .failure(.unavailable) }
        guard let directorySlot = checkedSlot(for: node) else {
            return .failure(.notFound)
        }
        let directory: SwiftFSNodeRecord
        switch requireDirectory(slot: directorySlot, into: auxiliaryScratch) {
        case .node(let record):
            directory = record
        case .empty:
            return .failure(.notFound)
        case .failure(let failure):
            return .failure(failure)
        }

        var nextSlot: UInt32 = 1
        if cookie != .start {
            guard let decoded = SwiftFSOnDisk.decodeDirectoryCookie(cookie),
                  decoded.generation == directory.generation,
                  decoded.nextSlot >= 1,
                  decoded.nextSlot <= layout.nodeCapacity + 1
            else { return .staleCookie }
            nextSlot = decoded.nextSlot
        }

        while nextSlot <= layout.nodeCapacity {
            let slot = nextSlot
            nextSlot += 1
            switch loadNode(slot: slot, into: ioScratch) {
            case .empty:
                continue
            case .failure(let failure):
                return .failure(failure)
            case .node(let child):
                guard slot != SwiftFSOnDisk.rootSlot,
                      child.parentSlot == directorySlot
                else { continue }
                let required = Int(child.nameByteCount)
                guard nameOutput.count >= required,
                      let destination = nameOutput.baseAddress
                else { return .nameBufferTooSmall(requiredByteCount: required) }
                var nameIndex = 0
                while nameIndex < required {
                    destination.storeBytes(
                        of: ioScratch[SwiftFSOnDisk.nodeHeaderByteCount + nameIndex],
                        toByteOffset: nameIndex,
                        as: UInt8.self
                    )
                    nameIndex += 1
                }
                let nameBytes = UnsafeRawBufferPointer(
                    start: destination,
                    count: required
                )
                guard case .name(let name) = VFSNameValidator.validate(nameBytes),
                      let identifier = VFSNodeIdentifier(
                          volume: volumeIdentifier,
                          localValue: UInt64(slot)
                      ),
                      let nextCookie = SwiftFSOnDisk.directoryCookie(
                          generation: directory.generation,
                          nextSlot: nextSlot
                      )
                else {
                    isAvailable = false
                    return .failure(.corrupt)
                }
                return .entry(
                    VFSDirectoryEntry(
                        identifier: identifier,
                        kind: child.kind,
                        name: name
                    ),
                    nextCookie: nextCookie
                )
            }
        }
        return .end
    }

    mutating func read(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSDataIOResult {
        guard isAvailable else { return .failure(.unavailable) }
        guard let slot = checkedSlot(for: node) else { return .failure(.notFound) }
        let record: SwiftFSNodeRecord
        switch loadNode(slot: slot, into: auxiliaryScratch) {
        case .node(let loaded):
            record = loaded
        case .empty:
            return .failure(.notFound)
        case .failure(let failure):
            return .failure(failure)
        }
        guard record.kind == .regularFile else { return .failure(.isDirectory) }
        guard offset <= record.byteCount else { return .failure(.invalidOffset) }
        if output.count == 0 || offset == record.byteCount {
            return .transferred(byteCount: 0)
        }
        guard let outputBase = output.baseAddress else {
            return .failure(.invalidOffset)
        }
        let available = record.byteCount - offset
        let transferCount = available < UInt64(output.count)
            ? Int(available)
            : output.count
        let payloadCapacity = UInt64(layout.dataPayloadByteCountPerBlock)
        var fileOffset = offset
        var outputOffset = 0
        while outputOffset < transferCount {
            let fileBlockIndex = fileOffset / payloadCapacity
            let withinBlock = Int(fileOffset % payloadCapacity)
            guard readDataBlock(
                record: record,
                fileBlockIndex: fileBlockIndex,
                into: ioScratch
            ) else { return .failure(currentReadFailure()) }
            let payloadCount = SwiftFSOnDisk.payloadByteCount(
                fileByteCount: record.byteCount,
                fileBlockIndex: fileBlockIndex,
                layout: layout
            )!
            let remainingInBlock = payloadCount - withinBlock
            let remainingOutput = transferCount - outputOffset
            let copied = remainingInBlock < remainingOutput
                ? remainingInBlock
                : remainingOutput
            var index = 0
            while index < copied {
                outputBase.storeBytes(
                    of: ioScratch[
                        SwiftFSOnDisk.dataHeaderByteCount + withinBlock + index
                    ],
                    toByteOffset: outputOffset + index,
                    as: UInt8.self
                )
                index += 1
            }
            outputOffset += copied
            fileOffset += UInt64(copied)
        }
        return .transferred(byteCount: transferCount)
    }

    mutating func write(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> VFSDataIOResult {
        write(node: node, at: offset, from: input, modifiedAt: nil)
    }

    mutating func write(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer,
        modifiedAt: VFSTimestamp?
    ) -> VFSDataIOResult {
        guard isAvailable else { return .failure(.unavailable) }
        guard accessMode == .readWrite else { return .failure(.readOnly) }
        guard let slot = checkedSlot(for: node) else { return .failure(.notFound) }
        let record: SwiftFSNodeRecord
        switch loadNode(slot: slot, into: auxiliaryScratch) {
        case .node(let loaded):
            record = loaded
        case .empty:
            return .failure(.notFound)
        case .failure(let failure):
            return .failure(failure)
        }
        guard record.kind == .regularFile else { return .failure(.isDirectory) }
        if input.count == 0 { return .transferred(byteCount: 0) }
        guard input.baseAddress != nil,
              UInt64(input.count) <= UInt64.max - offset
        else { return .failure(.invalidOffset) }
        guard record.generation < SwiftFSOnDisk.maximumNodeGeneration,
              sequence != UInt64.max
        else { return .failure(.noSpace) }
        let newByteCount = offset + UInt64(input.count)
        let resultingByteCount = newByteCount > record.byteCount
            ? newByteCount
            : record.byteCount
        guard let blocks = SwiftFSOnDisk.dataBlockCount(
            for: resultingByteCount,
            layout: layout
        ), blocks <= layout.dataBankBlockCount else {
            return .failure(.noSpace)
        }
        let result = commit(
            .write(
                slot: slot,
                offset: offset,
                input: input,
                modifiedAt: modifiedAt
            )
        )
        switch result {
        case .completed:
            return .transferred(byteCount: input.count)
        case .failure(.provider(let failure)):
            return .failure(failure)
        case .failure:
            return .failure(.unavailable)
        }
    }

    mutating func create(
        parent: VFSNodeIdentifier,
        name: VFSNameView,
        kind: VFSNodeKind,
        timestamp: VFSTimestamp
    ) -> SwiftFSCreateResult {
        guard isAvailable else {
            return .failure(.provider(.unavailable))
        }
        guard accessMode == .readWrite else {
            return .failure(.provider(.readOnly))
        }
        guard kind == .regularFile || kind == .directory else {
            return .failure(.provider(.unavailable))
        }
        guard let parentSlot = checkedSlot(for: parent) else {
            return .failure(.provider(.notFound))
        }
        let parentRecord: SwiftFSNodeRecord
        switch requireDirectory(slot: parentSlot, into: auxiliaryScratch) {
        case .node(let record):
            parentRecord = record
        case .empty:
            return .failure(.provider(.notFound))
        case .failure(let failure):
            return .failure(.provider(failure))
        }
        guard parentRecord.generation < SwiftFSOnDisk.maximumNodeGeneration,
              sequence != UInt64.max
        else { return .failure(.provider(.noSpace)) }
        switch findChild(parentSlot: parentSlot, name: name, into: ioScratch) {
        case .found:
            return .failure(.provider(.alreadyExists))
        case .failure(let failure):
            return .failure(.provider(failure))
        case .missing:
            break
        }
        let freeSlot: UInt32
        switch firstFreeSlot() {
        case .slot(let slot):
            freeSlot = slot
        case .full:
            return .failure(.provider(.noSpace))
        case .failure(let failure):
            return .failure(.provider(failure))
        }
        let committed = commit(
            .create(
                slot: freeSlot,
                parentSlot: parentSlot,
                kind: kind,
                name: name,
                timestamp: timestamp
            )
        )
        guard case .completed = committed,
              let identifier = VFSNodeIdentifier(
                  volume: volumeIdentifier,
                  localValue: UInt64(freeSlot)
              )
        else {
            if case .failure(let failure) = committed { return .failure(failure) }
            return .failure(.provider(.corrupt))
        }
        switch metadata(for: identifier) {
        case .metadata(let metadata):
            return .created(metadata)
        case .failure(let failure):
            return .failure(.provider(failure))
        }
    }

    mutating func remove(
        parent: VFSNodeIdentifier,
        name: VFSNameView,
        timestamp: VFSTimestamp
    ) -> SwiftFSMutationResult {
        guard isAvailable else { return .failure(.provider(.unavailable)) }
        guard accessMode == .readWrite else { return .failure(.provider(.readOnly)) }
        guard let parentSlot = checkedSlot(for: parent) else {
            return .failure(.provider(.notFound))
        }
        let parentRecord: SwiftFSNodeRecord
        switch requireDirectory(slot: parentSlot, into: auxiliaryScratch) {
        case .node(let record):
            parentRecord = record
        case .empty:
            return .failure(.provider(.notFound))
        case .failure(let failure):
            return .failure(.provider(failure))
        }
        let targetSlot: UInt32
        let target: SwiftFSNodeRecord
        switch findChild(parentSlot: parentSlot, name: name, into: ioScratch) {
        case .found(let slot, let record):
            targetSlot = slot
            target = record
        case .missing:
            return .failure(.provider(.notFound))
        case .failure(let failure):
            return .failure(.provider(failure))
        }
        guard targetSlot != SwiftFSOnDisk.rootSlot else {
            return .failure(.rootImmutable)
        }
        if target.kind == .directory {
            switch directoryHasChildren(targetSlot) {
            case .some(true):
                return .failure(.directoryNotEmpty)
            case .some(false):
                break
            case .none:
                return .failure(.provider(currentReadFailure()))
            }
        }
        guard parentRecord.generation < SwiftFSOnDisk.maximumNodeGeneration,
              sequence != UInt64.max
        else { return .failure(.provider(.noSpace)) }
        return commit(
            .remove(
                slot: targetSlot,
                parentSlot: parentSlot,
                timestamp: timestamp
            )
        )
    }

    mutating func rename(
        sourceParent: VFSNodeIdentifier,
        sourceName: VFSNameView,
        destinationParent: VFSNodeIdentifier,
        destinationName: VFSNameView,
        timestamp: VFSTimestamp
    ) -> SwiftFSMutationResult {
        guard isAvailable else { return .failure(.provider(.unavailable)) }
        guard accessMode == .readWrite else { return .failure(.provider(.readOnly)) }
        guard let sourceParentSlot = checkedSlot(for: sourceParent),
              let destinationParentSlot = checkedSlot(for: destinationParent)
        else { return .failure(.provider(.notFound)) }
        let sourceParentRecord: SwiftFSNodeRecord
        switch requireDirectory(slot: sourceParentSlot, into: auxiliaryScratch) {
        case .node(let record): sourceParentRecord = record
        case .empty: return .failure(.provider(.notFound))
        case .failure(let failure): return .failure(.provider(failure))
        }
        let destinationParentRecord: SwiftFSNodeRecord
        switch requireDirectory(slot: destinationParentSlot, into: auxiliaryScratch) {
        case .node(let record): destinationParentRecord = record
        case .empty: return .failure(.provider(.notFound))
        case .failure(let failure): return .failure(.provider(failure))
        }
        let targetSlot: UInt32
        let target: SwiftFSNodeRecord
        switch findChild(
            parentSlot: sourceParentSlot,
            name: sourceName,
            into: ioScratch
        ) {
        case .found(let slot, let record):
            targetSlot = slot
            target = record
        case .missing:
            return .failure(.provider(.notFound))
        case .failure(let failure):
            return .failure(.provider(failure))
        }
        guard targetSlot != SwiftFSOnDisk.rootSlot else {
            return .failure(.rootImmutable)
        }
        switch findChild(
            parentSlot: destinationParentSlot,
            name: destinationName,
            into: ioScratch
        ) {
        case .found(let slot, _):
            if slot == targetSlot,
               sourceParentSlot == destinationParentSlot,
               sourceName.isBytewiseEqual(to: destinationName) {
                return .completed
            }
            return .failure(.provider(.alreadyExists))
        case .failure(let failure):
            return .failure(.provider(failure))
        case .missing:
            break
        }
        if target.kind == .directory,
           destinationParentSlot != sourceParentSlot {
            switch isDescendant(destinationParentSlot, of: targetSlot) {
            case .some(true):
                return .failure(.wouldCreateCycle)
            case .some(false):
                break
            case .none:
                return .failure(.provider(currentReadFailure()))
            }
        }
        guard target.generation < SwiftFSOnDisk.maximumNodeGeneration,
              sourceParentRecord.generation < SwiftFSOnDisk.maximumNodeGeneration,
              (sourceParentSlot == destinationParentSlot
                || destinationParentRecord.generation
                    < SwiftFSOnDisk.maximumNodeGeneration),
              sequence != UInt64.max
        else { return .failure(.provider(.noSpace)) }
        return commit(
            .rename(
                slot: targetSlot,
                sourceParentSlot: sourceParentSlot,
                destinationParentSlot: destinationParentSlot,
                destinationName: destinationName,
                timestamp: timestamp
            )
        )
    }

    private var ioScratch: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: scratchBase,
            count: layout.logicalBlockByteCount
        )
    }

    private var auxiliaryScratch: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: scratchBase.advanced(by: layout.logicalBlockByteCount),
            count: layout.logicalBlockByteCount
        )
    }

    private static func scratchBuffers(
        _ scratch: UnsafeMutableRawBufferPointer,
        blockByteCount: Int
    ) -> (
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    )? {
        guard blockByteCount > 0,
              scratch.count / blockByteCount >= 2,
              let base = scratch.baseAddress
        else { return nil }
        return (
            UnsafeMutableRawBufferPointer(start: base, count: blockByteCount),
            UnsafeMutableRawBufferPointer(
                start: base.advanced(by: blockByteCount),
                count: blockByteCount
            )
        )
    }

    private static func writeBlock(
        _ block: UInt64,
        from bytes: UnsafeMutableRawBufferPointer,
        to device: inout Device
    ) -> BlockDeviceIOResult {
        guard let base = bytes.baseAddress else { return .invalidBuffer }
        return device.writeBlock(
            at: block,
            from: UnsafeRawBufferPointer(
                start: base,
                count: device.geometry.logicalBlockByteCount
            )
        )
    }
}

private extension SwiftFSPersistentProvider {
    mutating func validateActiveSnapshot() -> Bool {
        var packedDataBlock: UInt64 = 0
        var slot: UInt32 = 1
        while slot <= layout.nodeCapacity {
            switch loadNode(slot: slot, into: auxiliaryScratch) {
            case .failure:
                return false
            case .empty:
                if slot == SwiftFSOnDisk.rootSlot { return false }
            case .node(let record):
                if slot == SwiftFSOnDisk.rootSlot {
                    guard record.kind == .directory,
                          record.parentSlot == SwiftFSOnDisk.rootSlot
                    else { return false }
                }
                if record.kind == .regularFile {
                    if record.dataBlockCount == 0 {
                        guard record.firstDataBlock == 0 else { return false }
                    } else {
                        guard record.firstDataBlock == packedDataBlock,
                              record.dataBlockCount
                                <= layout.dataBankBlockCount - packedDataBlock
                        else { return false }
                        var fileBlockIndex: UInt64 = 0
                        while fileBlockIndex < record.dataBlockCount {
                            guard readDataBlock(
                                record: record,
                                fileBlockIndex: fileBlockIndex,
                                into: ioScratch
                            ) else { return false }
                            fileBlockIndex += 1
                        }
                        packedDataBlock += record.dataBlockCount
                    }
                }
            }
            slot += 1
        }

        // Validate hierarchy, cycles, and bytewise sibling uniqueness. This is
        // O(nodeCapacity^2), but nodeCapacity is format-bounded and no heap or
        // attacker-controlled traversal can make it unbounded.
        slot = 2
        while slot <= layout.nodeCapacity {
            let record: SwiftFSNodeRecord
            switch loadNode(slot: slot, into: ioScratch) {
            case .empty:
                slot += 1
                continue
            case .failure:
                return false
            case .node(let loaded):
                record = loaded
            }
            switch loadNode(slot: record.parentSlot, into: auxiliaryScratch) {
            case .node(let parent):
                guard parent.kind == .directory else { return false }
            case .empty, .failure:
                return false
            }

            var ancestor = record.parentSlot
            var depth: UInt32 = 0
            while ancestor != SwiftFSOnDisk.rootSlot {
                guard ancestor != slot, depth < layout.nodeCapacity else {
                    return false
                }
                switch loadNode(slot: ancestor, into: auxiliaryScratch) {
                case .node(let parent):
                    guard parent.kind == .directory else { return false }
                    ancestor = parent.parentSlot
                case .empty, .failure:
                    return false
                }
                depth += 1
            }

            var otherSlot = slot + 1
            while otherSlot <= layout.nodeCapacity {
                switch loadNode(slot: otherSlot, into: auxiliaryScratch) {
                case .node(let other):
                    if other.parentSlot == record.parentSlot,
                       SwiftFSOnDisk.namesAreEqual(
                           ioScratch,
                           first: record,
                           auxiliaryScratch,
                           second: other
                       ) {
                        return false
                    }
                case .empty:
                    break
                case .failure:
                    return false
                }
                otherSlot += 1
            }
            slot += 1
        }
        isAvailable = true
        return true
    }

    mutating func loadNode(
        slot: UInt32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> SwiftFSNodeLoadResult {
        guard let block = layout.metadataBlock(for: slot, bank: activeBank) else {
            isAvailable = false
            return .failure(.corrupt)
        }
        let result = device.readBlock(at: block, into: buffer)
        guard result == .success else { return .failure(.ioFailure) }
        guard let decoded = SwiftFSOnDisk.decodeNode(
            buffer,
            expectedSlot: slot,
            layout: layout
        ) else {
            isAvailable = false
            return .failure(.corrupt)
        }
        switch decoded {
        case .empty: return .empty
        case .node(let record): return .node(record)
        }
    }

    mutating func requireDirectory(
        slot: UInt32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> SwiftFSNodeLoadResult {
        switch loadNode(slot: slot, into: buffer) {
        case .node(let record):
            guard record.kind == .directory else {
                return .failure(.notDirectory)
            }
            return .node(record)
        case .empty:
            return .empty
        case .failure(let failure):
            return .failure(failure)
        }
    }

    mutating func findChild(
        parentSlot: UInt32,
        name: VFSNameView,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> SwiftFSChildSearchResult {
        var slot: UInt32 = 2
        while slot <= layout.nodeCapacity {
            switch loadNode(slot: slot, into: buffer) {
            case .empty:
                break
            case .failure(let failure):
                return .failure(failure)
            case .node(let record):
                if record.parentSlot == parentSlot,
                   Int(record.nameByteCount) == name.byteCount,
                   nameMatches(name, record: record, bytes: buffer) {
                    return .found(slot: slot, record: record)
                }
            }
            slot += 1
        }
        return .missing
    }

    func nameMatches(
        _ name: VFSNameView,
        record: SwiftFSNodeRecord,
        bytes: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard name.byteCount == Int(record.nameByteCount) else { return false }
        var index = 0
        while index < name.byteCount {
            if name.byte(at: index)
                != bytes[SwiftFSOnDisk.nodeHeaderByteCount + index] {
                return false
            }
            index += 1
        }
        return true
    }

    mutating func firstFreeSlot() -> SwiftFSFreeSlotResult {
        var slot: UInt32 = 2
        while slot <= layout.nodeCapacity {
            switch loadNode(slot: slot, into: ioScratch) {
            case .empty:
                return .slot(slot)
            case .node:
                break
            case .failure(let failure):
                return .failure(failure)
            }
            slot += 1
        }
        return .full
    }

    mutating func directoryHasChildren(_ directorySlot: UInt32) -> Bool? {
        var slot: UInt32 = 2
        while slot <= layout.nodeCapacity {
            switch loadNode(slot: slot, into: ioScratch) {
            case .node(let record):
                if record.parentSlot == directorySlot { return true }
            case .empty:
                break
            case .failure:
                return nil
            }
            slot += 1
        }
        return false
    }

    mutating func isDescendant(
        _ possibleChild: UInt32,
        of ancestor: UInt32
    ) -> Bool? {
        var slot = possibleChild
        var depth: UInt32 = 0
        while slot != SwiftFSOnDisk.rootSlot {
            if slot == ancestor { return true }
            guard depth < layout.nodeCapacity else {
                isAvailable = false
                return nil
            }
            switch loadNode(slot: slot, into: auxiliaryScratch) {
            case .node(let record):
                guard record.kind == .directory else {
                    isAvailable = false
                    return nil
                }
                slot = record.parentSlot
            case .empty:
                isAvailable = false
                return nil
            case .failure:
                return nil
            }
            depth += 1
        }
        return ancestor == SwiftFSOnDisk.rootSlot
    }

    func checkedSlot(for identifier: VFSNodeIdentifier) -> UInt32? {
        guard identifier.volume == volumeIdentifier,
              identifier.localValue >= 1,
              identifier.localValue <= UInt64(layout.nodeCapacity)
        else { return nil }
        return UInt32(identifier.localValue)
    }

    func metadata(from record: SwiftFSNodeRecord) -> VFSNodeMetadata? {
        guard let identifier = VFSNodeIdentifier(
            volume: volumeIdentifier,
            localValue: UInt64(record.slot)
        ) else { return nil }
        let projectedAccess: VFSAccessRights
        if accessMode == .readWrite {
            projectedAccess = record.availableAccess
        } else {
            let ceiling: VFSAccessRights
            switch record.kind {
            case .regularFile:
                ceiling = .readData.union(.readMetadata).union(.execute)
            case .directory:
                ceiling = .enumerate.union(.traverse).union(.readMetadata)
            case .symbolicLink:
                ceiling = .readMetadata
            case .device:
                ceiling = .readData.union(.readMetadata)
            }
            projectedAccess = VFSAccessRights(
                rawValue: record.availableAccess.rawValue & ceiling.rawValue
            )!
        }
        return VFSNodeMetadata(
            identifier: identifier,
            kind: record.kind,
            byteCount: record.byteCount,
            linkCount: 1,
            generation: record.generation,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt,
            availableAccess: projectedAccess
        )
    }

    mutating func readDataBlock(
        record: SwiftFSNodeRecord,
        fileBlockIndex: UInt64,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard fileBlockIndex < record.dataBlockCount,
              record.firstDataBlock <= UInt64.max - fileBlockIndex,
              let block = layout.dataBlock(
                  relativeBlock: record.firstDataBlock + fileBlockIndex,
                  bank: activeBank
              ),
              let expectedPayload = SwiftFSOnDisk.payloadByteCount(
                  fileByteCount: record.byteCount,
                  fileBlockIndex: fileBlockIndex,
                  layout: layout
              )
        else {
            isAvailable = false
            return false
        }
        let result = device.readBlock(at: block, into: buffer)
        guard result == .success else { return false }
        guard SwiftFSOnDisk.validateDataBlock(
            buffer,
            nodeSlot: record.slot,
            fileBlockIndex: fileBlockIndex,
            nodeGeneration: record.generation,
            expectedPayloadByteCount: expectedPayload,
            layout: layout
        ) else {
            isAvailable = false
            return false
        }
        return true
    }

    func currentReadFailure() -> VFSProviderFailure {
        isAvailable ? .ioFailure : .corrupt
    }
}

private extension SwiftFSPersistentProvider {
    mutating func commit(
        _ mutation: SwiftFSSnapshotMutation
    ) -> SwiftFSMutationResult {
        guard isAvailable else { return .failure(.provider(.unavailable)) }
        guard accessMode == .readWrite else { return .failure(.provider(.readOnly)) }
        guard sequence != UInt64.max else { return .failure(.provider(.noSpace)) }

        let targetBank: UInt8 = activeBank == 0 ? 1 : 0
        var packedDataBlock: UInt64 = 0
        var slot: UInt32 = 1
        while slot <= layout.nodeCapacity {
            let loaded = loadNode(slot: slot, into: auxiliaryScratch)
            var outputRecord: SwiftFSNodeRecord?
            var outputName: VFSNameView?
            var oldRecord: SwiftFSNodeRecord?

            switch loaded {
            case .failure(let failure):
                return .failure(.provider(failure))
            case .empty:
                if case .create(
                    let createdSlot,
                    let parentSlot,
                    let kind,
                    let name,
                    let timestamp
                ) = mutation, createdSlot == slot {
                    outputRecord = SwiftFSNodeRecord(
                        slot: slot,
                        kind: kind,
                        parentSlot: parentSlot,
                        nameByteCount: UInt16(name.byteCount),
                        byteCount: 0,
                        firstDataBlock: 0,
                        dataBlockCount: 0,
                        generation: 1,
                        createdAt: timestamp,
                        modifiedAt: timestamp,
                        availableAccess: kind == .directory
                            ? SwiftFSOnDisk.directoryAccess
                            : SwiftFSOnDisk.regularFileAccess
                    )
                    outputName = name
                }
            case .node(let record):
                oldRecord = record
                if case .remove(let removedSlot, _, _) = mutation,
                   removedSlot == slot {
                    outputRecord = nil
                } else {
                    var changed = record
                    outputName = SwiftFSOnDisk.nodeName(
                        in: auxiliaryScratch,
                        record: record
                    )
                    applyMetadataMutation(
                        mutation,
                        to: &changed,
                        outputName: &outputName
                    )
                    outputRecord = changed
                }
            }

            if var record = outputRecord {
                if record.kind == .regularFile {
                    guard let blockCount = SwiftFSOnDisk.dataBlockCount(
                        for: record.byteCount,
                        layout: layout
                    ), blockCount <= layout.dataBankBlockCount - packedDataBlock
                    else { return .failure(.provider(.noSpace)) }
                    record.firstDataBlock = blockCount == 0 ? 0 : packedDataBlock
                    record.dataBlockCount = blockCount
                    if blockCount != 0 {
                        guard let oldRecord else {
                            isAvailable = false
                            return .failure(.provider(.corrupt))
                        }
                        if let failure = copyFileData(
                            oldRecord: oldRecord,
                            newRecord: record,
                            targetFirstDataBlock: packedDataBlock,
                            targetBank: targetBank,
                            mutation: mutation
                        ) {
                            return .failure(.provider(failure))
                        }
                    }
                    packedDataBlock += blockCount
                }
                if slot != SwiftFSOnDisk.rootSlot, outputName == nil {
                    isAvailable = false
                    return .failure(.provider(.corrupt))
                }
                SwiftFSOnDisk.encodeNode(
                    record,
                    name: outputName,
                    into: ioScratch
                )
            } else {
                SwiftFSOnDisk.zero(ioScratch)
            }
            let metadataBlock = layout.metadataBlock(for: slot, bank: targetBank)!
            let written = Self.writeBlock(
                metadataBlock,
                from: ioScratch,
                to: &device
            )
            guard written == .success else {
                return .failure(.provider(.ioFailure))
            }
            slot += 1
        }

        let snapshotSync = device.synchronize()
        guard snapshotSync == .success else {
            return .failure(.provider(.ioFailure))
        }
        let newSequence = sequence + 1
        let superblock = SwiftFSSuperblock(
            layout: layout,
            volumeIdentifier: volumeIdentifier,
            sequence: newSequence,
            activeBank: targetBank
        )
        SwiftFSOnDisk.encodeSuperblock(superblock, into: ioScratch)
        let superblockBlock = UInt64(targetBank)
        let published = Self.writeBlock(
            superblockBlock,
            from: ioScratch,
            to: &device
        )
        guard published == .success else {
            isAvailable = false
            return .failure(.provider(.ioFailure))
        }
        let publicationSync = device.synchronize()
        guard publicationSync == .success else {
            isAvailable = false
            return .failure(.provider(.ioFailure))
        }
        activeBank = targetBank
        sequence = newSequence
        return .completed
    }

    func applyMetadataMutation(
        _ mutation: SwiftFSSnapshotMutation,
        to record: inout SwiftFSNodeRecord,
        outputName: inout VFSNameView?
    ) {
        switch mutation {
        case .create(_, let parentSlot, _, _, let timestamp):
            if record.slot == parentSlot {
                record.generation += 1
                record.modifiedAt = timestamp
            }
        case .remove(_, let parentSlot, let timestamp):
            if record.slot == parentSlot {
                record.generation += 1
                record.modifiedAt = timestamp
            }
        case .rename(
            let renamedSlot,
            let sourceParentSlot,
            let destinationParentSlot,
            let destinationName,
            let timestamp
        ):
            if record.slot == renamedSlot {
                record.parentSlot = destinationParentSlot
                record.nameByteCount = UInt16(destinationName.byteCount)
                record.generation += 1
                record.modifiedAt = timestamp
                outputName = destinationName
            }
            if record.slot == sourceParentSlot {
                record.generation += 1
                record.modifiedAt = timestamp
            }
            if destinationParentSlot != sourceParentSlot,
               record.slot == destinationParentSlot {
                record.generation += 1
                record.modifiedAt = timestamp
            }
        case .write(let writtenSlot, let offset, let input, let modifiedAt):
            if record.slot == writtenSlot {
                let writtenEnd = offset + UInt64(input.count)
                if writtenEnd > record.byteCount { record.byteCount = writtenEnd }
                record.generation += 1
                if let modifiedAt { record.modifiedAt = modifiedAt }
            }
        }
    }

    mutating func copyFileData(
        oldRecord: SwiftFSNodeRecord,
        newRecord: SwiftFSNodeRecord,
        targetFirstDataBlock: UInt64,
        targetBank: UInt8,
        mutation: SwiftFSSnapshotMutation
    ) -> VFSProviderFailure? {
        var fileBlockIndex: UInt64 = 0
        while fileBlockIndex < newRecord.dataBlockCount {
            if fileBlockIndex < oldRecord.dataBlockCount {
                guard readDataBlock(
                    record: oldRecord,
                    fileBlockIndex: fileBlockIndex,
                    into: ioScratch
                ) else { return currentReadFailure() }
            } else {
                SwiftFSOnDisk.zero(ioScratch)
            }

            if case .write(let slot, let offset, let input, _) = mutation,
               slot == newRecord.slot {
                overlayWrite(
                    offset: offset,
                    input: input,
                    fileBlockIndex: fileBlockIndex,
                    into: ioScratch
                )
            }
            guard let payloadCount = SwiftFSOnDisk.payloadByteCount(
                fileByteCount: newRecord.byteCount,
                fileBlockIndex: fileBlockIndex,
                layout: layout
            ) else {
                isAvailable = false
                return .corrupt
            }
            var zeroIndex = SwiftFSOnDisk.dataHeaderByteCount + payloadCount
            while zeroIndex < layout.logicalBlockByteCount {
                ioScratch[zeroIndex] = 0
                zeroIndex += 1
            }
            SwiftFSOnDisk.encodeDataBlock(
                nodeSlot: newRecord.slot,
                fileBlockIndex: fileBlockIndex,
                nodeGeneration: newRecord.generation,
                payloadByteCount: payloadCount,
                into: ioScratch
            )
            guard targetFirstDataBlock <= UInt64.max - fileBlockIndex,
                  let targetBlock = layout.dataBlock(
                      relativeBlock: targetFirstDataBlock + fileBlockIndex,
                      bank: targetBank
                  )
            else { return .noSpace }
            let written = Self.writeBlock(
                targetBlock,
                from: ioScratch,
                to: &device
            )
            guard written == .success else { return .ioFailure }
            fileBlockIndex += 1
        }
        return nil
    }

    func overlayWrite(
        offset: UInt64,
        input: UnsafeRawBufferPointer,
        fileBlockIndex: UInt64,
        into bytes: UnsafeMutableRawBufferPointer
    ) {
        let payloadCapacity = UInt64(layout.dataPayloadByteCountPerBlock)
        let blockStart = fileBlockIndex * payloadCapacity
        let blockEnd = blockStart + payloadCapacity
        let inputEnd = offset + UInt64(input.count)
        let overlapStart = offset > blockStart ? offset : blockStart
        let overlapEnd = inputEnd < blockEnd ? inputEnd : blockEnd
        guard overlapStart < overlapEnd, let inputBase = input.baseAddress else {
            return
        }
        var fileOffset = overlapStart
        while fileOffset < overlapEnd {
            let inputOffset = Int(fileOffset - offset)
            let blockOffset = Int(fileOffset - blockStart)
            bytes[SwiftFSOnDisk.dataHeaderByteCount + blockOffset] =
                inputBase.load(fromByteOffset: inputOffset, as: UInt8.self)
            fileOffset += 1
        }
    }
}
