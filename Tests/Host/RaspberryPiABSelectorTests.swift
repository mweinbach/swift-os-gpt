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
        rejectsMalformedSelectorMetadataWithoutWriting()
        reportsWriteAndSynchronizationFailures()
        rejectsUnexpectedPartitionGeometry()
        print("Raspberry Pi A/B selector: 4 groups passed")
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
                ) == .failure(.malformedAllocationTables),
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
                ) == .failure(.write(.transportFailure)),
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
                ) == .failure(.synchronize(.transportFailure)),
                "selector synchronization failure was hidden"
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
        writeLE16(512, to: device, at: 11)
        device.bytes[13] = 1
        writeLE16(1, to: device, at: 14)
        device.bytes[16] = 2
        writeLE16(32, to: device, at: 17)
        writeLE16(2_047, to: device, at: 19)
        device.bytes[21] = 0xf8
        writeLE16(6, to: device, at: 22)
        writeLE32(1, to: device, at: 28)
        writeASCII("SWIFTOS-CTL", to: device, at: 43)
        writeASCII("FAT12   ", to: device, at: 54)
        device.bytes[510] = 0x55
        device.bytes[511] = 0xaa

        for block in [1, 7] {
            let offset = block * 512
            device.bytes[offset] = 0xf8
            device.bytes[offset + 1] = 0xff
            device.bytes[offset + 2] = 0xff
            device.bytes[offset + 3] = 0xff
            device.bytes[offset + 4] = 0x0f
        }

        let root = 13 * 512
        writeASCII("AUTOBOOTTXT", to: device, at: root)
        device.bytes[root + 11] = 0x20
        writeLE16(2, to: device, at: root + 26)
        writeLE32(UInt32(defaultPolicy.count), to: device, at: root + 28)
        let data = Int(RaspberryPiABSelector.autobootDataBlock) * 512
        var index = 0
        while index < defaultPolicy.count {
            device.bytes[data + index] = defaultPolicy[index]
            index += 1
        }
        return device
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
