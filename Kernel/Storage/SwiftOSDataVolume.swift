struct SwiftOSDataVolumeLayout: Equatable {
    static let superblockCount: UInt64 = 2
    /// Bounds both bytes written and records scanned even when the containing
    /// data partition spans an entire large device.
    static let maximumKernelLogByteCount: UInt64 = 32 * 1_024 * 1_024
    static let maximumKernelLogBlockCount: UInt64 = 65_536

    let logicalBlockByteCount: Int
    let totalBlockCount: UInt64
    let kernelLogStartBlock: UInt64
    let kernelLogBlockCount: UInt64
    let userDataStartBlock: UInt64
    let userDataBlockCount: UInt64

    init?(
        geometry: BlockDeviceGeometry,
        kernelLogBlockCount: UInt64
    ) {
        guard kernelLogBlockCount >= 2,
              kernelLogBlockCount <= Self.maximumKernelLogBlockCount,
              kernelLogBlockCount <= Self.maximumKernelLogByteCount
                / UInt64(geometry.logicalBlockByteCount),
              geometry.logicalBlockCount > Self.superblockCount,
              kernelLogBlockCount
                < geometry.logicalBlockCount - Self.superblockCount
        else { return nil }
        logicalBlockByteCount = geometry.logicalBlockByteCount
        totalBlockCount = geometry.logicalBlockCount
        kernelLogStartBlock = Self.superblockCount
        self.kernelLogBlockCount = kernelLogBlockCount
        userDataStartBlock = Self.superblockCount + kernelLogBlockCount
        userDataBlockCount = geometry.logicalBlockCount - userDataStartBlock
    }

    fileprivate init?(
        geometry: BlockDeviceGeometry,
        kernelLogStartBlock: UInt64,
        kernelLogBlockCount: UInt64,
        userDataStartBlock: UInt64,
        userDataBlockCount: UInt64
    ) {
        guard kernelLogStartBlock == Self.superblockCount,
              kernelLogBlockCount >= 2,
              kernelLogBlockCount <= Self.maximumKernelLogBlockCount,
              kernelLogBlockCount <= Self.maximumKernelLogByteCount
                / UInt64(geometry.logicalBlockByteCount),
              userDataStartBlock == kernelLogStartBlock + kernelLogBlockCount,
              userDataBlockCount != 0,
              userDataStartBlock <= geometry.logicalBlockCount,
              userDataBlockCount
                == geometry.logicalBlockCount - userDataStartBlock
        else { return nil }
        logicalBlockByteCount = geometry.logicalBlockByteCount
        totalBlockCount = geometry.logicalBlockCount
        self.kernelLogStartBlock = kernelLogStartBlock
        self.kernelLogBlockCount = kernelLogBlockCount
        self.userDataStartBlock = userDataStartBlock
        self.userDataBlockCount = userDataBlockCount
    }
}

enum SwiftOSDataVolumeFormatResult: Equatable {
    case formatted(SwiftOSDataVolumeLayout)
    case invalidLayout
    case invalidScratch
    case writeFailed(block: UInt64, result: BlockDeviceIOResult)
    case synchronizeFailed(BlockDeviceIOResult)
}

enum SwiftOSDataVolumeOpenFailure: Equatable {
    case invalidScratch
    case readFailed(block: UInt64, result: BlockDeviceIOResult)
    case missingSuperblock
    case conflictingSuperblocks
}

enum SwiftOSDataVolumeOpenResult: Equatable {
    case volume(SwiftOSDataVolumeLayout)
    case failure(SwiftOSDataVolumeOpenFailure)
}

/// Signed on-disk container for the SwiftOS data partition.
///
/// Blocks zero and one hold identical, CRC-protected immutable superblocks.
/// The bounded kernel-log arena follows them. Remaining blocks belong to the
/// future user filesystem and are intentionally outside the log writer's
/// authority. EL0 will reach that arena through VFS syscalls, never raw block
/// mappings or shared kernel state.
enum SwiftOSDataVolume {
    static let formatVersion: UInt16 = 1
    static let headerByteCount = 64

    static func initializeEmpty<Device: BlockDevice>(
        _ device: inout Device,
        kernelLogBlockCount: UInt64,
        scratch: UnsafeMutableRawBufferPointer
    ) -> SwiftOSDataVolumeFormatResult {
        guard let layout = SwiftOSDataVolumeLayout(
            geometry: device.geometry,
            kernelLogBlockCount: kernelLogBlockCount
        ) else { return .invalidLayout }
        guard scratch.count >= layout.logicalBlockByteCount else {
            return .invalidScratch
        }

        // Formatting owns only this bounded arena. The future user filesystem
        // may already contain data and must never be erased by log setup.
        zero(scratch, byteCount: layout.logicalBlockByteCount)
        var block = layout.kernelLogStartBlock
        let logEnd = layout.kernelLogStartBlock + layout.kernelLogBlockCount
        while block < logEnd {
            let result = write(block: block, bytes: scratch, to: &device)
            guard result == .success else {
                return .writeFailed(block: block, result: result)
            }
            block += 1
        }

        encode(layout, into: scratch)
        block = 0
        while block < SwiftOSDataVolumeLayout.superblockCount {
            let result = write(block: block, bytes: scratch, to: &device)
            guard result == .success else {
                return .writeFailed(block: block, result: result)
            }
            block += 1
        }
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .synchronizeFailed(synchronized)
        }
        return .formatted(layout)
    }

    static func open<Device: BlockDevice>(
        _ device: inout Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> SwiftOSDataVolumeOpenResult {
        guard scratch.count >= device.geometry.logicalBlockByteCount else {
            return .failure(.invalidScratch)
        }
        var primary: SwiftOSDataVolumeLayout?
        var backup: SwiftOSDataVolumeLayout?
        var block: UInt64 = 0
        while block < SwiftOSDataVolumeLayout.superblockCount {
            let read = device.readBlock(at: block, into: scratch)
            guard read == .success else {
                return .failure(.readFailed(block: block, result: read))
            }
            let decoded = decode(scratch, geometry: device.geometry)
            if block == 0 { primary = decoded } else { backup = decoded }
            block += 1
        }
        if let primary, let backup {
            guard primary == backup else {
                return .failure(.conflictingSuperblocks)
            }
            return .volume(primary)
        }
        if let primary { return .volume(primary) }
        if let backup { return .volume(backup) }
        return .failure(.missingSuperblock)
    }

    private static func encode(
        _ layout: SwiftOSDataVolumeLayout,
        into bytes: UnsafeMutableRawBufferPointer
    ) {
        zero(bytes, byteCount: layout.logicalBlockByteCount)
        writeMagic(into: bytes)
        writeLE16(formatVersion, into: bytes, at: 8)
        writeLE16(UInt16(headerByteCount), into: bytes, at: 10)
        writeLE32(UInt32(layout.logicalBlockByteCount), into: bytes, at: 12)
        writeLE64(layout.totalBlockCount, into: bytes, at: 16)
        writeLE64(layout.kernelLogStartBlock, into: bytes, at: 24)
        writeLE64(layout.kernelLogBlockCount, into: bytes, at: 32)
        writeLE64(layout.userDataStartBlock, into: bytes, at: 40)
        writeLE64(layout.userDataBlockCount, into: bytes, at: 48)
        writeLE32(0, into: bytes, at: 56)
        let checksum = checksum(bytes, byteCount: 60)
        writeLE32(checksum, into: bytes, at: 60)
    }

    private static func decode(
        _ bytes: UnsafeMutableRawBufferPointer,
        geometry: BlockDeviceGeometry
    ) -> SwiftOSDataVolumeLayout? {
        guard hasMagic(bytes),
              readLE16(bytes, at: 8) == formatVersion,
              readLE16(bytes, at: 10) == UInt16(headerByteCount),
              readLE32(bytes, at: 12) == UInt32(geometry.logicalBlockByteCount),
              readLE64(bytes, at: 16) == geometry.logicalBlockCount,
              readLE32(bytes, at: 56) == 0,
              readLE32(bytes, at: 60) == checksum(bytes, byteCount: 60)
        else { return nil }
        return SwiftOSDataVolumeLayout(
            geometry: geometry,
            kernelLogStartBlock: readLE64(bytes, at: 24),
            kernelLogBlockCount: readLE64(bytes, at: 32),
            userDataStartBlock: readLE64(bytes, at: 40),
            userDataBlockCount: readLE64(bytes, at: 48)
        )
    }

    private static func writeMagic(into bytes: UnsafeMutableRawBufferPointer) {
        bytes[0] = 0x53 // S
        bytes[1] = 0x57 // W
        bytes[2] = 0x4f // O
        bytes[3] = 0x53 // S
        bytes[4] = 0x44 // D
        bytes[5] = 0x41 // A
        bytes[6] = 0x54 // T
        bytes[7] = 0x41 // A
    }

    private static func hasMagic(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        bytes[0] == 0x53 && bytes[1] == 0x57
            && bytes[2] == 0x4f && bytes[3] == 0x53
            && bytes[4] == 0x44 && bytes[5] == 0x41
            && bytes[6] == 0x54 && bytes[7] == 0x41
    }
}

struct PersistentLogRecordMetadata: Equatable {
    let sequence: UInt64
    let timestampTicks: UInt64
    let payloadByteCount: Int
}

enum PersistentLogAppendResult: Equatable {
    case appended(sequence: UInt64)
    case invalidPayload
    case sequenceExhausted
    case encoderRejected
    case writeFailed(BlockDeviceIOResult)
    case synchronizeFailed(BlockDeviceIOResult)
}

enum PersistentLogReadResult: Equatable {
    case record(PersistentLogRecordMetadata)
    case invalidOutput
    case notFound
    case readFailed(BlockDeviceIOResult)
}

enum PersistentLogStoreOpenFailure: Equatable {
    case volume(SwiftOSDataVolumeOpenFailure)
    case readFailed(block: UInt64, result: BlockDeviceIOResult)
}

enum PersistentLogStoreOpenResult<Device: BlockDevice> {
    case store(PersistentLogStore<Device>)
    case failure(PersistentLogStoreOpenFailure)
}

/// A power-loss-tolerant, bounded record ring. Each append is one complete
/// logical-block write followed by a durability barrier. There is no mutable
/// head block to tear: recovery scans the bounded arena, validates both header
/// and payload CRCs, and resumes after the greatest valid sequence. A torn
/// overwrite can lose that oldest slot, but cannot make partial bytes visible
/// as a committed record.
///
/// `scratch` is retained for the store's lifetime. Its owner supplies one
/// logical block of stable, exclusively borrowed memory and releases it only
/// after discarding the store.
struct PersistentLogStore<Device: BlockDevice> {
    static var recordHeaderByteCount: Int { 40 }
    static var recordFormatVersion: UInt16 { 1 }

    private(set) var device: Device
    let volumeLayout: SwiftOSDataVolumeLayout
    private let scratch: UnsafeMutableRawBufferPointer
    private(set) var newestSequence: UInt64?

    private init(
        device: Device,
        volumeLayout: SwiftOSDataVolumeLayout,
        scratch: UnsafeMutableRawBufferPointer,
        newestSequence: UInt64?
    ) {
        self.device = device
        self.volumeLayout = volumeLayout
        self.scratch = scratch
        self.newestSequence = newestSequence
    }

    static func open(
        device inputDevice: Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> PersistentLogStoreOpenResult<Device> {
        var device = inputDevice
        let opened = SwiftOSDataVolume.open(&device, scratch: scratch)
        let layout: SwiftOSDataVolumeLayout
        switch opened {
        case .volume(let discovered):
            layout = discovered
        case .failure(let failure):
            return .failure(.volume(failure))
        }

        var newest: UInt64?
        var slot: UInt64 = 0
        while slot < layout.kernelLogBlockCount {
            let block = layout.kernelLogStartBlock + slot
            let read = device.readBlock(at: block, into: scratch)
            guard read == .success else {
                return .failure(.readFailed(block: block, result: read))
            }
            if let record = decodeRecord(
                scratch,
                logicalBlockByteCount: layout.logicalBlockByteCount
            ), (record.sequence - 1) % layout.kernelLogBlockCount == slot,
               newest == nil || record.sequence > newest! {
                newest = record.sequence
            }
            slot += 1
        }
        return .store(
            Self(
                device: device,
                volumeLayout: layout,
                scratch: scratch,
                newestSequence: newest
            )
        )
    }

    var maximumPayloadByteCount: Int {
        volumeLayout.logicalBlockByteCount - Self.recordHeaderByteCount
    }

    mutating func append(
        payloadByteCount: Int,
        timestampTicks: UInt64,
        encodePayload: (UnsafeMutableRawBufferPointer) -> Bool
    ) -> PersistentLogAppendResult {
        guard payloadByteCount > 0,
              payloadByteCount <= maximumPayloadByteCount
        else { return .invalidPayload }
        guard newestSequence != UInt64.max else { return .sequenceExhausted }
        let sequence = (newestSequence ?? 0) + 1
        SwiftOSDataVolume.zero(
            scratch,
            byteCount: volumeLayout.logicalBlockByteCount
        )
        guard let baseAddress = scratch.baseAddress else {
            return .invalidPayload
        }
        let payload = UnsafeMutableRawBufferPointer(
            start: baseAddress.advanced(by: Self.recordHeaderByteCount),
            count: payloadByteCount
        )
        guard encodePayload(payload) else { return .encoderRejected }
        Self.encodeRecordHeader(
            sequence: sequence,
            timestampTicks: timestampTicks,
            payload: UnsafeRawBufferPointer(payload),
            into: scratch
        )
        let slot = (sequence - 1) % volumeLayout.kernelLogBlockCount
        let block = volumeLayout.kernelLogStartBlock + slot
        let written = SwiftOSDataVolume.write(
            block: block,
            bytes: scratch,
            to: &device
        )
        guard written == .success else { return .writeFailed(written) }
        let synchronized = device.synchronize()
        guard synchronized == .success else {
            return .synchronizeFailed(synchronized)
        }
        newestSequence = sequence
        return .appended(sequence: sequence)
    }

    mutating func read(
        sequence: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> PersistentLogReadResult {
        guard sequence != 0 else { return .notFound }
        let slot = (sequence - 1) % volumeLayout.kernelLogBlockCount
        let block = volumeLayout.kernelLogStartBlock + slot
        let result = device.readBlock(at: block, into: scratch)
        guard result == .success else { return .readFailed(result) }
        guard let record = Self.decodeRecord(
            scratch,
            logicalBlockByteCount: volumeLayout.logicalBlockByteCount
        ), record.sequence == sequence else { return .notFound }
        guard output.count >= record.payloadByteCount,
              let source = scratch.baseAddress,
              let destination = output.baseAddress
        else { return .invalidOutput }
        destination.copyMemory(
            from: source.advanced(by: Self.recordHeaderByteCount),
            byteCount: record.payloadByteCount
        )
        return .record(record)
    }

    private static func encodeRecordHeader(
        sequence: UInt64,
        timestampTicks: UInt64,
        payload: UnsafeRawBufferPointer,
        into bytes: UnsafeMutableRawBufferPointer
    ) {
        bytes[0] = 0x53 // S
        bytes[1] = 0x57 // W
        bytes[2] = 0x4c // L
        bytes[3] = 0x4f // O
        bytes[4] = 0x47 // G
        bytes[5] = 0x30 // 0
        bytes[6] = 0x30 // 0
        bytes[7] = 0x31 // 1
        SwiftOSDataVolume.writeLE16(recordFormatVersion, into: bytes, at: 8)
        SwiftOSDataVolume.writeLE16(
            UInt16(recordHeaderByteCount),
            into: bytes,
            at: 10
        )
        SwiftOSDataVolume.writeLE32(
            UInt32(payload.count),
            into: bytes,
            at: 12
        )
        SwiftOSDataVolume.writeLE64(sequence, into: bytes, at: 16)
        SwiftOSDataVolume.writeLE64(timestampTicks, into: bytes, at: 24)
        SwiftOSDataVolume.writeLE32(
            StorageCRC32.checksum(payload),
            into: bytes,
            at: 32
        )
        let headerChecksum = SwiftOSDataVolume.checksum(bytes, byteCount: 36)
        SwiftOSDataVolume.writeLE32(headerChecksum, into: bytes, at: 36)
    }

    private static func decodeRecord(
        _ bytes: UnsafeMutableRawBufferPointer,
        logicalBlockByteCount: Int
    ) -> PersistentLogRecordMetadata? {
        guard bytes[0] == 0x53, bytes[1] == 0x57,
              bytes[2] == 0x4c, bytes[3] == 0x4f,
              bytes[4] == 0x47, bytes[5] == 0x30,
              bytes[6] == 0x30, bytes[7] == 0x31,
              SwiftOSDataVolume.readLE16(bytes, at: 8) == recordFormatVersion,
              SwiftOSDataVolume.readLE16(bytes, at: 10)
                == UInt16(recordHeaderByteCount)
        else { return nil }
        let payloadByteCount = Int(
            SwiftOSDataVolume.readLE32(bytes, at: 12)
        )
        let sequence = SwiftOSDataVolume.readLE64(bytes, at: 16)
        guard sequence != 0,
              payloadByteCount > 0,
              payloadByteCount <= logicalBlockByteCount - recordHeaderByteCount,
              SwiftOSDataVolume.readLE32(bytes, at: 36)
                == SwiftOSDataVolume.checksum(bytes, byteCount: 36),
              let baseAddress = bytes.baseAddress
        else { return nil }
        let payload = UnsafeRawBufferPointer(
            start: baseAddress.advanced(by: recordHeaderByteCount),
            count: payloadByteCount
        )
        guard SwiftOSDataVolume.readLE32(bytes, at: 32)
                == StorageCRC32.checksum(payload)
        else { return nil }
        return PersistentLogRecordMetadata(
            sequence: sequence,
            timestampTicks: SwiftOSDataVolume.readLE64(bytes, at: 24),
            payloadByteCount: payloadByteCount
        )
    }
}

private extension SwiftOSDataVolume {
    static func write<Device: BlockDevice>(
        block: UInt64,
        bytes: UnsafeMutableRawBufferPointer,
        to device: inout Device
    ) -> BlockDeviceIOResult {
        guard let baseAddress = bytes.baseAddress else { return .invalidBuffer }
        return device.writeBlock(
            at: block,
            from: UnsafeRawBufferPointer(
                start: baseAddress,
                count: device.geometry.logicalBlockByteCount
            )
        )
    }

    static func zero(
        _ bytes: UnsafeMutableRawBufferPointer,
        byteCount: Int
    ) {
        var index = 0
        while index < byteCount {
            bytes[index] = 0
            index += 1
        }
    }

    static func checksum(
        _ bytes: UnsafeMutableRawBufferPointer,
        byteCount: Int
    ) -> UInt32 {
        guard let baseAddress = bytes.baseAddress else { return 0 }
        return StorageCRC32.checksum(
            UnsafeRawBufferPointer(start: baseAddress, count: byteCount)
        )
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
        writeLE16(
            UInt16(truncatingIfNeeded: value >> 16),
            into: bytes,
            at: offset + 2
        )
    }

    static func writeLE64(
        _ value: UInt64,
        into bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeLE32(UInt32(truncatingIfNeeded: value), into: bytes, at: offset)
        writeLE32(
            UInt32(truncatingIfNeeded: value >> 32),
            into: bytes,
            at: offset + 4
        )
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
