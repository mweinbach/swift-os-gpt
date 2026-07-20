@main
struct StorageFoundationTests {
    static func main() {
        validatesGeometryAndPartitionBounds()
        sharesOneStableTransportAcrossDisjointBorrowedRegions()
        discoversTheSwiftOSMBRLayout()
        discoversTheSwiftOSABMBRLayout()
        rejectsCorruptAndAmbiguousMBRs()
        print("storage foundation host tests: 5 groups passed")
    }

    private static func sharesOneStableTransportAcrossDisjointBorrowedRegions() {
        var base = MemoryBlockDevice(blockCount: 32)
        withUnsafeMutablePointer(to: &base) { basePointer in
            let logRange = BlockDeviceRange(
                startBlock: 2,
                blockCount: 4,
                within: 32
            )!
            let userRange = BlockDeviceRange(
                startBlock: 6,
                blockCount: 20,
                within: 32
            )!
            guard var log = BorrowedBlockDeviceRegion(
                      borrowing: basePointer,
                      partitionRange: logRange
                  ),
                  var users = BorrowedBlockDeviceRegion(
                      borrowing: basePointer,
                      partitionRange: userRange
                  )
            else { fail("borrowed region construction") }

            var logBytes = [UInt8](repeating: 0x4c, count: 512)
            let userBytes = [UInt8](repeating: 0x55, count: 512)
            logBytes.withUnsafeBytes {
                expect(
                    log.writeBlock(at: 3, from: $0) == .success,
                    "borrowed log write"
                )
            }
            userBytes.withUnsafeBytes {
                expect(
                    users.writeBlock(at: 0, from: $0) == .success,
                    "borrowed user write"
                )
            }
            expect(
                basePointer.pointee.bytes[5 * 512] == 0x4c
                    && basePointer.pointee.bytes[6 * 512] == 0x55,
                "borrowed regions did not share translated transport"
            )
            expect(
                logBytes.withUnsafeMutableBytes {
                    users.readBlock(at: 20, into: $0)
                } == .invalidBlock,
                "borrowed user boundary escaped"
            )
            expect(
                users.synchronize() == .success,
                "borrowed synchronization"
            )
        }
    }

    private static func validatesGeometryAndPartitionBounds() {
        expect(
            BlockDeviceGeometry(
                logicalBlockByteCount: 511,
                logicalBlockCount: 8
            ) == nil,
            "short logical block accepted"
        )
        expect(
            BlockDeviceGeometry(
                logicalBlockByteCount: 768,
                logicalBlockCount: 8
            ) == nil,
            "non-power-of-two block accepted"
        )
        let base = MemoryBlockDevice(blockCount: 32)
        let range = BlockDeviceRange(
            startBlock: 8,
            blockCount: 4,
            within: 32
        )!
        var partition = PartitionBlockDevice(base: base, partitionRange: range)!
        var input = [UInt8](repeating: 0xa5, count: 512)
        input.withUnsafeBytes {
            expect(
                partition.writeBlock(at: 3, from: $0) == .success,
                "in-range partition write failed"
            )
            expect(
                partition.writeBlock(at: 4, from: $0) == .invalidBlock,
                "partition forwarded an out-of-range write"
            )
        }
        expect(base.bytes[11 * 512] == 0xa5, "partition LBA translation changed")
        input.removeLast()
        input.withUnsafeBytes {
            expect(
                partition.writeBlock(at: 0, from: $0) == .invalidBuffer,
                "short partition buffer accepted"
            )
        }
    }

    private static func discoversTheSwiftOSMBRLayout() {
        let device = MemoryBlockDevice(blockCount: 64_000)
        writePartition(
            to: device,
            index: 0,
            status: 0x80,
            type: MBRPartitionType.fat32LBA.rawValue,
            start: 2_048,
            count: 16_384
        )
        writePartition(
            to: device,
            index: 1,
            status: 0,
            type: MBRPartitionType.swiftOSData.rawValue,
            start: 18_432,
            count: 32_768
        )
        device.bytes[510] = 0x55
        device.bytes[511] = 0xaa
        var erased = device
        withScratch { scratch in
            guard case .table(let table) = MBRPartitionDiscovery.read(
                from: &erased,
                scratch: scratch
            ) else { fail("valid MBR was rejected") }
            guard case .layout(let media) = SwiftOSMediaLayout.select(from: table)
            else { fail("valid SwiftOS media layout was rejected") }
            expect(media.boot.index == 0, "boot partition index")
            expect(media.boot.isBootable, "boot flag")
            expect(media.data.index == 1, "data partition index")
            expect(media.data.range.blockCount == 32_768, "data extent")
        }
    }

    private static func rejectsCorruptAndAmbiguousMBRs() {
        let device = MemoryBlockDevice(blockCount: 100)
        var value = device
        withScratch { scratch in
            expect(
                MBRPartitionDiscovery.read(from: &value, scratch: scratch)
                    == .failure(.missingSignature),
                "unsigned MBR accepted"
            )
        }

        device.bytes[510] = 0x55
        device.bytes[511] = 0xaa
        writePartition(
            to: device,
            index: 0,
            status: 0,
            type: MBRPartitionType.fat32LBA.rawValue,
            start: 10,
            count: 50
        )
        writePartition(
            to: device,
            index: 1,
            status: 0,
            type: MBRPartitionType.swiftOSData.rawValue,
            start: 40,
            count: 20
        )
        value = device
        withScratch { scratch in
            expect(
                MBRPartitionDiscovery.read(from: &value, scratch: scratch)
                    == .failure(.overlappingEntries(first: 0, second: 1)),
                "overlapping partitions accepted"
            )
        }

        clearPartitions(device)
        writePartition(
            to: device,
            index: 0,
            status: 0,
            type: MBRPartitionType.fat32LBA.rawValue,
            start: 0,
            count: 50
        )
        value = device
        withScratch { scratch in
            expect(
                MBRPartitionDiscovery.read(from: &value, scratch: scratch)
                    == .failure(.startsAtPartitionTable(index: 0)),
                "partition aliasing the MBR was accepted"
            )
        }

        clearPartitions(device)
        writePartition(
            to: device,
            index: 0,
            status: 0,
            type: MBRPartitionType.protectiveGPT.rawValue,
            start: 1,
            count: 99
        )
        value = device
        withScratch { scratch in
            expect(
                MBRPartitionDiscovery.read(from: &value, scratch: scratch)
                    == .failure(.protectiveGPTUnsupported),
                "protective GPT MBR was treated as a primary table"
            )
        }
    }

    private static func discoversTheSwiftOSABMBRLayout() {
        let device = MemoryBlockDevice(blockCount: 1_000)
        writePartition(
            to: device,
            index: 0,
            status: 0x80,
            type: MBRPartitionType.fat12.rawValue,
            start: 1,
            count: 9
        )
        writePartition(
            to: device,
            index: 1,
            status: 0,
            type: MBRPartitionType.fat32LBA.rawValue,
            start: 10,
            count: 200
        )
        writePartition(
            to: device,
            index: 2,
            status: 0,
            type: MBRPartitionType.fat32LBA.rawValue,
            start: 210,
            count: 200
        )
        writePartition(
            to: device,
            index: 3,
            status: 0,
            type: MBRPartitionType.swiftOSData.rawValue,
            start: 410,
            count: 500
        )
        device.bytes[510] = 0x55
        device.bytes[511] = 0xaa
        var value = device
        withScratch { scratch in
            guard case .table(let table) = MBRPartitionDiscovery.read(
                from: &value,
                scratch: scratch
            ) else { fail("valid A/B MBR was rejected") }
            guard case .layout(let media) = SwiftOSABMediaLayout.select(
                from: table
            ) else { fail("valid A/B media topology was rejected") }
            expect(media.selector.index == 0, "A/B selector index")
            expect(media.selector.type == .fat12, "A/B selector type")
            expect(media.partition(for: .a).index == 1, "slot A index")
            expect(media.partition(for: .b).index == 2, "slot B index")
            expect(media.data.index == 3, "A/B data index")

            writePartition(
                to: device,
                index: 2,
                status: 0,
                type: MBRPartitionType.fat32LBA.rawValue,
                start: 210,
                count: 199
            )
            value = device
            guard case .table(let unequalTable) = MBRPartitionDiscovery.read(
                from: &value,
                scratch: scratch
            ) else { fail("unequal-slot MBR parsing") }
            expect(
                SwiftOSABMediaLayout.select(from: unequalTable)
                    == .failure(.slotGeometryMismatch),
                "unequal A/B slots were accepted"
            )
        }
    }

    private static func writePartition(
        to device: MemoryBlockDevice,
        index: Int,
        status: UInt8,
        type: UInt8,
        start: UInt32,
        count: UInt32
    ) {
        let offset = 446 + index * 16
        device.bytes[offset] = status
        device.bytes[offset + 4] = type
        writeLE32(start, into: &device.bytes, at: offset + 8)
        writeLE32(count, into: &device.bytes, at: offset + 12)
    }

    private static func clearPartitions(_ device: MemoryBlockDevice) {
        var index = 446
        while index < 510 {
            device.bytes[index] = 0
            index += 1
        }
    }

    private static func writeLE32(
        _ value: UInt32,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func withScratch(
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { pointer.deallocate() }
        body(UnsafeMutableRawBufferPointer(start: pointer, count: 512))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}
