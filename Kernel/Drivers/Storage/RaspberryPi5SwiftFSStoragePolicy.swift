struct RaspberryPi5SwiftFSRegionPlan: Equatable {
    let dataPartition: BlockDeviceRange
    let kernelLog: BlockDeviceRange
    let userFileSystem: BlockDeviceRange
}

enum RaspberryPi5SwiftFSRegionPlanFailure: Equatable {
    case dataPartitionOutOfBounds
    case dataVolumeGeometryMismatch
    case kernelLogOutOfBounds
    case userFileSystemOutOfBounds
    case regionsOverlap
    case unsupportedSwiftFSLayout
}

enum RaspberryPi5SwiftFSRegionPlanResult: Equatable {
    case plan(RaspberryPi5SwiftFSRegionPlan)
    case failure(RaspberryPi5SwiftFSRegionPlanFailure)
}

enum RaspberryPi5SteadyStorageAction: UInt8, Equatable {
    case serviceBootUpdate = 1
    case bootstrapUserFileSystem = 2
    case servicePersistentLog = 3
}

/// Pure board policy translating the MBR-selected data partition and signed
/// data-volume layout into disjoint absolute SD ranges. No MMIO, allocator, or
/// filesystem operation occurs here, so the same invariants are host-tested.
enum RaspberryPi5SwiftFSStoragePolicy {
    static func regionPlan(
        deviceGeometry: BlockDeviceGeometry,
        dataPartition: BlockDeviceRange,
        dataVolume: SwiftOSDataVolumeLayout,
        nodeCapacity: UInt32
    ) -> RaspberryPi5SwiftFSRegionPlanResult {
        guard dataPartition.endBlock <= deviceGeometry.logicalBlockCount else {
            return .failure(.dataPartitionOutOfBounds)
        }
        guard dataVolume.logicalBlockByteCount
                == deviceGeometry.logicalBlockByteCount,
              dataVolume.totalBlockCount == dataPartition.blockCount
        else { return .failure(.dataVolumeGeometryMismatch) }

        guard let kernelLog = absoluteRange(
                  relativeStart: dataVolume.kernelLogStartBlock,
                  blockCount: dataVolume.kernelLogBlockCount,
                  partition: dataPartition,
                  deviceBlockCount: deviceGeometry.logicalBlockCount
              )
        else { return .failure(.kernelLogOutOfBounds) }
        guard let userFileSystem = absoluteRange(
                  relativeStart: dataVolume.userDataStartBlock,
                  blockCount: dataVolume.userDataBlockCount,
                  partition: dataPartition,
                  deviceBlockCount: deviceGeometry.logicalBlockCount
              )
        else { return .failure(.userFileSystemOutOfBounds) }
        guard !kernelLog.overlaps(userFileSystem) else {
            return .failure(.regionsOverlap)
        }
        guard let userGeometry = BlockDeviceGeometry(
                  logicalBlockByteCount: deviceGeometry.logicalBlockByteCount,
                  logicalBlockCount: userFileSystem.blockCount
              ), SwiftFSLayout(
                  geometry: userGeometry,
                  nodeCapacity: nodeCapacity
              ) != nil
        else { return .failure(.unsupportedSwiftFSLayout) }
        return .plan(
            RaspberryPi5SwiftFSRegionPlan(
                dataPartition: dataPartition,
                kernelLog: kernelLog,
                userFileSystem: userFileSystem
            )
        )
    }

    /// A pending filesystem bootstrap owns one cooperative storage pass. Log
    /// recovery/appends resume on the following pass, so two aliases of the SD
    /// transport are never entered concurrently by this runtime.
    static func steadyStateAction(
        bootUpdatePending: Bool,
        userFileSystemBootstrapPending: Bool
    ) -> RaspberryPi5SteadyStorageAction {
        if bootUpdatePending { return .serviceBootUpdate }
        return userFileSystemBootstrapPending
            ? .bootstrapUserFileSystem : .servicePersistentLog
    }

    private static func absoluteRange(
        relativeStart: UInt64,
        blockCount: UInt64,
        partition: BlockDeviceRange,
        deviceBlockCount: UInt64
    ) -> BlockDeviceRange? {
        guard relativeStart <= partition.blockCount,
              blockCount <= partition.blockCount - relativeStart,
              partition.startBlock <= UInt64.max - relativeStart
        else { return nil }
        return BlockDeviceRange(
            startBlock: partition.startBlock + relativeStart,
            blockCount: blockCount,
            within: deviceBlockCount
        )
    }
}
