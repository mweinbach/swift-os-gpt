private final class CountingBlockDevice: BlockDevice {
    let base: MemoryBlockDevice
    var readCount = 0
    var writeCount = 0
    var synchronizeCount = 0
    var writeBlocks: [UInt64] = []

    init(base: MemoryBlockDevice) { self.base = base }
    var geometry: BlockDeviceGeometry { base.geometry }

    func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        readCount += 1
        return base.readBlock(at: logicalBlock, into: output)
    }

    func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult {
        writeCount += 1
        writeBlocks.append(logicalBlock)
        return base.writeBlock(at: logicalBlock, from: input)
    }

    func synchronize() -> BlockDeviceIOResult {
        synchronizeCount += 1
        return base.synchronize()
    }
}

private final class TestRetainedLogSource: RetainedKernelLogSource {
    var entries: [KernelLogEntry]
    var available = true
    var forcedLostSequence: UInt64?
    var forcedOldestAvailableSequence: UInt64 = 1

    init(entries: [KernelLogEntry]) { self.entries = entries }

    func retainedLogStatistics() -> KernelLogStatistics? {
        guard available else { return nil }
        return KernelLogStatistics(
            capacity: 64,
            retainedCount: entries.count,
            oldestSequence: entries.first?.sequence,
            newestSequence: entries.last?.sequence,
            nextSequence: entries.last.map { $0.sequence + 1 } ?? 1,
            overwrittenEntryCount: 0,
            rejectedEntryCount: 0
        )
    }

    func retainedLogEntry(sequence: UInt64) -> KernelLogLookupResult? {
        guard available else { return nil }
        if forcedLostSequence == sequence {
            forcedLostSequence = nil
            return .lost(
                oldestAvailableSequence: forcedOldestAvailableSequence
            )
        }
        guard let first = entries.first else { return .notYetWritten }
        if sequence < first.sequence {
            return .lost(oldestAvailableSequence: first.sequence)
        }
        guard let entry = entries.first(where: { $0.sequence == sequence }) else {
            return .notYetWritten
        }
        return .entry(entry)
    }
}

@main
struct DeferredPersistentLogServiceTests {
    static func main() {
        stagesMediaValidationRecoveryAndBoundedFlushes()
        selectsPersistentLogDataFromStrictABPartitionFour()
        permanentlyDisablesDuplicateAndUnsignedMediaWithoutWrites()
        permanentlyDropsWriteAuthorityAfterTransportFailure()
        advancesAcrossSnapshotOverwriteRacesWithoutStaleWrites()
        print("deferred persistent log service: 5 groups passed")
    }

    private static func stagesMediaValidationRecoveryAndBoundedFlushes() {
        let device = CountingBlockDevice(base: makeMedia(logBlocks: 4))
        let source = TestRetainedLogSource(entries: [entry(1), entry(2)])
        withScratch { scratch in
            var service = DeferredPersistentLogService(
                device: device,
                source: source,
                scratch: scratch
            )!
            expect(
                service.serviceOnce(
                    allowRecovery: false,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .partitionReady(startBlock: 8, blockCount: 24),
                "MBR/data selection was not its own stage"
            )
            expect(device.readCount == 1, "partition stage read beyond the MBR")
            expect(
                service.selectedDataPartitionRange == BlockDeviceRange(
                    startBlock: 8,
                    blockCount: 24,
                    within: device.geometry.logicalBlockCount
                ),
                "selected data range was not retained for sibling services"
            )
            expect(
                service.selectedABMediaPartitions == nil,
                "legacy two-partition media was presented as A/B capable"
            )
            expect(
                service.serviceOnce(
                    allowRecovery: false,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .superblockReady(kernelLogBlockCount: 4),
                "signed superblocks did not validate separately"
            )
            expect(service.signedVolumeBootstrapResolved, "bootstrap boundary missing")
            expect(
                service.signedDataVolumeLayout == SwiftOSDataVolumeLayout(
                    geometry: BlockDeviceGeometry(
                        logicalBlockByteCount: 512,
                        logicalBlockCount: 24
                    )!,
                    kernelLogBlockCount: 4
                ),
                "signed data layout was not retained for sibling services"
            )
            expect(device.readCount == 3, "superblock stage read the log arena")
            expect(
                service.serviceOnce(
                    allowRecovery: false,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .idle,
                "network scheduling gate did not pause recovery"
            )
            expect(device.readCount == 3, "paused recovery touched media")

            var scanned: UInt64 = 1
            while scanned < 4 {
                expect(
                    service.serviceOnce(
                        allowRecovery: true,
                        maximumRecoveryBlockCount: 1,
                        maximumAppendCount: 1
                    ) == .recoveryProgress(
                        scannedBlockCount: scanned,
                        totalBlockCount: 4
                    ),
                    "recovery exceeded one block per pass"
                )
                scanned += 1
            }
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .recoveryReady(newestPersistentSequence: nil),
                "bounded recovery did not complete"
            )
            expect(device.readCount == 7, "recovery block budget drifted")

            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .flushed(volatileSequence: 1, persistentSequence: 1),
                "first retained record did not flush"
            )
            expect(device.writeCount == 1 && device.synchronizeCount == 1,
                   "one pass wrote more than one durable record")
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .flushed(volatileSequence: 2, persistentSequence: 2),
                "second retained record did not flush"
            )
            expect(device.writeCount == 2 && device.synchronizeCount == 2,
                   "durability boundary was not per record")
            expect(
                device.writeBlocks == [10, 11],
                "persistent writes escaped data.start plus the log arena"
            )
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .idle,
                "caught-up service manufactured records"
            )
            source.entries.append(entry(3))
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .flushed(volatileSequence: 3, persistentSequence: 3),
                "new retained event after catch-up was not persisted once"
            )
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .idle,
                "new retained event was persisted more than once"
            )
            expect(device.writeBlocks == [10, 11, 12], "log slots were not bounded")
        }
    }

    private static func selectsPersistentLogDataFromStrictABPartitionFour() {
        let base = MemoryBlockDevice(blockCount: 160)
        let dataRange = BlockDeviceRange(
            startBlock: 90,
            blockCount: 60,
            within: base.geometry.logicalBlockCount
        )!
        withScratch { scratch in
            var dataPartition = PartitionBlockDevice(
                base: base,
                partitionRange: dataRange
            )!
            guard case .formatted = SwiftOSDataVolume.initializeEmpty(
                      &dataPartition,
                      kernelLogBlockCount: 4,
                      scratch: scratch
                  )
            else { fatalError("A/B fixture volume format failed") }
        }
        writePartition(
            to: base,
            index: 0,
            type: MBRPartitionType.fat12.rawValue,
            start: 1,
            count: 9
        )
        base.bytes[446] = 0x80
        writePartition(
            to: base,
            index: 1,
            type: MBRPartitionType.fat32LBA.rawValue,
            start: 10,
            count: 40
        )
        writePartition(
            to: base,
            index: 2,
            type: MBRPartitionType.fat32LBA.rawValue,
            start: 50,
            count: 40
        )
        writePartition(
            to: base,
            index: 3,
            type: MBRPartitionType.swiftOSData.rawValue,
            start: 90,
            count: 60
        )
        base.bytes[510] = 0x55
        base.bytes[511] = 0xaa

        let device = CountingBlockDevice(base: base)
        withScratch { scratch in
            var service = DeferredPersistentLogService(
                device: device,
                source: TestRetainedLogSource(entries: []),
                scratch: scratch
            )!
            expect(
                service.serviceOnce(
                    allowRecovery: false,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .partitionReady(startBlock: 90, blockCount: 60),
                "strict A/B media did not select partition four for logs"
            )
            expect(
                service.selectedDataPartitionRange == dataRange,
                "strict A/B partition-four range was not retained"
            )
            expect(
                service.selectedABMediaPartitions == expectedABMedia(),
                "validated A/B topology was not retained as one identity"
            )
            expect(
                service.serviceOnce(
                    allowRecovery: false,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .superblockReady(kernelLogBlockCount: 4),
                "strict A/B partition-four signed volume did not open"
            )
        }

        let invalidBase = MemoryBlockDevice(blockCount: 160)
        invalidBase.bytes = base.bytes
        invalidBase.bytes[Int(dataRange.startBlock) * 512] ^= 0xff
        invalidBase.bytes[Int(dataRange.startBlock + 1) * 512] ^= 0xff
        let invalid = CountingBlockDevice(base: invalidBase)
        withScratch { scratch in
            var service = DeferredPersistentLogService(
                device: invalid,
                source: TestRetainedLogSource(entries: []),
                scratch: scratch
            )!
            expect(
                service.serviceOnce(
                    allowRecovery: false,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .partitionReady(startBlock: 90, blockCount: 60),
                "invalid signed volume did not finish bounded MBR discovery"
            )
            expect(
                service.selectedABMediaPartitions == expectedABMedia(),
                "A/B discovery identity was missing before volume validation"
            )
            guard case .disabled = service.serviceOnce(
                      allowRecovery: false,
                      maximumRecoveryBlockCount: 1,
                      maximumAppendCount: 1
                  )
            else { fatalError("invalid A/B signed volume remained active") }
            expect(
                service.selectedABMediaPartitions == nil
                    && service.selectedDataPartitionRange == nil,
                "failed signed volume retained A/B write authority"
            )
        }
    }

    private static func expectedABMedia() -> SwiftOSABMediaPartitions {
        SwiftOSABMediaPartitions(
            selector: MBRPartition(
                index: 0,
                type: .fat12,
                isBootable: true,
                range: BlockDeviceRange(
                    startBlock: 1,
                    blockCount: 9,
                    within: 160
                )!
            ),
            slotA: MBRPartition(
                index: 1,
                type: .fat32LBA,
                isBootable: false,
                range: BlockDeviceRange(
                    startBlock: 10,
                    blockCount: 40,
                    within: 160
                )!
            ),
            slotB: MBRPartition(
                index: 2,
                type: .fat32LBA,
                isBootable: false,
                range: BlockDeviceRange(
                    startBlock: 50,
                    blockCount: 40,
                    within: 160
                )!
            ),
            data: MBRPartition(
                index: 3,
                type: .swiftOSData,
                isBootable: false,
                range: BlockDeviceRange(
                    startBlock: 90,
                    blockCount: 60,
                    within: 160
                )!
            )
        )
    }

    private static func permanentlyDisablesDuplicateAndUnsignedMediaWithoutWrites() {
        let duplicateBase = makeMedia(logBlocks: 4)
        writePartition(
            to: duplicateBase,
            index: 2,
            type: 0xda,
            start: 32,
            count: 4
        )
        let duplicate = CountingBlockDevice(base: duplicateBase)
        withScratch { scratch in
            var service = DeferredPersistentLogService(
                device: duplicate,
                source: TestRetainedLogSource(entries: []),
                scratch: scratch
            )!
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .disabled(.mediaLayout(.duplicateDataPartition)),
                "duplicate 0xDA partitions were accepted"
            )
            expect(service.isPermanentlyDisabled, "ambiguity remained retryable")
            expect(duplicate.writeCount == 0, "ambiguous media was written")
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .idle,
                "disabled media retried"
            )
        }

        let unsignedBase = MemoryBlockDevice(blockCount: 40)
        encodeMBR(on: unsignedBase)
        let unsigned = CountingBlockDevice(base: unsignedBase)
        withScratch { scratch in
            var service = DeferredPersistentLogService(
                device: unsigned,
                source: TestRetainedLogSource(entries: []),
                scratch: scratch
            )!
            _ = service.serviceOnce(
                allowRecovery: true,
                maximumRecoveryBlockCount: 1,
                maximumAppendCount: 1
            )
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .disabled(
                    .signedVolume(.volume(.missingSuperblock))
                ),
                "unsigned volume was opened or formatted"
            )
            expect(unsigned.writeCount == 0, "unsigned volume was modified")
        }
    }

    private static func permanentlyDropsWriteAuthorityAfterTransportFailure() {
        let device = CountingBlockDevice(base: makeMedia(logBlocks: 2))
        let source = TestRetainedLogSource(entries: [entry(1)])
        withScratch { scratch in
            var service = DeferredPersistentLogService(
                device: device,
                source: source,
                scratch: scratch
            )!
            _ = service.serviceOnce(
                allowRecovery: true,
                maximumRecoveryBlockCount: 1,
                maximumAppendCount: 1
            )
            _ = service.serviceOnce(
                allowRecovery: true,
                maximumRecoveryBlockCount: 1,
                maximumAppendCount: 1
            )
            _ = service.serviceOnce(
                allowRecovery: true,
                maximumRecoveryBlockCount: 2,
                maximumAppendCount: 1
            )
            device.base.failWrites = true
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .disabled(.append(.writeFailed(.transportFailure))),
                "failed append retained write authority"
            )
            let writes = device.writeCount
            device.base.failWrites = false
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .idle,
                "failed transport retried after recovery"
            )
            expect(device.writeCount == writes, "disabled service wrote again")
        }
    }

    private static func advancesAcrossSnapshotOverwriteRacesWithoutStaleWrites() {
        let device = CountingBlockDevice(base: makeMedia(logBlocks: 4))
        let source = TestRetainedLogSource(
            entries: [entry(1), entry(2), entry(3)]
        )
        source.forcedLostSequence = 1
        source.forcedOldestAvailableSequence = 3
        withScratch { scratch in
            var service = DeferredPersistentLogService(
                device: device,
                source: source,
                scratch: scratch
            )!
            _ = service.serviceOnce(
                allowRecovery: true,
                maximumRecoveryBlockCount: 1,
                maximumAppendCount: 1
            )
            _ = service.serviceOnce(
                allowRecovery: true,
                maximumRecoveryBlockCount: 1,
                maximumAppendCount: 1
            )
            _ = service.serviceOnce(
                allowRecovery: true,
                maximumRecoveryBlockCount: 4,
                maximumAppendCount: 1
            )
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .volatileEntriesLost(oldestAvailableSequence: 3),
                "stats-to-entry overwrite race did not advance"
            )
            expect(device.writeBlocks.isEmpty, "lost slot wrote stale bytes")
            expect(
                service.serviceOnce(
                    allowRecovery: true,
                    maximumRecoveryBlockCount: 1,
                    maximumAppendCount: 1
                ) == .flushed(volatileSequence: 3, persistentSequence: 1),
                "race recovery did not resume at the reported oldest entry"
            )
            expect(device.writeBlocks == [10], "race recovery escaped log arena")
        }
    }

    private static func makeMedia(logBlocks: UInt64) -> MemoryBlockDevice {
        let device = MemoryBlockDevice(blockCount: 40)
        let range = BlockDeviceRange(
            startBlock: 8,
            blockCount: 24,
            within: device.geometry.logicalBlockCount
        )!
        withScratch { scratch in
            var partition = PartitionBlockDevice(
                base: device,
                partitionRange: range
            )!
            guard case .formatted = SwiftOSDataVolume.initializeEmpty(
                      &partition,
                      kernelLogBlockCount: logBlocks,
                      scratch: scratch
                  )
            else { fatalError("fixture volume format failed") }
        }
        encodeMBR(on: device)
        return device
    }

    private static func encodeMBR(on device: MemoryBlockDevice) {
        writePartition(to: device, index: 0, type: 0x0c, start: 1, count: 7)
        writePartition(to: device, index: 1, type: 0xda, start: 8, count: 24)
        device.bytes[510] = 0x55
        device.bytes[511] = 0xaa
    }

    private static func writePartition(
        to device: MemoryBlockDevice,
        index: Int,
        type: UInt8,
        start: UInt32,
        count: UInt32
    ) {
        let offset = 446 + index * 16
        device.bytes[offset] = 0
        device.bytes[offset + 4] = type
        writeLE32(start, to: device, at: offset + 8)
        writeLE32(count, to: device, at: offset + 12)
    }

    private static func writeLE32(
        _ value: UInt32,
        to device: MemoryBlockDevice,
        at offset: Int
    ) {
        device.bytes[offset] = UInt8(truncatingIfNeeded: value)
        device.bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        device.bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        device.bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func entry(_ sequence: UInt64) -> KernelLogEntry {
        KernelLogEntry(
            sequence: sequence,
            event: KernelLogEvent(
                timestampTicks: sequence * 100,
                level: .info,
                subsystem: .drivers,
                eventCode: UInt32(truncatingIfNeeded: sequence),
                argument0: sequence
            )
        )
    }

    private static func withScratch(
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { pointer.deallocate() }
        body(UnsafeMutableRawBufferPointer(start: pointer, count: 512))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
