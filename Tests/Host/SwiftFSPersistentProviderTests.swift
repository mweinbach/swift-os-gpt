private enum SwiftFSTestDeviceEvent: Equatable {
    case write(UInt64)
    case synchronize
}

private final class SwiftFSTestBlockDevice: BlockDevice {
    let geometry: BlockDeviceGeometry
    var bytes: [UInt8]
    var events: [SwiftFSTestDeviceEvent] = []
    var failReadBlock: UInt64?
    var failWriteBlock: UInt64?
    var failNextSynchronization = false

    init(blockCount: UInt64, blockByteCount: Int = 512) {
        geometry = BlockDeviceGeometry(
            logicalBlockByteCount: blockByteCount,
            logicalBlockCount: blockCount
        )!
        bytes = [UInt8](repeating: 0, count: Int(blockCount) * blockByteCount)
    }

    func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        if failReadBlock == logicalBlock { return .transportFailure }
        guard logicalBlock < geometry.logicalBlockCount else { return .invalidBlock }
        guard output.count >= geometry.logicalBlockByteCount,
              let destination = output.baseAddress
        else { return .invalidBuffer }
        let offset = Int(logicalBlock) * geometry.logicalBlockByteCount
        bytes.withUnsafeBytes { source in
            destination.copyMemory(
                from: source.baseAddress!.advanced(by: offset),
                byteCount: geometry.logicalBlockByteCount
            )
        }
        return .success
    }

    func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult {
        events.append(.write(logicalBlock))
        if failWriteBlock == logicalBlock {
            failWriteBlock = nil
            return .transportFailure
        }
        guard logicalBlock < geometry.logicalBlockCount else { return .invalidBlock }
        guard input.count >= geometry.logicalBlockByteCount,
              let source = input.baseAddress
        else { return .invalidBuffer }
        let offset = Int(logicalBlock) * geometry.logicalBlockByteCount
        bytes.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: offset).copyMemory(
                from: source,
                byteCount: geometry.logicalBlockByteCount
            )
        }
        return .success
    }

    func synchronize() -> BlockDeviceIOResult {
        events.append(.synchronize)
        if failNextSynchronization {
            failNextSynchronization = false
            return .transportFailure
        }
        return .success
    }

    func corrupt(block: UInt64, byteOffset: Int) {
        let index = Int(block) * geometry.logicalBlockByteCount + byteOffset
        bytes[index] ^= 0x80
    }
}

@main
struct SwiftFSPersistentProviderTests {
    private typealias Provider = SwiftFSPersistentProvider<SwiftFSTestBlockDevice>

    static func main() {
        validatesLayoutAndFormattingBounds()
        mountsRootAndProjectsReadOnlyRights()
        createsAndEnumeratesHierarchies()
        persistsSparseAndOverwrittenFileData()
        renamesAndRemovesWithHierarchySafety()
        rejectsCapacityAndOffsetOverflow()
        publishesOnlyAfterSnapshotSynchronization()
        recoversTheOlderCommittedSnapshot()
        rejectsCorruptMediaWithoutAValidSnapshot()
        print("SwiftFS persistent provider host tests: 9 groups passed")
    }

    private static func validatesLayoutAndFormattingBounds() {
        let tiny = SwiftFSTestBlockDevice(blockCount: 8)
        expect(
            SwiftFSLayout(geometry: tiny.geometry, nodeCapacity: 4) == nil,
            "layout accepted no room for two data banks"
        )
        let device = SwiftFSTestBlockDevice(blockCount: 80)
        var value = device
        withScratch(blockByteCount: 512, blockCount: 1) { scratch in
            expect(
                Provider.format(
                    &value,
                    volumeIdentifier: volume(10),
                    nodeCapacity: 8,
                    scratch: scratch
                ) == .failure(.invalidScratch),
                "one-block lifetime scratch was accepted"
            )
        }
        withScratch { scratch in
            expect(
                Provider.format(
                    &value,
                    volumeIdentifier: volume(10),
                    nodeCapacity: 1,
                    scratch: scratch
                ) == .failure(.invalidLayout),
                "one-node format was accepted"
            )
            guard case .formatted(let layout) = Provider.format(
                &value,
                volumeIdentifier: volume(10),
                nodeCapacity: 8,
                scratch: scratch
            ) else { fail("valid format failed") }
            expect(layout.metadataBank0StartBlock == 2, "metadata bank zero")
            expect(layout.metadataBank1StartBlock == 10, "metadata bank one")
            expect(layout.dataBankBlockCount == 31, "data bank split")
        }

        let base = SwiftFSTestBlockDevice(blockCount: 96)
        base.bytes = [UInt8](repeating: 0x5a, count: base.bytes.count)
        let range = BlockDeviceRange(
            startBlock: 8,
            blockCount: 80,
            within: base.geometry.logicalBlockCount
        )!
        var partition = PartitionBlockDevice(base: base, partitionRange: range)!
        typealias PartitionProvider = SwiftFSPersistentProvider<
            PartitionBlockDevice<SwiftFSTestBlockDevice>
        >
        withScratch { scratch in
            guard case .formatted = PartitionProvider.format(
                &partition,
                volumeIdentifier: volume(22),
                nodeCapacity: 8,
                scratch: scratch
            ) else { fail("partition-bounded format failed") }
        }
        expect(base.bytes[7 * 512] == 0x5a, "format wrote before partition")
        expect(base.bytes[88 * 512] == 0x5a, "format wrote after partition")
    }

    private static func mountsRootAndProjectsReadOnlyRights() {
        let device = formattedDevice(volumeID: 11)
        withScratch { scratch in
            var writable = requireMounted(device, volumeID: 11, scratch: scratch)
            let root = requireMetadata(&writable, writable.rootNodeIdentifier)
            expect(root.kind == .directory, "root kind")
            expect(root.generation == 1, "root generation")
            expect(root.availableAccess.contains(.create), "writable root lost create")
            let protectedFile = create(
                &writable,
                parent: writable.rootNodeIdentifier,
                name: "manifest",
                kind: .regularFile,
                second: 1
            )

            var readOnly = requireMounted(
                device,
                volumeID: 11,
                accessMode: .readOnly,
                scratch: scratch
            )
            let projected = requireMetadata(&readOnly, readOnly.rootNodeIdentifier)
            expect(projected.availableAccess.contains(.enumerate), "read-only enumerate")
            expect(!projected.availableAccess.contains(.create), "read-only create leaked")
            let projectedFile = requireMetadata(&readOnly, protectedFile)
            expect(projectedFile.availableAccess.contains(.readData), "read-only file read")
            expect(!projectedFile.availableAccess.contains(.writeData), "read-only file write")
            var deniedByte: UInt8 = 1
            withUnsafeBytes(of: &deniedByte) {
                expect(
                    readOnly.write(node: protectedFile, at: 0, from: $0)
                        == .failure(.readOnly),
                    "read-only mount wrote file data"
                )
            }
            withName("blocked") { name in
                guard case .failure(.provider(.readOnly)) = readOnly.create(
                    parent: readOnly.rootNodeIdentifier,
                    name: name,
                    kind: .regularFile,
                    timestamp: timestamp(1)
                ) else { fail("read-only mount created a file") }
            }
            expect(
                readOnly.volumeIdentifier == volume(11),
                "mounted volume identity changed"
            )
        }
        withScratch { scratch in
            guard case .failure(.unexpectedVolume(let found)) = Provider.mount(
                device,
                expectedVolumeIdentifier: volume(99),
                scratch: scratch
            ) else { fail("unexpected volume identity mounted") }
            expect(found == volume(11), "reported unexpected volume")
        }
    }

    private static func createsAndEnumeratesHierarchies() {
        let device = formattedDevice(volumeID: 12, nodeCapacity: 12)
        withScratch { scratch in
            var provider = requireMounted(device, volumeID: 12, scratch: scratch)
            let alice = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "alice",
                kind: .directory,
                second: 10
            )
            _ = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "shared",
                kind: .directory,
                second: 11
            )
            let notes = create(
                &provider,
                parent: alice,
                name: "Notes",
                kind: .directory,
                second: 12
            )
            let file = create(
                &provider,
                parent: notes,
                name: "todo.txt",
                kind: .regularFile,
                second: 13
            )
            expect(requireMetadata(&provider, file).kind == .regularFile, "file kind")

            var nameBuffer = [UInt8](repeating: 0, count: 255)
            let firstCookie = nameBuffer.withUnsafeMutableBytes { output -> VFSDirectoryCookie in
                guard case .entry(let entry, let next) = provider.readDirectory(
                    node: provider.rootNodeIdentifier,
                    after: .start,
                    nameOutput: output
                ) else { fail("root enumeration had no first child") }
                expectName(entry.name, equals: "alice")
                return next
            }
            _ = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "later",
                kind: .directory,
                second: 14
            )
            nameBuffer.withUnsafeMutableBytes { output in
                guard case .staleCookie = provider.readDirectory(
                    node: provider.rootNodeIdentifier,
                    after: firstCookie,
                    nameOutput: output
                ) else { fail("directory mutation did not stale a cookie") }
            }
            withName("Notes") { name in
                guard case .node(let metadata) = provider.lookup(parent: alice, name: name)
                else { fail("nested directory lookup failed") }
                expect(metadata.identifier == notes, "nested lookup identifier")
            }
        }
    }

    private static func persistsSparseAndOverwrittenFileData() {
        let device = formattedDevice(volumeID: 13, nodeCapacity: 8)
        withScratch { scratch in
            var provider = requireMounted(device, volumeID: 13, scratch: scratch)
            let file = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "state.bin",
                kind: .regularFile,
                second: 20
            )
            write(&provider, file: file, offset: 0, bytes: Array("hello".utf8))
            write(&provider, file: file, offset: 7, bytes: [0x21])
            write(&provider, file: file, offset: 2, bytes: Array("YY".utf8))
            expect(
                read(&provider, file: file, count: 32)
                    == [0x68, 0x65, 0x59, 0x59, 0x6f, 0, 0, 0x21],
                "sparse overwrite bytes"
            )
            expect(requireMetadata(&provider, file).byteCount == 8, "file size")
        }
        withScratch { scratch in
            var remounted = requireMounted(device, volumeID: 13, scratch: scratch)
            let file = lookup(
                &remounted,
                parent: remounted.rootNodeIdentifier,
                name: "state.bin"
            )
            expect(
                read(&remounted, file: file, count: 8)
                    == [0x68, 0x65, 0x59, 0x59, 0x6f, 0, 0, 0x21],
                "file did not survive remount"
            )
            var one = [UInt8](repeating: 0, count: 1)
            one.withUnsafeMutableBytes { output in
                expect(
                    remounted.read(node: file, at: 9, into: output)
                        == .failure(.invalidOffset),
                    "read beyond EOF accepted"
                )
            }
        }
    }

    private static func renamesAndRemovesWithHierarchySafety() {
        let device = formattedDevice(volumeID: 14, nodeCapacity: 12)
        withScratch { scratch in
            var provider = requireMounted(device, volumeID: 14, scratch: scratch)
            let alice = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "alice",
                kind: .directory,
                second: 30
            )
            let notes = create(
                &provider,
                parent: alice,
                name: "Notes",
                kind: .directory,
                second: 31
            )
            let file = create(
                &provider,
                parent: notes,
                name: "draft",
                kind: .regularFile,
                second: 32
            )
            write(&provider, file: file, offset: 0, bytes: Array("kept".utf8))

            withTwoNames("draft", "final") { source, destination in
                expect(
                    provider.rename(
                        sourceParent: notes,
                        sourceName: source,
                        destinationParent: alice,
                        destinationName: destination,
                        timestamp: timestamp(33)
                    ) == .completed,
                    "cross-directory rename"
                )
            }
            let renamed = lookup(&provider, parent: alice, name: "final")
            expect(renamed == file, "rename changed stable node ID")
            expect(read(&provider, file: renamed, count: 8) == Array("kept".utf8),
                   "rename lost file data")

            withTwoNames("alice", "nested") { source, destination in
                expect(
                    provider.rename(
                        sourceParent: provider.rootNodeIdentifier,
                        sourceName: source,
                        destinationParent: notes,
                        destinationName: destination,
                        timestamp: timestamp(34)
                    ) == .failure(.wouldCreateCycle),
                    "directory moved beneath its descendant"
                )
            }
            withName("alice") { name in
                expect(
                    provider.remove(
                        parent: provider.rootNodeIdentifier,
                        name: name,
                        timestamp: timestamp(35)
                    ) == .failure(.directoryNotEmpty),
                    "non-empty directory removed"
                )
            }
            remove(&provider, parent: alice, name: "final", second: 36)
            remove(&provider, parent: alice, name: "Notes", second: 37)
            remove(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "alice",
                second: 38
            )
        }
    }

    private static func rejectsCapacityAndOffsetOverflow() {
        let device = formattedDevice(
            volumeID: 15,
            nodeCapacity: 4,
            blockCount: 14
        )
        withScratch { scratch in
            var provider = requireMounted(device, volumeID: 15, scratch: scratch)
            let first = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "one",
                kind: .regularFile,
                second: 40
            )
            _ = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "two",
                kind: .regularFile,
                second: 41
            )
            _ = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "three",
                kind: .regularFile,
                second: 42
            )
            withName("four") { name in
                guard case .failure(.provider(.noSpace)) = provider.create(
                    parent: provider.rootNodeIdentifier,
                    name: name,
                    kind: .regularFile,
                    timestamp: timestamp(43)
                ) else { fail("full node table accepted another node") }
            }
            var bytes = [UInt8](repeating: 0xaa, count: 945)
            bytes.withUnsafeBytes {
                expect(
                    provider.write(node: first, at: 0, from: $0)
                        == .failure(.noSpace),
                    "file larger than data bank was accepted"
                )
            }
            bytes = [1]
            bytes.withUnsafeBytes {
                expect(
                    provider.write(node: first, at: UInt64.max, from: $0)
                        == .failure(.invalidOffset),
                    "overflowing write offset accepted"
                )
            }
        }
    }

    private static func publishesOnlyAfterSnapshotSynchronization() {
        let device = formattedDevice(volumeID: 16, nodeCapacity: 8)
        withScratch { scratch in
            var provider = requireMounted(device, volumeID: 16, scratch: scratch)
            device.events.removeAll(keepingCapacity: true)
            _ = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "ordered",
                kind: .regularFile,
                second: 50
            )
            guard let publication = device.events.firstIndex(of: .write(1)) else {
                fail("new superblock was not published")
            }
            expect(publication > 0, "superblock was first write")
            expect(device.events[publication - 1] == .synchronize,
                   "snapshot was not synchronized before publication")
            expect(publication + 1 < device.events.count,
                   "publication synchronization missing")
            expect(device.events[publication + 1] == .synchronize,
                   "superblock was not synchronized")
        }

        let interrupted = formattedDevice(volumeID: 17, nodeCapacity: 8)
        withScratch { scratch in
            var provider = requireMounted(interrupted, volumeID: 17, scratch: scratch)
            interrupted.failWriteBlock = 1
            withName("torn") { name in
                guard case .failure(.provider(.ioFailure)) = provider.create(
                    parent: provider.rootNodeIdentifier,
                    name: name,
                    kind: .regularFile,
                    timestamp: timestamp(51)
                ) else { fail("failed publication was reported as committed") }
            }
            expect(!provider.isAvailable, "uncertain publication did not poison mount")
        }
        withScratch { scratch in
            var recovered = requireMounted(interrupted, volumeID: 17, scratch: scratch)
            withName("torn") { name in
                guard case .failure(.notFound) = recovered.lookup(
                    parent: recovered.rootNodeIdentifier,
                    name: name
                ) else { fail("unpublished node appeared after remount") }
            }
        }
    }

    private static func recoversTheOlderCommittedSnapshot() {
        let device = formattedDevice(volumeID: 18, nodeCapacity: 8)
        let layout = SwiftFSLayout(geometry: device.geometry, nodeCapacity: 8)!
        withScratch { scratch in
            var provider = requireMounted(device, volumeID: 18, scratch: scratch)
            let file = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "recover",
                kind: .regularFile,
                second: 60
            )
            write(&provider, file: file, offset: 0, bytes: Array("new".utf8))
        }
        device.corrupt(
            block: layout.dataBank0StartBlock,
            byteOffset: SwiftFSOnDisk.dataHeaderByteCount
        )
        withScratch { scratch in
            var recovered = requireMounted(device, volumeID: 18, scratch: scratch)
            let file = lookup(
                &recovered,
                parent: recovered.rootNodeIdentifier,
                name: "recover"
            )
            expect(requireMetadata(&recovered, file).byteCount == 0,
                   "did not fall back to previous empty-file snapshot")
        }

        let superblockFallback = formattedDevice(volumeID: 19, nodeCapacity: 8)
        withScratch { scratch in
            var provider = requireMounted(
                superblockFallback,
                volumeID: 19,
                scratch: scratch
            )
            _ = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "newest",
                kind: .regularFile,
                second: 61
            )
        }
        superblockFallback.corrupt(block: 1, byteOffset: 124)
        withScratch { scratch in
            var recovered = requireMounted(
                superblockFallback,
                volumeID: 19,
                scratch: scratch
            )
            withName("newest") { name in
                guard case .failure(.notFound) = recovered.lookup(
                    parent: recovered.rootNodeIdentifier,
                    name: name
                ) else { fail("corrupt newest superblock did not fall back") }
            }
        }
    }

    private static func rejectsCorruptMediaWithoutAValidSnapshot() {
        let device = formattedDevice(volumeID: 20, nodeCapacity: 8)
        let layout = SwiftFSLayout(geometry: device.geometry, nodeCapacity: 8)!
        withScratch { scratch in
            var provider = requireMounted(device, volumeID: 20, scratch: scratch)
            _ = create(
                &provider,
                parent: provider.rootNodeIdentifier,
                name: "only",
                kind: .regularFile,
                second: 70
            )
        }
        device.corrupt(block: layout.metadataBank0StartBlock, byteOffset: 0)
        device.corrupt(block: layout.metadataBank1StartBlock, byteOffset: 0)
        withScratch { scratch in
            guard case .failure(.noValidSnapshot) = Provider.mount(
                device,
                expectedVolumeIdentifier: volume(20),
                scratch: scratch
            ) else { fail("two corrupt snapshots mounted") }
        }

        let noSuperblock = formattedDevice(volumeID: 21)
        noSuperblock.corrupt(block: 0, byteOffset: 124)
        noSuperblock.corrupt(block: 1, byteOffset: 0)
        withScratch { scratch in
            guard case .failure(.noValidSuperblock) = Provider.mount(
                noSuperblock,
                expectedVolumeIdentifier: volume(21),
                scratch: scratch
            ) else { fail("media without a valid superblock mounted") }
        }
    }

    private static func formattedDevice(
        volumeID: UInt64,
        nodeCapacity: UInt32 = 8,
        blockCount: UInt64 = 96
    ) -> SwiftFSTestBlockDevice {
        let device = SwiftFSTestBlockDevice(blockCount: blockCount)
        var value = device
        withScratch { scratch in
            guard case .formatted = Provider.format(
                &value,
                volumeIdentifier: volume(volumeID),
                nodeCapacity: nodeCapacity,
                scratch: scratch
            ) else { fail("test format failed") }
        }
        return device
    }

    private static func requireMounted(
        _ device: SwiftFSTestBlockDevice,
        volumeID: UInt64,
        accessMode: SwiftFSAccessMode = .readWrite,
        scratch: UnsafeMutableRawBufferPointer
    ) -> Provider {
        switch Provider.mount(
            device,
            expectedVolumeIdentifier: volume(volumeID),
            accessMode: accessMode,
            scratch: scratch
        ) {
        case .mounted(let provider):
            return provider
        case .failure:
            fail("test mount failed")
        }
    }

    private static func create(
        _ provider: inout Provider,
        parent: VFSNodeIdentifier,
        name: String,
        kind: VFSNodeKind,
        second: Int64
    ) -> VFSNodeIdentifier {
        withName(name) { view in
            switch provider.create(
                parent: parent,
                name: view,
                kind: kind,
                timestamp: timestamp(second)
            ) {
            case .created(let metadata):
                return metadata.identifier
            case .failure:
                fail("test create failed")
            }
        }
    }

    private static func remove(
        _ provider: inout Provider,
        parent: VFSNodeIdentifier,
        name: String,
        second: Int64
    ) {
        withName(name) { view in
            expect(
                provider.remove(
                    parent: parent,
                    name: view,
                    timestamp: timestamp(second)
                ) == .completed,
                "test removal failed"
            )
        }
    }

    private static func lookup(
        _ provider: inout Provider,
        parent: VFSNodeIdentifier,
        name: String
    ) -> VFSNodeIdentifier {
        withName(name) { view in
            guard case .node(let metadata) = provider.lookup(parent: parent, name: view)
            else { fail("test lookup failed") }
            return metadata.identifier
        }
    }

    private static func write(
        _ provider: inout Provider,
        file: VFSNodeIdentifier,
        offset: UInt64,
        bytes: [UInt8]
    ) {
        bytes.withUnsafeBytes { input in
            expect(
                provider.write(node: file, at: offset, from: input)
                    == .transferred(byteCount: bytes.count),
                "test write failed"
            )
        }
    }

    private static func read(
        _ provider: inout Provider,
        file: VFSNodeIdentifier,
        count: Int
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0xcc, count: count)
        let transferred = output.withUnsafeMutableBytes { bytes -> Int in
            guard case .transferred(let byteCount) = provider.read(
                node: file,
                at: 0,
                into: bytes
            ) else { fail("test read failed") }
            return byteCount
        }
        return Array(output.prefix(transferred))
    }

    private static func requireMetadata(
        _ provider: inout Provider,
        _ node: VFSNodeIdentifier
    ) -> VFSNodeMetadata {
        guard case .metadata(let value) = provider.metadata(for: node) else {
            fail("test metadata failed")
        }
        return value
    }

    private static func withName<T>(
        _ string: String,
        _ body: (VFSNameView) -> T
    ) -> T {
        let bytes = Array(string.utf8)
        return bytes.withUnsafeBytes { raw in
            guard case .name(let name) = VFSNameValidator.validate(raw) else {
                fail("invalid test name")
            }
            return body(name)
        }
    }

    private static func withTwoNames<T>(
        _ first: String,
        _ second: String,
        _ body: (VFSNameView, VFSNameView) -> T
    ) -> T {
        withName(first) { firstName in
            withName(second) { secondName in
                body(firstName, secondName)
            }
        }
    }

    private static func expectName(_ name: VFSNameView, equals expected: String) {
        let expectedBytes = Array(expected.utf8)
        expect(name.byteCount == expectedBytes.count, "name byte count")
        var index = 0
        while index < expectedBytes.count {
            expect(name.byte(at: index) == expectedBytes[index], "name byte")
            index += 1
        }
    }

    private static func volume(_ value: UInt64) -> VFSVolumeIdentifier {
        VFSVolumeIdentifier(rawValue: value)!
    }

    private static func timestamp(_ second: Int64) -> VFSTimestamp {
        VFSTimestamp(secondsSinceUnixEpoch: second, nanoseconds: 0)!
    }

    private static func withScratch(
        blockByteCount: Int = 512,
        blockCount: Int = 2,
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: blockByteCount * blockCount,
            alignment: 8
        )
        defer { pointer.deallocate() }
        body(
            UnsafeMutableRawBufferPointer(
                start: pointer,
                count: blockByteCount * blockCount
            )
        )
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
