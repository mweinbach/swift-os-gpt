/// Geometry published by a sector-addressed storage transport.
///
/// The storage core deliberately knows nothing about VirtIO, SDHCI, PCI, or a
/// particular board. A transport owns DMA and cache maintenance, then exposes
/// complete logical blocks through `BlockDevice`.
struct BlockDeviceGeometry: Equatable {
    let logicalBlockByteCount: Int
    let logicalBlockCount: UInt64

    init?(logicalBlockByteCount: Int, logicalBlockCount: UInt64) {
        guard logicalBlockByteCount >= 512,
              logicalBlockByteCount <= 65_536,
              logicalBlockByteCount.nonzeroBitCount == 1,
              logicalBlockCount != 0
        else { return nil }
        self.logicalBlockByteCount = logicalBlockByteCount
        self.logicalBlockCount = logicalBlockCount
    }
}

enum BlockDeviceIOResult: Equatable {
    case success
    case invalidBlock
    case invalidBuffer
    case readOnly
    case transportFailure
}

/// Allocation-free, synchronous logical-block contract shared by every storage
/// transport. Implementations must not retain either borrowed buffer. Returning
/// success means one complete logical block was transferred; partial I/O is a
/// transport failure. Callers serialize access unless the transport documents
/// a stronger rule.
protocol BlockDevice {
    var geometry: BlockDeviceGeometry { get }

    mutating func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult

    mutating func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult

    /// Completes previously successful writes at durable media. Devices with no
    /// volatile write cache may return success immediately.
    mutating func synchronize() -> BlockDeviceIOResult
}

struct BlockDeviceRange: Equatable {
    let startBlock: UInt64
    let blockCount: UInt64

    init?(startBlock: UInt64, blockCount: UInt64, within limit: UInt64) {
        guard blockCount != 0,
              startBlock < limit,
              blockCount <= limit - startBlock
        else { return nil }
        self.startBlock = startBlock
        self.blockCount = blockCount
    }

    var endBlock: UInt64 { startBlock + blockCount }

    func overlaps(_ other: Self) -> Bool {
        startBlock < other.endBlock && other.startBlock < endBlock
    }
}

/// Bounds a transport to one discovered partition without changing its logical
/// block size. The wrapped device remains kernel-owned; no raw block pointer is
/// ever mapped into an EL0 address space.
struct PartitionBlockDevice<Base: BlockDevice>: BlockDevice {
    private(set) var base: Base
    let partitionRange: BlockDeviceRange
    let geometry: BlockDeviceGeometry

    init?(base: Base, partitionRange: BlockDeviceRange) {
        guard partitionRange.endBlock <= base.geometry.logicalBlockCount,
              let geometry = BlockDeviceGeometry(
                  logicalBlockByteCount: base.geometry.logicalBlockByteCount,
                  logicalBlockCount: partitionRange.blockCount
              )
        else { return nil }
        self.base = base
        self.partitionRange = partitionRange
        self.geometry = geometry
    }

    mutating func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard output.count >= geometry.logicalBlockByteCount else {
            return .invalidBuffer
        }
        return base.readBlock(
            at: partitionRange.startBlock + logicalBlock,
            into: output
        )
    }

    mutating func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
        guard input.count >= geometry.logicalBlockByteCount else {
            return .invalidBuffer
        }
        return base.writeBlock(
            at: partitionRange.startBlock + logicalBlock,
            from: input
        )
    }

    mutating func synchronize() -> BlockDeviceIOResult {
        base.synchronize()
    }
}
