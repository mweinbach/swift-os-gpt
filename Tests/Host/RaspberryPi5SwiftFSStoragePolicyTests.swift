private struct AliasProbeBlockDevice: BlockDevice {
    let geometry = BlockDeviceGeometry(
        logicalBlockByteCount: 512,
        logicalBlockCount: 64
    )!
    var lastReadBlock: UInt64?
    var lastWriteBlock: UInt64?
    var readCount = 0
    var writeCount = 0
    var synchronizeCount = 0

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
        lastReadBlock = logicalBlock
        readCount += 1
        return .success
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
        lastWriteBlock = logicalBlock
        writeCount += 1
        return .success
    }

    mutating func synchronize() -> BlockDeviceIOResult {
        synchronizeCount += 1
        return .success
    }
}

@main
struct RaspberryPi5SwiftFSStoragePolicyTests {
    static func main() {
        derivesDisjointAbsoluteRegions()
        rejectsInvalidOrUndersizedLayouts()
        serializesFilesystemBootstrapBeforeLogService()
        borrowedRegionsAliasOneStableTransport()
        print("raspberry pi 5 swiftfs storage policy: 4 groups passed")
    }

    private static func derivesDisjointAbsoluteRegions() {
        let device = BlockDeviceGeometry(
            logicalBlockByteCount: 512,
            logicalBlockCount: 256
        )!
        let dataPartition = BlockDeviceRange(
            startBlock: 8,
            blockCount: 192,
            within: device.logicalBlockCount
        )!
        let dataVolume = SwiftOSDataVolumeLayout(
            geometry: BlockDeviceGeometry(
                logicalBlockByteCount: 512,
                logicalBlockCount: 192
            )!,
            kernelLogBlockCount: 16
        )!
        let expectedLog = BlockDeviceRange(
            startBlock: 10,
            blockCount: 16,
            within: device.logicalBlockCount
        )!
        let expectedUsers = BlockDeviceRange(
            startBlock: 26,
            blockCount: 174,
            within: device.logicalBlockCount
        )!

        let result = RaspberryPi5SwiftFSStoragePolicy.regionPlan(
            deviceGeometry: device,
            dataPartition: dataPartition,
            dataVolume: dataVolume,
            nodeCapacity:
                SwiftOSUserFileSystemConfiguration.initialNodeCapacity
        )
        guard case .plan(let plan) = result else {
            fatalError("valid signed layout was rejected")
        }
        expect(plan.dataPartition == dataPartition, "data range drifted")
        expect(plan.kernelLog == expectedLog, "log range was not absolute")
        expect(
            plan.userFileSystem == expectedUsers,
            "user filesystem range was not absolute"
        )
        expect(
            !plan.kernelLog.overlaps(plan.userFileSystem),
            "log and user authorities overlap"
        )
        expect(
            SwiftOSUserFileSystemConfiguration.volumeIdentifier.rawValue
                == 0x5357_4653_5553_4552,
            "board-neutral user volume identity drifted"
        )
    }

    private static func rejectsInvalidOrUndersizedLayouts() {
        let device = BlockDeviceGeometry(
            logicalBlockByteCount: 512,
            logicalBlockCount: 256
        )!
        let layout192 = SwiftOSDataVolumeLayout(
            geometry: BlockDeviceGeometry(
                logicalBlockByteCount: 512,
                logicalBlockCount: 192
            )!,
            kernelLogBlockCount: 16
        )!
        let beyondDevice = BlockDeviceRange(
            startBlock: 200,
            blockCount: 80,
            within: 300
        )!
        expect(
            RaspberryPi5SwiftFSStoragePolicy.regionPlan(
                deviceGeometry: device,
                dataPartition: beyondDevice,
                dataVolume: layout192,
                nodeCapacity: 32
            ) == .failure(.dataPartitionOutOfBounds),
            "partition beyond the physical geometry was accepted"
        )

        let wrongCount = BlockDeviceRange(
            startBlock: 8,
            blockCount: 190,
            within: device.logicalBlockCount
        )!
        expect(
            RaspberryPi5SwiftFSStoragePolicy.regionPlan(
                deviceGeometry: device,
                dataPartition: wrongCount,
                dataVolume: layout192,
                nodeCapacity: 32
            ) == .failure(.dataVolumeGeometryMismatch),
            "signed layout was accepted for a different partition geometry"
        )

        let smallPartition = BlockDeviceRange(
            startBlock: 8,
            blockCount: 70,
            within: device.logicalBlockCount
        )!
        let smallLayout = SwiftOSDataVolumeLayout(
            geometry: BlockDeviceGeometry(
                logicalBlockByteCount: 512,
                logicalBlockCount: 70
            )!,
            kernelLogBlockCount: 4
        )!
        expect(
            RaspberryPi5SwiftFSStoragePolicy.regionPlan(
                deviceGeometry: device,
                dataPartition: smallPartition,
                dataVolume: smallLayout,
                nodeCapacity: 32
            ) == .failure(.unsupportedSwiftFSLayout),
            "undersized user range was accepted for the configured node table"
        )
    }

    private static func serializesFilesystemBootstrapBeforeLogService() {
        expect(
            RaspberryPi5SwiftFSStoragePolicy.steadyStateAction(
                userFileSystemBootstrapPending: true
            ) == .bootstrapUserFileSystem,
            "pending filesystem bootstrap shared a pass with log I/O"
        )
        expect(
            RaspberryPi5SwiftFSStoragePolicy.steadyStateAction(
                userFileSystemBootstrapPending: false
            ) == .servicePersistentLog,
            "log service did not resume after filesystem bootstrap"
        )
    }

    private static func borrowedRegionsAliasOneStableTransport() {
        let base = UnsafeMutablePointer<AliasProbeBlockDevice>.allocate(
            capacity: 1
        )
        base.initialize(to: AliasProbeBlockDevice())
        defer {
            base.deinitialize(count: 1)
            base.deallocate()
        }
        let logRange = BlockDeviceRange(
            startBlock: 10,
            blockCount: 4,
            within: base.pointee.geometry.logicalBlockCount
        )!
        let usersRange = BlockDeviceRange(
            startBlock: 20,
            blockCount: 8,
            within: base.pointee.geometry.logicalBlockCount
        )!
        var log = BorrowedBlockDeviceRegion(
            borrowing: base,
            partitionRange: logRange
        )!
        var logCopy = log
        var users = BorrowedBlockDeviceRegion(
            borrowing: base,
            partitionRange: usersRange
        )!
        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: 512,
            alignment: 8
        )
        defer { bytes.deallocate() }
        let output = UnsafeMutableRawBufferPointer(start: bytes, count: 512)
        let input = UnsafeRawBufferPointer(output)

        expect(log.writeBlock(at: 0, from: input) == .success, "log write failed")
        expect(
            logCopy.writeBlock(at: 2, from: input) == .success,
            "copied borrowed view lost transport authority"
        )
        expect(
            users.readBlock(at: 1, into: output) == .success,
            "user read failed"
        )
        expect(users.synchronize() == .success, "shared sync failed")
        expect(
            base.pointee.writeCount == 2
                && base.pointee.lastWriteBlock == 12,
            "borrowed log copies did not mutate the stable base record"
        )
        expect(
            base.pointee.readCount == 1
                && base.pointee.lastReadBlock == 21,
            "user range did not translate through the same base record"
        )
        expect(
            base.pointee.synchronizeCount == 1,
            "synchronization missed the stable base record"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
