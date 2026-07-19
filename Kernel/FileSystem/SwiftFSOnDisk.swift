/// Deterministic, bounded on-disk structures for the first SwiftOS user
/// filesystem. The format is original to SwiftOS and deliberately simple:
/// every node occupies one logical block and each committed snapshot owns one
/// metadata bank plus one data bank. Mutations alternate banks.
///
/// This is an integrity-checked format, not an authenticated one. CRC-32 catches
/// torn writes and accidental media corruption; it does not defend against a
/// malicious block device.
struct SwiftFSLayout: Equatable {
    static let superblockCount: UInt64 = 2
    static let minimumNodeCapacity: UInt32 = 2
    static let maximumNodeCapacity: UInt32 = 1_024

    let logicalBlockByteCount: Int
    let logicalBlockCount: UInt64
    let nodeCapacity: UInt32
    let metadataBank0StartBlock: UInt64
    let metadataBank1StartBlock: UInt64
    let dataBank0StartBlock: UInt64
    let dataBank1StartBlock: UInt64
    let dataBankBlockCount: UInt64

    init?(geometry: BlockDeviceGeometry, nodeCapacity: UInt32) {
        guard nodeCapacity >= Self.minimumNodeCapacity,
              nodeCapacity <= Self.maximumNodeCapacity
        else { return nil }
        let metadataBlocks = UInt64(nodeCapacity)
        guard metadataBlocks <= (UInt64.max - Self.superblockCount) / 2 else {
            return nil
        }
        let dataStart = Self.superblockCount + metadataBlocks * 2
        guard dataStart < geometry.logicalBlockCount else { return nil }
        let remaining = geometry.logicalBlockCount - dataStart
        let dataBankBlockCount = remaining / 2
        guard dataBankBlockCount != 0 else { return nil }

        logicalBlockByteCount = geometry.logicalBlockByteCount
        logicalBlockCount = geometry.logicalBlockCount
        self.nodeCapacity = nodeCapacity
        metadataBank0StartBlock = Self.superblockCount
        metadataBank1StartBlock = Self.superblockCount + metadataBlocks
        dataBank0StartBlock = dataStart
        dataBank1StartBlock = dataStart + dataBankBlockCount
        self.dataBankBlockCount = dataBankBlockCount
    }

    var dataPayloadByteCountPerBlock: Int {
        logicalBlockByteCount - SwiftFSOnDisk.dataHeaderByteCount
    }

    func metadataStartBlock(for bank: UInt8) -> UInt64 {
        bank == 0 ? metadataBank0StartBlock : metadataBank1StartBlock
    }

    func dataStartBlock(for bank: UInt8) -> UInt64 {
        bank == 0 ? dataBank0StartBlock : dataBank1StartBlock
    }

    func metadataBlock(for slot: UInt32, bank: UInt8) -> UInt64? {
        guard slot >= 1, slot <= nodeCapacity, bank <= 1 else { return nil }
        return metadataStartBlock(for: bank) + UInt64(slot - 1)
    }

    func dataBlock(relativeBlock: UInt64, bank: UInt8) -> UInt64? {
        guard bank <= 1, relativeBlock < dataBankBlockCount else { return nil }
        return dataStartBlock(for: bank) + relativeBlock
    }
}

enum SwiftFSFormatFailure: Equatable {
    case invalidLayout
    case invalidScratch
    case writeFailed(block: UInt64, result: BlockDeviceIOResult)
    case synchronizeFailed(BlockDeviceIOResult)
}

enum SwiftFSFormatResult: Equatable {
    case formatted(SwiftFSLayout)
    case failure(SwiftFSFormatFailure)
}

enum SwiftFSMountFailure: Equatable {
    case invalidScratch
    case readFailed(block: UInt64, result: BlockDeviceIOResult)
    case noValidSuperblock
    case conflictingSuperblocks
    case unexpectedVolume(found: VFSVolumeIdentifier)
    case noValidSnapshot
}

enum SwiftFSMountResult<Device: BlockDevice> {
    case mounted(SwiftFSPersistentProvider<Device>)
    case failure(SwiftFSMountFailure)
}

enum SwiftFSAccessMode: UInt8, Equatable {
    case readOnly = 1
    case readWrite = 2
}

enum SwiftFSMutationFailure: Equatable {
    case provider(VFSProviderFailure)
    case rootImmutable
    case directoryNotEmpty
    case wouldCreateCycle
}

enum SwiftFSCreateResult {
    case created(VFSNodeMetadata)
    case failure(SwiftFSMutationFailure)
}

enum SwiftFSMutationResult: Equatable {
    case completed
    case failure(SwiftFSMutationFailure)
}

struct SwiftFSSuperblock: Equatable {
    let layout: SwiftFSLayout
    let volumeIdentifier: VFSVolumeIdentifier
    let sequence: UInt64
    let activeBank: UInt8
}

struct SwiftFSNodeRecord {
    let slot: UInt32
    var kind: VFSNodeKind
    var parentSlot: UInt32
    var nameByteCount: UInt16
    var byteCount: UInt64
    var firstDataBlock: UInt64
    var dataBlockCount: UInt64
    var generation: UInt64
    var createdAt: VFSTimestamp
    var modifiedAt: VFSTimestamp
    var availableAccess: VFSAccessRights
}

enum SwiftFSDecodedNode {
    case empty
    case node(SwiftFSNodeRecord)
}

enum SwiftFSOnDisk {
    static let formatVersion: UInt16 = 1
    static let superblockHeaderByteCount = 128
    static let nodeHeaderByteCount = 96
    static let dataHeaderByteCount = 40
    static let rootSlot: UInt32 = 1
    static let directoryCookieIndexBitCount: UInt64 = 11
    static let maximumNodeGeneration = UInt64.max >> directoryCookieIndexBitCount

    static let regularFileAccess = VFSAccessRights.readData
        .union(.writeData)
        .union(.readMetadata)
        .union(.writeMetadata)
    static let directoryAccess = VFSAccessRights.enumerate
        .union(.traverse)
        .union(.create)
        .union(.remove)
        .union(.readMetadata)
        .union(.writeMetadata)

    static func initialRootRecord() -> SwiftFSNodeRecord {
        let epoch = VFSTimestamp(
            secondsSinceUnixEpoch: 0,
            nanoseconds: 0
        )!
        return SwiftFSNodeRecord(
            slot: rootSlot,
            kind: .directory,
            parentSlot: rootSlot,
            nameByteCount: 0,
            byteCount: 0,
            firstDataBlock: 0,
            dataBlockCount: 0,
            generation: 1,
            createdAt: epoch,
            modifiedAt: epoch,
            availableAccess: directoryAccess
        )
    }

    static func encodeSuperblock(
        _ superblock: SwiftFSSuperblock,
        into bytes: UnsafeMutableRawBufferPointer
    ) {
        zero(bytes)
        writeSuperblockMagic(into: bytes)
        writeLE16(formatVersion, into: bytes, at: 8)
        writeLE16(UInt16(superblockHeaderByteCount), into: bytes, at: 10)
        writeLE32(
            UInt32(superblock.layout.logicalBlockByteCount),
            into: bytes,
            at: 12
        )
        writeLE64(superblock.layout.logicalBlockCount, into: bytes, at: 16)
        writeLE64(superblock.volumeIdentifier.rawValue, into: bytes, at: 24)
        writeLE64(superblock.sequence, into: bytes, at: 32)
        bytes[40] = superblock.activeBank
        writeLE32(superblock.layout.nodeCapacity, into: bytes, at: 48)
        writeLE64(
            superblock.layout.metadataBank0StartBlock,
            into: bytes,
            at: 56
        )
        writeLE64(
            superblock.layout.metadataBank1StartBlock,
            into: bytes,
            at: 64
        )
        writeLE64(superblock.layout.dataBank0StartBlock, into: bytes, at: 72)
        writeLE64(superblock.layout.dataBank1StartBlock, into: bytes, at: 80)
        writeLE64(superblock.layout.dataBankBlockCount, into: bytes, at: 88)
        writeLE32(rootSlot, into: bytes, at: 96)
        writeLE32(0, into: bytes, at: 124)
        writeLE32(checksumExcluding(bytes, offset: 124, count: 4), into: bytes, at: 124)
    }

    static func decodeSuperblock(
        _ bytes: UnsafeMutableRawBufferPointer,
        geometry: BlockDeviceGeometry
    ) -> SwiftFSSuperblock? {
        guard bytes.count >= geometry.logicalBlockByteCount,
              hasSuperblockMagic(bytes),
              readLE16(bytes, at: 8) == formatVersion,
              readLE16(bytes, at: 10) == UInt16(superblockHeaderByteCount),
              readLE32(bytes, at: 12) == UInt32(geometry.logicalBlockByteCount),
              readLE64(bytes, at: 16) == geometry.logicalBlockCount,
              let volume = VFSVolumeIdentifier(rawValue: readLE64(bytes, at: 24)),
              readLE64(bytes, at: 32) != 0,
              bytes[40] <= 1,
              bytes[40] == UInt8((readLE64(bytes, at: 32) - 1) & 1),
              reservedBytesAreZero(bytes, from: 41, through: 47),
              reservedBytesAreZero(bytes, from: 52, through: 55),
              readLE32(bytes, at: 96) == rootSlot,
              reservedBytesAreZero(bytes, from: 100, through: 123),
              readLE32(bytes, at: 124)
                == checksumExcluding(bytes, offset: 124, count: 4),
              let layout = SwiftFSLayout(
                  geometry: geometry,
                  nodeCapacity: readLE32(bytes, at: 48)
              ),
              layout.metadataBank0StartBlock == readLE64(bytes, at: 56),
              layout.metadataBank1StartBlock == readLE64(bytes, at: 64),
              layout.dataBank0StartBlock == readLE64(bytes, at: 72),
              layout.dataBank1StartBlock == readLE64(bytes, at: 80),
              layout.dataBankBlockCount == readLE64(bytes, at: 88)
        else { return nil }
        return SwiftFSSuperblock(
            layout: layout,
            volumeIdentifier: volume,
            sequence: readLE64(bytes, at: 32),
            activeBank: bytes[40]
        )
    }

    static func encodeNode(
        _ record: SwiftFSNodeRecord,
        name: VFSNameView?,
        into bytes: UnsafeMutableRawBufferPointer
    ) {
        zero(bytes)
        writeNodeMagic(into: bytes)
        writeLE16(formatVersion, into: bytes, at: 4)
        writeLE16(UInt16(nodeHeaderByteCount), into: bytes, at: 6)
        writeLE32(record.slot, into: bytes, at: 8)
        bytes[12] = record.kind.rawValue
        writeLE16(record.nameByteCount, into: bytes, at: 14)
        writeLE32(record.parentSlot, into: bytes, at: 16)
        writeLE64(record.byteCount, into: bytes, at: 24)
        writeLE64(record.firstDataBlock, into: bytes, at: 32)
        writeLE64(record.dataBlockCount, into: bytes, at: 40)
        writeLE64(record.generation, into: bytes, at: 48)
        writeLE64(
            UInt64(bitPattern: record.createdAt.secondsSinceUnixEpoch),
            into: bytes,
            at: 56
        )
        writeLE32(record.createdAt.nanoseconds, into: bytes, at: 64)
        writeLE64(
            UInt64(bitPattern: record.modifiedAt.secondsSinceUnixEpoch),
            into: bytes,
            at: 72
        )
        writeLE32(record.modifiedAt.nanoseconds, into: bytes, at: 80)
        writeLE16(record.availableAccess.rawValue, into: bytes, at: 84)
        if let name {
            var index = 0
            while index < name.byteCount {
                bytes[nodeHeaderByteCount + index] = name.byte(at: index)!
                index += 1
            }
        }
        writeLE32(0, into: bytes, at: 92)
        writeLE32(checksumExcluding(bytes, offset: 92, count: 4), into: bytes, at: 92)
    }

    static func decodeNode(
        _ bytes: UnsafeMutableRawBufferPointer,
        expectedSlot: UInt32,
        layout: SwiftFSLayout
    ) -> SwiftFSDecodedNode? {
        guard bytes.count >= layout.logicalBlockByteCount else { return nil }
        if blockIsZero(bytes, byteCount: layout.logicalBlockByteCount) {
            return .empty
        }
        guard hasNodeMagic(bytes),
              readLE16(bytes, at: 4) == formatVersion,
              readLE16(bytes, at: 6) == UInt16(nodeHeaderByteCount),
              readLE32(bytes, at: 8) == expectedSlot,
              bytes[13] == 0,
              readLE32(bytes, at: 20) == 0,
              reservedBytesAreZero(bytes, from: 66, through: 71),
              reservedBytesAreZero(bytes, from: 86, through: 91),
              readLE32(bytes, at: 92)
                == checksumExcluding(bytes, offset: 92, count: 4),
              let kind = VFSNodeKind(rawValue: bytes[12]),
              kind == .regularFile || kind == .directory,
              let access = VFSAccessRights(rawValue: readLE16(bytes, at: 84)),
              let createdAt = VFSTimestamp(
                  secondsSinceUnixEpoch: Int64(bitPattern: readLE64(bytes, at: 56)),
                  nanoseconds: readLE32(bytes, at: 64)
              ),
              let modifiedAt = VFSTimestamp(
                  secondsSinceUnixEpoch: Int64(bitPattern: readLE64(bytes, at: 72)),
                  nanoseconds: readLE32(bytes, at: 80)
              )
        else { return nil }

        let nameByteCount = Int(readLE16(bytes, at: 14))
        guard nameByteCount <= VFSPathLimits.maximumComponentByteCount,
              nodeHeaderByteCount + nameByteCount <= layout.logicalBlockByteCount
        else { return nil }
        if expectedSlot == rootSlot {
            guard nameByteCount == 0,
                  readLE32(bytes, at: 16) == rootSlot,
                  kind == .directory
            else { return nil }
        } else {
            guard nameByteCount != 0,
                  let base = bytes.baseAddress
            else { return nil }
            let nameBytes = UnsafeRawBufferPointer(
                start: base.advanced(by: nodeHeaderByteCount),
                count: nameByteCount
            )
            guard case .name = VFSNameValidator.validate(nameBytes) else {
                return nil
            }
        }

        let record = SwiftFSNodeRecord(
            slot: expectedSlot,
            kind: kind,
            parentSlot: readLE32(bytes, at: 16),
            nameByteCount: UInt16(nameByteCount),
            byteCount: readLE64(bytes, at: 24),
            firstDataBlock: readLE64(bytes, at: 32),
            dataBlockCount: readLE64(bytes, at: 40),
            generation: readLE64(bytes, at: 48),
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            availableAccess: access
        )
        guard record.parentSlot >= 1,
              record.parentSlot <= layout.nodeCapacity,
              record.generation != 0,
              record.generation <= maximumNodeGeneration,
              nodeSemanticsAreValid(record, layout: layout)
        else { return nil }
        return .node(record)
    }

    static func nodeName(
        in bytes: UnsafeMutableRawBufferPointer,
        record: SwiftFSNodeRecord
    ) -> VFSNameView? {
        guard record.nameByteCount != 0, let base = bytes.baseAddress else {
            return nil
        }
        let raw = UnsafeRawBufferPointer(
            start: base.advanced(by: nodeHeaderByteCount),
            count: Int(record.nameByteCount)
        )
        guard case .name(let name) = VFSNameValidator.validate(raw) else {
            return nil
        }
        return name
    }

    static func encodeDataBlock(
        nodeSlot: UInt32,
        fileBlockIndex: UInt64,
        nodeGeneration: UInt64,
        payloadByteCount: Int,
        into bytes: UnsafeMutableRawBufferPointer
    ) {
        writeDataMagic(into: bytes)
        writeLE16(formatVersion, into: bytes, at: 4)
        writeLE16(UInt16(dataHeaderByteCount), into: bytes, at: 6)
        writeLE32(nodeSlot, into: bytes, at: 8)
        writeLE64(fileBlockIndex, into: bytes, at: 12)
        writeLE32(UInt32(payloadByteCount), into: bytes, at: 20)
        writeLE64(nodeGeneration, into: bytes, at: 24)
        let payload = UnsafeRawBufferPointer(
            start: bytes.baseAddress!.advanced(by: dataHeaderByteCount),
            count: payloadByteCount
        )
        writeLE32(StorageCRC32.checksum(payload), into: bytes, at: 32)
        writeLE32(0, into: bytes, at: 36)
        writeLE32(checksumExcluding(bytes, offset: 36, count: 4), into: bytes, at: 36)
    }

    static func validateDataBlock(
        _ bytes: UnsafeMutableRawBufferPointer,
        nodeSlot: UInt32,
        fileBlockIndex: UInt64,
        nodeGeneration: UInt64,
        expectedPayloadByteCount: Int,
        layout: SwiftFSLayout
    ) -> Bool {
        guard bytes.count >= layout.logicalBlockByteCount,
              hasDataMagic(bytes),
              readLE16(bytes, at: 4) == formatVersion,
              readLE16(bytes, at: 6) == UInt16(dataHeaderByteCount),
              readLE32(bytes, at: 8) == nodeSlot,
              readLE64(bytes, at: 12) == fileBlockIndex,
              readLE32(bytes, at: 20) == UInt32(expectedPayloadByteCount),
              readLE64(bytes, at: 24) == nodeGeneration,
              readLE32(bytes, at: 36)
                == checksumExcluding(bytes, offset: 36, count: 4),
              let base = bytes.baseAddress
        else { return false }
        let payload = UnsafeRawBufferPointer(
            start: base.advanced(by: dataHeaderByteCount),
            count: expectedPayloadByteCount
        )
        guard readLE32(bytes, at: 32) == StorageCRC32.checksum(payload) else {
            return false
        }
        var index = dataHeaderByteCount + expectedPayloadByteCount
        while index < layout.logicalBlockByteCount {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    static func dataBlockCount(for byteCount: UInt64, layout: SwiftFSLayout) -> UInt64? {
        if byteCount == 0 { return 0 }
        let payload = UInt64(layout.dataPayloadByteCountPerBlock)
        guard byteCount <= UInt64.max - (payload - 1) else { return nil }
        return (byteCount + payload - 1) / payload
    }

    static func payloadByteCount(
        fileByteCount: UInt64,
        fileBlockIndex: UInt64,
        layout: SwiftFSLayout
    ) -> Int? {
        let payload = UInt64(layout.dataPayloadByteCountPerBlock)
        guard fileBlockIndex <= UInt64.max / payload else { return nil }
        let start = fileBlockIndex * payload
        guard start < fileByteCount else { return nil }
        let remaining = fileByteCount - start
        return Int(remaining < payload ? remaining : payload)
    }

    static func directoryCookie(generation: UInt64, nextSlot: UInt32) -> VFSDirectoryCookie? {
        guard generation != 0,
              generation <= maximumNodeGeneration,
              UInt64(nextSlot) < (UInt64(1) << directoryCookieIndexBitCount)
        else { return nil }
        return VFSDirectoryCookie(
            rawValue: (generation << directoryCookieIndexBitCount) | UInt64(nextSlot)
        )
    }

    static func decodeDirectoryCookie(
        _ cookie: VFSDirectoryCookie
    ) -> (generation: UInt64, nextSlot: UInt32)? {
        guard cookie.rawValue != 0 else { return nil }
        let mask = (UInt64(1) << directoryCookieIndexBitCount) - 1
        return (
            cookie.rawValue >> directoryCookieIndexBitCount,
            UInt32(cookie.rawValue & mask)
        )
    }

    static func zero(_ bytes: UnsafeMutableRawBufferPointer) {
        var index = 0
        while index < bytes.count {
            bytes[index] = 0
            index += 1
        }
    }

    static func namesAreEqual(
        _ firstBytes: UnsafeMutableRawBufferPointer,
        first: SwiftFSNodeRecord,
        _ secondBytes: UnsafeMutableRawBufferPointer,
        second: SwiftFSNodeRecord
    ) -> Bool {
        guard first.nameByteCount == second.nameByteCount else { return false }
        var index = 0
        while index < Int(first.nameByteCount) {
            if firstBytes[nodeHeaderByteCount + index]
                != secondBytes[nodeHeaderByteCount + index] {
                return false
            }
            index += 1
        }
        return true
    }

    private static func nodeSemanticsAreValid(
        _ record: SwiftFSNodeRecord,
        layout: SwiftFSLayout
    ) -> Bool {
        switch record.kind {
        case .regularFile:
            guard record.availableAccess.isSubset(of: regularFileAccess),
                  let expected = dataBlockCount(
                      for: record.byteCount,
                      layout: layout
                  ),
                  expected == record.dataBlockCount
            else { return false }
            if expected == 0 { return record.firstDataBlock == 0 }
            return record.firstDataBlock < layout.dataBankBlockCount
                && expected <= layout.dataBankBlockCount - record.firstDataBlock
        case .directory:
            return record.availableAccess.isSubset(of: directoryAccess)
                && record.byteCount == 0
                && record.firstDataBlock == 0
                && record.dataBlockCount == 0
        case .symbolicLink, .device:
            return false
        }
    }

    private static func checksumExcluding(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> UInt32 {
        guard let base = bytes.baseAddress else { return 0 }
        var checksum = StorageCRC32()
        checksum.update(UnsafeRawBufferPointer(start: base, count: offset))
        let trailingOffset = offset + count
        checksum.update(
            UnsafeRawBufferPointer(
                start: base.advanced(by: trailingOffset),
                count: bytes.count - trailingOffset
            )
        )
        return checksum.value
    }

    private static func blockIsZero(
        _ bytes: UnsafeMutableRawBufferPointer,
        byteCount: Int
    ) -> Bool {
        var index = 0
        while index < byteCount {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    private static func reservedBytesAreZero(
        _ bytes: UnsafeMutableRawBufferPointer,
        from start: Int,
        through end: Int
    ) -> Bool {
        var index = start
        while index <= end {
            if bytes[index] != 0 { return false }
            index += 1
        }
        return true
    }

    private static func writeSuperblockMagic(into bytes: UnsafeMutableRawBufferPointer) {
        bytes[0] = 0x53 // S
        bytes[1] = 0x57 // W
        bytes[2] = 0x49 // I
        bytes[3] = 0x46 // F
        bytes[4] = 0x54 // T
        bytes[5] = 0x46 // F
        bytes[6] = 0x53 // S
        bytes[7] = 0x31 // 1
    }

    private static func hasSuperblockMagic(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        bytes[0] == 0x53 && bytes[1] == 0x57 && bytes[2] == 0x49
            && bytes[3] == 0x46 && bytes[4] == 0x54 && bytes[5] == 0x46
            && bytes[6] == 0x53 && bytes[7] == 0x31
    }

    private static func writeNodeMagic(into bytes: UnsafeMutableRawBufferPointer) {
        bytes[0] = 0x53 // S
        bytes[1] = 0x46 // F
        bytes[2] = 0x4e // N
        bytes[3] = 0x44 // D
    }

    private static func hasNodeMagic(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        bytes[0] == 0x53 && bytes[1] == 0x46
            && bytes[2] == 0x4e && bytes[3] == 0x44
    }

    private static func writeDataMagic(into bytes: UnsafeMutableRawBufferPointer) {
        bytes[0] = 0x53 // S
        bytes[1] = 0x46 // F
        bytes[2] = 0x44 // D
        bytes[3] = 0x41 // A
    }

    private static func hasDataMagic(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        bytes[0] == 0x53 && bytes[1] == 0x46
            && bytes[2] == 0x44 && bytes[3] == 0x41
    }

    static func writeLE16(
        _ value: UInt16,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func writeLE32(
        _ value: UInt32,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeLE16(UInt16(truncatingIfNeeded: value), into: bytes, at: offset)
        writeLE16(UInt16(truncatingIfNeeded: value >> 16), into: bytes, at: offset + 2)
    }

    static func writeLE64(
        _ value: UInt64,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeLE32(UInt32(truncatingIfNeeded: value), into: bytes, at: offset)
        writeLE32(UInt32(truncatingIfNeeded: value >> 32), into: bytes, at: offset + 4)
    }

    static func readLE16(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func readLE32(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(readLE16(bytes, at: offset))
            | UInt32(readLE16(bytes, at: offset + 2)) << 16
    }

    static func readLE64(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        UInt64(readLE32(bytes, at: offset))
            | UInt64(readLE32(bytes, at: offset + 4)) << 32
    }
}
