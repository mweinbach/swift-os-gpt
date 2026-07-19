private final class IncrementalBootstrapBlockDevice: BlockDevice {
    let geometry: BlockDeviceGeometry
    var bytes: [UInt8]
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var synchronizeCount = 0

    init(blockCount: UInt64, blockByteCount: Int = 512) {
        geometry = BlockDeviceGeometry(
            logicalBlockByteCount: blockByteCount,
            logicalBlockCount: blockCount
        )!
        bytes = [UInt8](
            repeating: 0,
            count: Int(blockCount) * blockByteCount
        )
    }

    var operationCount: Int {
        readCount + writeCount + synchronizeCount
    }

    func resetCounts() {
        readCount = 0
        writeCount = 0
        synchronizeCount = 0
    }

    func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        readCount += 1
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
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
        writeCount += 1
        guard logicalBlock < geometry.logicalBlockCount else {
            return .invalidBlock
        }
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
        synchronizeCount += 1
        return .success
    }

    func corrupt(block: UInt64, byteOffset: Int) {
        bytes[Int(block) * geometry.logicalBlockByteCount + byteOffset] ^= 0x80
    }
}

@main
struct SwiftFSIncrementalVolumeBootstrapTests {
    private typealias Device = IncrementalBootstrapBlockDevice
    private typealias Provider = SwiftFSPersistentProvider<Device>
    private typealias Bootstrap = SwiftFSIncrementalVolumeBootstrap<Device>

    static func main() {
        boundsEveryCooperativeStepAndRemounts()
        preservesCorruptNonblankMedia()
        fallsBackFromTheNewestTornSnapshot()
        print("incremental SwiftFS bootstrap host tests: 3 groups passed")
    }

    private static func boundsEveryCooperativeStepAndRemounts() {
        let device = Device(blockCount: 80)
        withScratch { scratch in
            var bootstrap = Bootstrap(
                device: device,
                volumeIdentifier: volume(71),
                nodeCapacity: 8,
                scratch: scratch
            )
            var formatted = requireReady(
                &bootstrap,
                device: device,
                expectedState: .formatted
            )
            expect(device.writeCount > 0, "blank media was not formatted")
            expect(
                device.synchronizeCount == 3,
                "format did not preserve its three durability barriers"
            )
            guard case .metadata(let root) = formatted.metadata(
                      for: formatted.rootNodeIdentifier
                  ), root.kind == .directory
            else { fail("formatted provider root unavailable") }

            device.resetCounts()
            var remount = Bootstrap(
                device: device,
                volumeIdentifier: volume(71),
                nodeCapacity: 8,
                scratch: scratch
            )
            _ = requireReady(
                &remount,
                device: device,
                expectedState: .mounted
            )
            expect(device.writeCount == 0, "remount rewrote valid media")
            expect(
                device.synchronizeCount == 0,
                "remount synchronized unchanged media"
            )
        }
    }

    private static func preservesCorruptNonblankMedia() {
        let device = Device(blockCount: 80)
        withScratch { scratch in
            var formatter = device
            guard case .formatted = Provider.format(
                      &formatter,
                      volumeIdentifier: volume(72),
                      nodeCapacity: 8,
                      scratch: scratch
                  )
            else { fail("corrupt-media fixture format") }
            device.corrupt(block: 0, byteOffset: 124)
            let before = device.bytes
            device.resetCounts()

            var bootstrap = Bootstrap(
                device: device,
                volumeIdentifier: volume(72),
                nodeCapacity: 8,
                scratch: scratch
            )
            let failure = requireFailure(&bootstrap, device: device)
            guard failure == .nonblankMediaWithoutValidSuperblock else {
                fail("corrupt nonblank media had the wrong failure")
            }
            expect(device.bytes == before, "corrupt media was modified")
            expect(device.writeCount == 0, "corrupt media was reformatted")
            expect(
                device.synchronizeCount == 0,
                "corrupt media was synchronized"
            )
        }
    }

    private static func fallsBackFromTheNewestTornSnapshot() {
        let device = Device(blockCount: 80)
        let layout = SwiftFSLayout(
            geometry: device.geometry,
            nodeCapacity: 8
        )!
        withScratch { scratch in
            var formatter = device
            guard case .formatted = Provider.format(
                      &formatter,
                      volumeIdentifier: volume(73),
                      nodeCapacity: 8,
                      scratch: scratch
                  )
            else { fail("fallback fixture format") }
            installSecondEmptySnapshot(
                on: device,
                layout: layout,
                volumeIdentifier: volume(73),
                scratch: scratch
            )
            device.corrupt(
                block: layout.metadataBank1StartBlock,
                byteOffset: 92
            )
            device.resetCounts()

            var bootstrap = Bootstrap(
                device: device,
                volumeIdentifier: volume(73),
                nodeCapacity: 8,
                scratch: scratch
            )
            var provider = requireReady(
                &bootstrap,
                device: device,
                expectedState: .mounted
            )
            guard case .metadata(let root) = provider.metadata(
                      for: provider.rootNodeIdentifier
                  ), root.kind == .directory
            else { fail("older valid snapshot did not mount") }
            expect(device.writeCount == 0, "fallback mount rewrote media")
        }
    }

    private static func installSecondEmptySnapshot(
        on device: Device,
        layout: SwiftFSLayout,
        volumeIdentifier: VFSVolumeIdentifier,
        scratch: UnsafeMutableRawBufferPointer
    ) {
        let blockBytes = device.geometry.logicalBlockByteCount
        let block = UnsafeMutableRawBufferPointer(
            start: scratch.baseAddress,
            count: blockBytes
        )
        var slot: UInt32 = 1
        while slot <= layout.nodeCapacity {
            if slot == SwiftFSOnDisk.rootSlot {
                SwiftFSOnDisk.encodeNode(
                    SwiftFSOnDisk.initialRootRecord(),
                    name: nil,
                    into: block
                )
            } else {
                SwiftFSOnDisk.zero(block)
            }
            let logicalBlock = layout.metadataBlock(for: slot, bank: 1)!
            expect(
                device.writeBlock(
                    at: logicalBlock,
                    from: UnsafeRawBufferPointer(block)
                ) == .success,
                "second snapshot metadata write"
            )
            slot += 1
        }
        expect(device.synchronize() == .success, "second snapshot sync")
        SwiftFSOnDisk.encodeSuperblock(
            SwiftFSSuperblock(
                layout: layout,
                volumeIdentifier: volumeIdentifier,
                sequence: 2,
                activeBank: 1
            ),
            into: block
        )
        expect(
            device.writeBlock(
                at: 1,
                from: UnsafeRawBufferPointer(block)
            ) == .success,
            "second superblock publication"
        )
        expect(device.synchronize() == .success, "second publication sync")
    }

    private static func requireReady(
        _ bootstrap: inout Bootstrap,
        device: Device,
        expectedState: SwiftFSPersistentVolumeState
    ) -> Provider {
        var pass = 0
        while pass < 20_000 {
            let before = device.operationCount
            let step = bootstrap.serviceOnce()
            let operationDelta = device.operationCount - before
            expect(
                operationDelta >= 0 && operationDelta <= 1,
                "one cooperative pass performed multiple device operations"
            )
            switch step {
            case .advanced:
                pass += 1
            case .ready(let provider, let state):
                expect(state == expectedState, "unexpected ready state")
                return provider
            case .failure:
                fail("incremental bootstrap unexpectedly failed")
            }
        }
        fail("incremental bootstrap did not become ready")
    }

    private static func requireFailure(
        _ bootstrap: inout Bootstrap,
        device: Device
    ) -> SwiftFSPersistentVolumeBootstrapFailure {
        var pass = 0
        while pass < 20_000 {
            let before = device.operationCount
            let step = bootstrap.serviceOnce()
            let operationDelta = device.operationCount - before
            expect(
                operationDelta >= 0 && operationDelta <= 1,
                "failed cooperative pass performed multiple operations"
            )
            switch step {
            case .advanced:
                pass += 1
            case .ready:
                fail("incremental bootstrap unexpectedly became ready")
            case .failure(let failure):
                return failure
            }
        }
        fail("incremental bootstrap did not resolve its failure")
    }

    private static func withScratch(
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: 1_024,
            alignment: 16
        )
        defer { pointer.deallocate() }
        body(
            UnsafeMutableRawBufferPointer(
                start: pointer,
                count: 1_024
            )
        )
    }

    private static func volume(_ rawValue: UInt64) -> VFSVolumeIdentifier {
        VFSVolumeIdentifier(rawValue: rawValue)!
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError(message)
    }
}
