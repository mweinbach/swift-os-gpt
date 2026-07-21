@main
struct RaspberryPiABSelectorTests {
    private static let policyA = Array(
        "[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n"
            .utf8
    )
    private static let policyB = Array(
        "[all]\ntryboot_a_b=1\nboot_partition=3\n[tryboot]\nboot_partition=2\n"
            .utf8
    )

    static func main() {
        inspectsAndCommitsOnlyTheSelectorPolicyCluster()
        repairsTornPolicyWithoutTouchingImmutableRescue()
        rejectsCorruptRescueManifestAndPayloadWithoutWriting()
        rejectsMalformedSelectorMetadataWithoutWriting()
        reportsWriteAndSynchronizationFailures()
        rejectsUnexpectedPartitionGeometry()
        print("Raspberry Pi A/B selector: 6 groups passed")
    }

    private static func rejectsCorruptRescueManifestAndPayloadWithoutWriting() {
        var badManifest = makeSelector(defaultPolicy: policyA)
        badManifest.bytes[64 + 28] ^= 0x80
        let badManifestBefore = badManifest.bytes
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &badManifest,
                    scratch: scratch
                ) == .rejectedBeforeWrite(.malformedRescueManifest),
                "invalid rescue manifest gained selector-write authority"
            )
            expect(
                badManifest.bytes == badManifestBefore,
                "invalid rescue manifest was modified"
            )
        }

        var badPayload = makeSelector(defaultPolicy: policyA)
        badPayload.bytes[16 * 512] ^= 0x80
        let badPayloadBefore = badPayload.bytes
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &badPayload,
                    scratch: scratch
                ) == .rejectedBeforeWrite(.corruptRescuePayload),
                "corrupt rescue payload gained selector-write authority"
            )
            expect(
                badPayload.bytes == badPayloadBefore,
                "corrupt rescue payload was modified"
            )
        }

        var badFreeSpace = makeSelector(defaultPolicy: policyA)
        let finalBlock = Int(RaspberryPiABSelector.partitionBlockCount - 1)
        badFreeSpace.bytes[finalBlock * 512] = 0x5a
        let badFreeSpaceBefore = badFreeSpace.bytes
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &badFreeSpace,
                    scratch: scratch
                ) == .rejectedBeforeWrite(.corruptRescuePayload),
                "nonzero selector free space gained write authority"
            )
            expect(
                badFreeSpace.bytes == badFreeSpaceBefore,
                "corrupt selector free space was modified"
            )
        }
    }

    private static func inspectsAndCommitsOnlyTheSelectorPolicyCluster() {
        var device = makeSelector(defaultPolicy: policyA)
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.inspect(&device, scratch: scratch)
                    == .state(.defaultA),
                "fresh selector did not report slot A"
            )
            let before = device.bytes
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &device,
                    scratch: scratch
                ) == .committed(.defaultB),
                "selector did not commit slot B"
            )
            expect(
                RaspberryPiABSelector.inspect(&device, scratch: scratch)
                    == .state(.defaultB),
                "selector B readback did not validate"
            )
            let policyStart = Int(RaspberryPiABSelector.autobootDataBlock) * 512
            let policyEnd = policyStart + 512
            var index = 0
            while index < before.count {
                if index < policyStart || index >= policyEnd {
                    expect(
                        device.bytes[index] == before[index],
                        "selector commit modified metadata or another cluster"
                    )
                }
                index += 1
            }
            expect(
                Array(device.bytes[policyStart..<policyStart + policyB.count])
                    == policyB,
                "selector B policy bytes mismatch"
            )
            let committed = device.bytes
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &device,
                    scratch: scratch
                ) == .unchanged(.defaultB),
                "idempotent selector commit rewrote the same policy"
            )
            expect(device.bytes == committed, "unchanged commit touched media")
        }
    }

    private static func repairsTornPolicyWithoutTouchingImmutableRescue() {
        var device = makeSelector(defaultPolicy: policyA)
        let policyStart = Int(RaspberryPiABSelector.autobootDataBlock) * 512
        var index = 0
        while index < 512 {
            device.bytes[policyStart + index] = UInt8(
                truncatingIfNeeded: index &* 37
            )
            index += 1
        }
        let torn = device.bytes
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.inspect(&device, scratch: scratch)
                    == .failure(.malformedPolicy),
                "torn selector policy was presented as valid"
            )
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &device,
                    scratch: scratch
                ) == .committed(.defaultB),
                "torn selector policy could not be transactionally repaired"
            )
            index = 0
            while index < torn.count {
                if index < policyStart || index >= policyStart + 512 {
                    expect(
                        device.bytes[index] == torn[index],
                        "torn-policy repair modified immutable rescue bytes"
                    )
                }
                index += 1
            }
            expect(
                RaspberryPiABSelector.inspect(&device, scratch: scratch)
                    == .state(.defaultB),
                "repaired selector did not validate"
            )
        }
    }

    private static func rejectsMalformedSelectorMetadataWithoutWriting() {
        var device = makeSelector(defaultPolicy: policyA)
        device.bytes[7 * 512 + 4] ^= 0x80
        let before = device.bytes
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.inspect(&device, scratch: scratch)
                    == .failure(.malformedAllocationTables),
                "disagreeing FAT12 copies were accepted"
            )
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &device,
                    scratch: scratch
                ) == .rejectedBeforeWrite(.malformedAllocationTables),
                "malformed selector metadata gained write authority"
            )
            expect(device.bytes == before, "malformed selector was modified")
        }
    }

    private static func reportsWriteAndSynchronizationFailures() {
        var writeFailure = makeSelector(defaultPolicy: policyA)
        writeFailure.failWrites = true
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &writeFailure,
                    scratch: scratch
                ) == .durabilityUncertain(.write(.transportFailure)),
                "selector write failure was hidden"
            )
        }

        var syncFailure = makeSelector(defaultPolicy: policyA)
        syncFailure.failSynchronization = true
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &syncFailure,
                    scratch: scratch
                ) == .durabilityUncertain(.synchronize(.transportFailure)),
                "selector synchronization failure was hidden"
            )
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &syncFailure,
                    scratch: scratch
                ) == .durabilityUncertain(.synchronize(.transportFailure)),
                "cached selector bytes bypassed a failed durability barrier"
            )
            syncFailure.failSynchronization = false
            expect(
                RaspberryPiABSelector.commit(
                    defaultSlot: .b,
                    to: &syncFailure,
                    scratch: scratch
                ) == .unchanged(.defaultB),
                "selector retry did not prove durability by sync and readback"
            )
        }
    }

    private static func rejectsUnexpectedPartitionGeometry() {
        var device = MemoryBlockDevice(blockCount: 2_048)
        withScratch { scratch in
            expect(
                RaspberryPiABSelector.inspect(&device, scratch: scratch)
                    == .failure(.invalidGeometry),
                "wrong selector extent was accepted"
            )
        }
    }

    private static func makeSelector(
        defaultPolicy: [UInt8]
    ) -> MemoryBlockDevice {
        let device = MemoryBlockDevice(
            blockCount: RaspberryPiABSelector.partitionBlockCount
        )
        device.bytes[0] = 0xeb
        device.bytes[1] = 0x3c
        device.bytes[2] = 0x90
        writeASCII("SWIFTOS ", to: device, at: 3)
        writeLE16(512, to: device, at: 11)
        device.bytes[13] = 1
        writeLE16(1, to: device, at: 14)
        device.bytes[16] = 2
        writeLE16(32, to: device, at: 17)
        writeLE16(2_047, to: device, at: 19)
        device.bytes[21] = 0xf8
        writeLE16(6, to: device, at: 22)
        writeLE16(63, to: device, at: 24)
        writeLE16(255, to: device, at: 26)
        writeLE32(1, to: device, at: 28)
        device.bytes[36] = 0x80
        device.bytes[38] = 0x29
        writeLE32(0x4354_4c31, to: device, at: 39)
        writeASCII("SWIFTOS-CTL", to: device, at: 43)
        writeASCII("FAT12   ", to: device, at: 54)
        device.bytes[510] = 0x55
        device.bytes[511] = 0xaa

        let config = Array("rescue-config\n".utf8)
        let kernel = [UInt8](repeating: 0xa5, count: 700)
        let deviceTree = [UInt8](repeating: 0x5a, count: 65)
        let configClusters = clusterCount(config.count)
        let kernelClusters = clusterCount(kernel.count)
        let treeClusters = clusterCount(deviceTree.count)
        let configFirst = 3
        let kernelFirst = configFirst + configClusters
        let treeFirst = kernelFirst + kernelClusters

        writeASCII("SWRSQ001", to: device, at: 64)
        writeLE16(1, to: device, at: 72)
        writeLE16(128, to: device, at: 74)
        writeLE16(3, to: device, at: 76)
        writeLE16(0, to: device, at: 78)
        writeLE32(UInt32(config.count), to: device, at: 80)
        writeLE32(UInt32(kernel.count), to: device, at: 84)
        writeLE32(UInt32(deviceTree.count), to: device, at: 88)
        writeDigest(digest(config), to: device, at: 92)
        writeDigest(digest(kernel), to: device, at: 124)
        writeDigest(digest(deviceTree), to: device, at: 156)
        let manifestCRC = device.bytes.withUnsafeBytes { bytes in
            StorageCRC32.checksum(UnsafeRawBufferPointer(
                start: bytes.baseAddress!.advanced(by: 64),
                count: 124
            ))
        }
        writeLE32(manifestCRC, to: device, at: 188)

        for fatBlock in [1, 7] {
            setFAT12Entry(0x0ff8, cluster: 0, to: device, fatBlock: fatBlock)
            setFAT12Entry(0x0fff, cluster: 1, to: device, fatBlock: fatBlock)
            setFAT12Entry(0x0fff, cluster: 2, to: device, fatBlock: fatBlock)
            writeFATChain(
                firstCluster: configFirst,
                clusterCount: configClusters,
                to: device,
                fatBlock: fatBlock
            )
            writeFATChain(
                firstCluster: kernelFirst,
                clusterCount: kernelClusters,
                to: device,
                fatBlock: fatBlock
            )
            writeFATChain(
                firstCluster: treeFirst,
                clusterCount: treeClusters,
                to: device,
                fatBlock: fatBlock
            )
        }

        let root = 13 * 512
        writeRootEntry(
            name: "AUTOBOOTTXT",
            firstCluster: 2,
            byteCount: defaultPolicy.count,
            to: device,
            at: root
        )
        writeRootEntry(
            name: "CONFIG  TXT",
            firstCluster: configFirst,
            byteCount: config.count,
            to: device,
            at: root + 32
        )
        writeRootEntry(
            name: "KERNEL8 IMG",
            firstCluster: kernelFirst,
            byteCount: kernel.count,
            to: device,
            at: root + 64
        )
        writeRootEntry(
            name: "RESCUE  DTB",
            firstCluster: treeFirst,
            byteCount: deviceTree.count,
            to: device,
            at: root + 96
        )
        let data = Int(RaspberryPiABSelector.autobootDataBlock) * 512
        var index = 0
        while index < defaultPolicy.count {
            device.bytes[data + index] = defaultPolicy[index]
            index += 1
        }
        writeFile(config, firstCluster: configFirst, to: device)
        writeFile(kernel, firstCluster: kernelFirst, to: device)
        writeFile(deviceTree, firstCluster: treeFirst, to: device)
        return device
    }

    private static func clusterCount(_ byteCount: Int) -> Int {
        max(1, (byteCount + 511) / 512)
    }

    private static func digest(_ bytes: [UInt8]) -> USBKernelUpdateSHA256Digest {
        var value = USBKernelUpdateSHA256()
        let updated = bytes.withUnsafeBytes { value.update($0) }
        expect(updated, "test SHA-256 rejected bounded fixture")
        return value.finalizedDigest()
    }

    private static func writeDigest(
        _ digest: USBKernelUpdateSHA256Digest,
        to device: MemoryBlockDevice,
        at offset: Int
    ) {
        let written = device.bytes.withUnsafeMutableBytes {
            digest.write(to: $0, at: offset)
        }
        expect(written, "test digest write failed")
    }

    private static func setFAT12Entry(
        _ value: UInt16,
        cluster: Int,
        to device: MemoryBlockDevice,
        fatBlock: Int
    ) {
        let offset = fatBlock * 512 + cluster + cluster / 2
        if cluster & 1 == 1 {
            device.bytes[offset] = (device.bytes[offset] & 0x0f)
                | UInt8(truncatingIfNeeded: value << 4)
            device.bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 4)
        } else {
            device.bytes[offset] = UInt8(truncatingIfNeeded: value)
            device.bytes[offset + 1] = (device.bytes[offset + 1] & 0xf0)
                | UInt8(truncatingIfNeeded: value >> 8)
        }
    }

    private static func writeFATChain(
        firstCluster: Int,
        clusterCount: Int,
        to device: MemoryBlockDevice,
        fatBlock: Int
    ) {
        var index = 0
        while index < clusterCount {
            setFAT12Entry(
                index + 1 == clusterCount
                    ? 0x0fff : UInt16(firstCluster + index + 1),
                cluster: firstCluster + index,
                to: device,
                fatBlock: fatBlock
            )
            index += 1
        }
    }

    private static func writeRootEntry(
        name: String,
        firstCluster: Int,
        byteCount: Int,
        to device: MemoryBlockDevice,
        at offset: Int
    ) {
        writeASCII(name, to: device, at: offset)
        device.bytes[offset + 11] = 0x20
        writeLE16(0x0021, to: device, at: offset + 16)
        writeLE16(0x0021, to: device, at: offset + 18)
        writeLE16(0x0021, to: device, at: offset + 24)
        writeLE16(UInt16(firstCluster), to: device, at: offset + 26)
        writeLE32(UInt32(byteCount), to: device, at: offset + 28)
    }

    private static func writeFile(
        _ bytes: [UInt8],
        firstCluster: Int,
        to device: MemoryBlockDevice
    ) {
        let offset = (15 + firstCluster - 2) * 512
        var index = 0
        while index < bytes.count {
            device.bytes[offset + index] = bytes[index]
            index += 1
        }
    }

    private static func writeASCII(
        _ value: String,
        to device: MemoryBlockDevice,
        at offset: Int
    ) {
        for (index, byte) in value.utf8.enumerated() {
            device.bytes[offset + index] = byte
        }
    }

    private static func writeLE16(
        _ value: UInt16,
        to device: MemoryBlockDevice,
        at offset: Int
    ) {
        device.bytes[offset] = UInt8(truncatingIfNeeded: value)
        device.bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeLE32(
        _ value: UInt32,
        to device: MemoryBlockDevice,
        at offset: Int
    ) {
        writeLE16(UInt16(truncatingIfNeeded: value), to: device, at: offset)
        writeLE16(
            UInt16(truncatingIfNeeded: value >> 16),
            to: device,
            at: offset + 2
        )
    }

    private static func withScratch(
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        var bytes = [UInt8](repeating: 0, count: 1_024)
        bytes.withUnsafeMutableBytes(body)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
