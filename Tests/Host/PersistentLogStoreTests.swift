@main
struct PersistentLogStoreTests {
    static func main() {
        formatsAndSeparatesTheDataVolume()
        persistsAndBoundsKernelLogRecords()
        recoversFromTornRecordsAndOneBadSuperblock()
        roundTripsStructuredKernelEvents()
        print("persistent log store host tests: 4 groups passed")
    }

    private static func formatsAndSeparatesTheDataVolume() {
        let device = MemoryBlockDevice(blockCount: 24)
        device.bytes = [UInt8](repeating: 0xa5, count: device.bytes.count)
        withScratch { scratch in
            var formatter = device
            expect(
                SwiftOSDataVolume.initializeEmpty(
                    &formatter,
                    kernelLogBlockCount: 6,
                    scratch: scratch
                ) == .formatted(
                    SwiftOSDataVolumeLayout(
                        geometry: device.geometry,
                        kernelLogBlockCount: 6
                    )!
                ),
                "data volume formatting failed"
            )
            var opener = device
            guard case .volume(let layout) = SwiftOSDataVolume.open(
                &opener,
                scratch: scratch
            ) else { fail("formatted volume did not reopen") }
            expect(layout.kernelLogStartBlock == 2, "log arena start")
            expect(layout.kernelLogBlockCount == 6, "log arena size")
            expect(layout.userDataStartBlock == 8, "user arena start")
            expect(layout.userDataBlockCount == 16, "user arena size")
            expect(
                device.bytes[8 * 512] == 0xa5
                    && device.bytes[device.bytes.count - 1] == 0xa5,
                "formatting erased the user-data arena"
            )
        }
    }

    private static func persistsAndBoundsKernelLogRecords() {
        let device = formattedDevice(blockCount: 16, logBlocks: 2)
        withScratch { scratch in
            var store = openStore(device, scratch: scratch)
            expect(
                append([1, 2, 3], timestamp: 10, to: &store)
                    == .appended(sequence: 1),
                "first append"
            )
            expect(
                append([4, 5], timestamp: 20, to: &store)
                    == .appended(sequence: 2),
                "second append"
            )
            expect(
                append([6], timestamp: 30, to: &store)
                    == .appended(sequence: 3),
                "wrapped append"
            )

            var output = [UInt8](repeating: 0, count: 8)
            output.withUnsafeMutableBytes {
                expect(
                    store.read(sequence: 1, into: $0) == .notFound,
                    "overwritten record remained visible"
                )
                expect(
                    store.read(sequence: 2, into: $0)
                        == .record(
                            PersistentLogRecordMetadata(
                                sequence: 2,
                                timestampTicks: 20,
                                payloadByteCount: 2
                            )
                        ),
                    "retained record could not be read"
                )
            }
            expect(output[0] == 4 && output[1] == 5, "payload changed")

            let reopened = openStore(device, scratch: scratch)
            expect(reopened.newestSequence == 3, "recovery head changed")
        }
    }

    private static func recoversFromTornRecordsAndOneBadSuperblock() {
        let device = formattedDevice(blockCount: 18, logBlocks: 4)
        withScratch { scratch in
            var store = openStore(device, scratch: scratch)
            _ = append([0x10], timestamp: 1, to: &store)
            _ = append([0x20], timestamp: 2, to: &store)

            // Sequence two occupies log slot one, physical block three.
            device.bytes[3 * 512 + 40] ^= 0xff
            var recovered = openStore(device, scratch: scratch)
            expect(recovered.newestSequence == 1, "torn newest record was accepted")
            expect(
                append([0x30], timestamp: 3, to: &recovered)
                    == .appended(sequence: 2),
                "recovery did not reuse the uncommitted sequence"
            )

            device.bytes[0] ^= 0xff
            var oneHeader = device
            guard case .volume = SwiftOSDataVolume.open(
                &oneHeader,
                scratch: scratch
            ) else { fail("backup superblock was not used") }
            device.bytes[512] ^= 0xff
            var noHeaders = device
            expect(
                SwiftOSDataVolume.open(&noHeaders, scratch: scratch)
                    == .failure(.missingSuperblock),
                "volume with no valid superblock was accepted"
            )
        }
    }

    private static func roundTripsStructuredKernelEvents() {
        let entry = KernelLogEntry(
            sequence: 99,
            event: KernelLogEvent(
                timestampTicks: 123_456,
                level: .error,
                subsystem: .drivers,
                eventCode: 0x1234_5678,
                processorID: 3,
                flags: 7,
                argument0: 8,
                argument1: 9
            )
        )
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes.withUnsafeMutableBytes {
            expect(
                PersistentKernelLogCodec.encode(entry, into: $0),
                "kernel event encode failed"
            )
        }
        let decoded = bytes.withUnsafeBytes {
            PersistentKernelLogCodec.decode($0)
        }
        expect(decoded == entry, "kernel event payload changed")

        let device = formattedDevice(blockCount: 12, logBlocks: 3)
        withScratch { scratch in
            var store = openStore(device, scratch: scratch)
            expect(
                store.appendKernelLogEntry(entry) == .appended(sequence: 1),
                "structured kernel event append failed"
            )
        }
    }

    private static func formattedDevice(
        blockCount: UInt64,
        logBlocks: UInt64
    ) -> MemoryBlockDevice {
        let device = MemoryBlockDevice(blockCount: blockCount)
        withScratch { scratch in
            var formatter = device
            guard case .formatted = SwiftOSDataVolume.initializeEmpty(
                &formatter,
                kernelLogBlockCount: logBlocks,
                scratch: scratch
            ) else { fail("test volume format failed") }
        }
        return device
    }

    private static func openStore(
        _ device: MemoryBlockDevice,
        scratch: UnsafeMutableRawBufferPointer
    ) -> PersistentLogStore<MemoryBlockDevice> {
        switch PersistentLogStore.open(device: device, scratch: scratch) {
        case .store(let store): return store
        case .failure: fail("test log store open failed")
        }
    }

    private static func append(
        _ payload: [UInt8],
        timestamp: UInt64,
        to store: inout PersistentLogStore<MemoryBlockDevice>
    ) -> PersistentLogAppendResult {
        store.append(
            payloadByteCount: payload.count,
            timestampTicks: timestamp
        ) { output in
            payload.withUnsafeBytes { source in
                guard let destination = output.baseAddress,
                      let sourceAddress = source.baseAddress
                else { return false }
                destination.copyMemory(
                    from: sourceAddress,
                    byteCount: payload.count
                )
                return true
            }
        }
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
