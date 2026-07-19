struct MBRPartitionType: RawRepresentable, Equatable {
    let rawValue: UInt8

    static let fat32 = Self(rawValue: 0x0b)
    static let fat32LBA = Self(rawValue: 0x0c)
    static let protectiveGPT = Self(rawValue: 0xee)
    /// Non-filesystem data. SwiftOS additionally requires its own signed volume
    /// header before treating this partition as user data.
    static let swiftOSData = Self(rawValue: 0xda)

    var isFAT32: Bool { self == .fat32 || self == .fat32LBA }
}

struct MBRPartition: Equatable {
    let index: Int
    let type: MBRPartitionType
    let isBootable: Bool
    let range: BlockDeviceRange
}

/// The legacy MBR has exactly four primary entries. Fixed fields keep discovery
/// allocation-free and prevent a corrupt table from manufacturing unbounded
/// work during early boot.
struct MBRPartitionTable: Equatable {
    private let partition0: MBRPartition?
    private let partition1: MBRPartition?
    private let partition2: MBRPartition?
    private let partition3: MBRPartition?

    init(
        partition0: MBRPartition?,
        partition1: MBRPartition?,
        partition2: MBRPartition?,
        partition3: MBRPartition?
    ) {
        self.partition0 = partition0
        self.partition1 = partition1
        self.partition2 = partition2
        self.partition3 = partition3
    }

    func partition(at index: Int) -> MBRPartition? {
        switch index {
        case 0: return partition0
        case 1: return partition1
        case 2: return partition2
        case 3: return partition3
        default: return nil
        }
    }
}

enum MBRPartitionDiscoveryFailure: Equatable {
    case invalidGeometry
    case invalidScratch
    case readFailed(BlockDeviceIOResult)
    case missingSignature
    case invalidStatus(index: Int)
    case emptyTypedEntry(index: Int)
    case startsAtPartitionTable(index: Int)
    case outOfBounds(index: Int)
    case overlappingEntries(first: Int, second: Int)
    /// A protective MBR delegates authoritative discovery to a future bounded
    /// GPT parser; it must never be mistaken for a usable primary partition.
    case protectiveGPTUnsupported
}

enum MBRPartitionDiscoveryResult: Equatable {
    case table(MBRPartitionTable)
    case failure(MBRPartitionDiscoveryFailure)
}

enum MBRPartitionDiscovery {
    static func read<Device: BlockDevice>(
        from device: inout Device,
        scratch: UnsafeMutableRawBufferPointer
    ) -> MBRPartitionDiscoveryResult {
        let geometry = device.geometry
        guard geometry.logicalBlockByteCount >= 512 else {
            return .failure(.invalidGeometry)
        }
        guard scratch.count >= geometry.logicalBlockByteCount else {
            return .failure(.invalidScratch)
        }
        let read = device.readBlock(at: 0, into: scratch)
        guard read == .success else { return .failure(.readFailed(read)) }
        guard scratch[510] == 0x55, scratch[511] == 0xaa else {
            return .failure(.missingSignature)
        }

        var decoded0: MBRPartition?
        var decoded1: MBRPartition?
        var decoded2: MBRPartition?
        var decoded3: MBRPartition?
        var index = 0
        while index < 4 {
            let offset = 446 + index * 16
            let status = scratch[offset]
            guard status == 0 || status == 0x80 else {
                return .failure(.invalidStatus(index: index))
            }
            let type = MBRPartitionType(rawValue: scratch[offset + 4])
            let start = UInt64(readLE32(scratch, at: offset + 8))
            let count = UInt64(readLE32(scratch, at: offset + 12))
            let partition: MBRPartition?
            if type.rawValue == 0 {
                guard start == 0, count == 0 else {
                    return .failure(.emptyTypedEntry(index: index))
                }
                partition = nil
            } else {
                guard type != .protectiveGPT else {
                    return .failure(.protectiveGPTUnsupported)
                }
                guard start != 0 else {
                    return .failure(.startsAtPartitionTable(index: index))
                }
                guard let range = BlockDeviceRange(
                    startBlock: start,
                    blockCount: count,
                    within: geometry.logicalBlockCount
                ) else { return .failure(.outOfBounds(index: index)) }
                partition = MBRPartition(
                    index: index,
                    type: type,
                    isBootable: status == 0x80,
                    range: range
                )
            }
            switch index {
            case 0: decoded0 = partition
            case 1: decoded1 = partition
            case 2: decoded2 = partition
            default: decoded3 = partition
            }
            index += 1
        }

        let table = MBRPartitionTable(
            partition0: decoded0,
            partition1: decoded1,
            partition2: decoded2,
            partition3: decoded3
        )
        var first = 0
        while first < 4 {
            if let lhs = table.partition(at: first) {
                var second = first + 1
                while second < 4 {
                    if let rhs = table.partition(at: second),
                       lhs.range.overlaps(rhs.range) {
                        return .failure(
                            .overlappingEntries(first: first, second: second)
                        )
                    }
                    second += 1
                }
            }
            first += 1
        }
        return .table(table)
    }

    private static func readLE32(
        _ bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

struct SwiftOSMediaPartitions: Equatable {
    let boot: MBRPartition
    let data: MBRPartition
}

enum SwiftOSMediaLayoutFailure: Equatable {
    case missingBootPartition
    case duplicateBootPartition
    case missingDataPartition
    case duplicateDataPartition
    case bootMustPrecedeData
}

enum SwiftOSMediaLayoutResult: Equatable {
    case layout(SwiftOSMediaPartitions)
    case failure(SwiftOSMediaLayoutFailure)
}

/// Selects the same two-partition media contract for physical and virtual block
/// transports. Firmware consumes FAT32; SwiftOS owns the signed data volume.
enum SwiftOSMediaLayout {
    static func select(from table: MBRPartitionTable) -> SwiftOSMediaLayoutResult {
        var boot: MBRPartition?
        var data: MBRPartition?
        var index = 0
        while index < 4 {
            if let partition = table.partition(at: index) {
                if partition.type.isFAT32 {
                    guard boot == nil else {
                        return .failure(.duplicateBootPartition)
                    }
                    boot = partition
                } else if partition.type == .swiftOSData {
                    guard data == nil else {
                        return .failure(.duplicateDataPartition)
                    }
                    data = partition
                }
            }
            index += 1
        }
        guard let boot else { return .failure(.missingBootPartition) }
        guard let data else { return .failure(.missingDataPartition) }
        guard boot.range.endBlock <= data.range.startBlock else {
            return .failure(.bootMustPrecedeData)
        }
        return .layout(SwiftOSMediaPartitions(boot: boot, data: data))
    }
}
