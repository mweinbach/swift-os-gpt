@main
struct PersistentVolumeBootstrapTests {
    typealias Provider = SwiftFSPersistentProvider<MemoryBlockDevice>

    static func main() {
        initializesOnlyBlankOuterVolumes()
        initializesAndRemountsSwiftFS()
        refusesNonblankUnknownMedia()
        preservesCorruptKnownMedia()
        print("persistent volume bootstrap host tests: 4 groups passed")
    }

    private static func initializesOnlyBlankOuterVolumes() {
        var device = MemoryBlockDevice(blockCount: 96)
        withScratch { scratch in
            guard case .initialized(let initialized) =
                SwiftOSDataVolumeBootstrap.openOrInitializeBlank(
                    &device,
                    kernelLogBlockCount: 8,
                    scratch: scratch
                )
            else { fail("blank outer volume was not initialized") }
            expect(initialized.userDataStartBlock == 10, "outer user start")

            guard case .opened(let reopened) =
                SwiftOSDataVolumeBootstrap.openOrInitializeBlank(
                    &device,
                    kernelLogBlockCount: 8,
                    scratch: scratch
                )
            else { fail("valid outer volume did not reopen") }
            expect(reopened == initialized, "outer layout changed on reopen")
        }
    }

    private static func initializesAndRemountsSwiftFS() {
        let device = MemoryBlockDevice(blockCount: 80)
        withScratch { scratch in
            guard case .ready(var provider, .formatted) =
                SwiftFSPersistentVolumeBootstrap.openOrFormatBlank(
                    device,
                    volumeIdentifier: volume(42),
                    nodeCapacity: 8,
                    scratch: scratch
                )
            else { fail("blank SwiftFS volume was not formatted") }
            let root = provider.rootNodeIdentifier
            guard case .metadata(let metadata) = provider.metadata(for: root)
            else { fail("formatted root unavailable") }
            expect(metadata.kind == .directory, "formatted root kind")

            guard case .ready(_, .mounted) =
                SwiftFSPersistentVolumeBootstrap.openOrFormatBlank(
                    device,
                    volumeIdentifier: volume(42),
                    nodeCapacity: 8,
                    scratch: scratch
                )
            else { fail("SwiftFS volume did not remount") }
        }
    }

    private static func refusesNonblankUnknownMedia() {
        var outer = MemoryBlockDevice(blockCount: 96)
        outer.bytes[3] = 0x7f
        withScratch { scratch in
            expect(
                SwiftOSDataVolumeBootstrap.openOrInitializeBlank(
                    &outer,
                    kernelLogBlockCount: 8,
                    scratch: scratch
                ) == .failure(.nonblankMediaWithoutValidSuperblock),
                "unknown outer media was overwritten"
            )
        }

        let filesystem = MemoryBlockDevice(blockCount: 80)
        filesystem.bytes[10] = 0x55
        withScratch { scratch in
            guard case .failure(.nonblankMediaWithoutValidSuperblock) =
                SwiftFSPersistentVolumeBootstrap.openOrFormatBlank(
                    filesystem,
                    volumeIdentifier: volume(43),
                    nodeCapacity: 8,
                    scratch: scratch
                )
            else { fail("unknown filesystem media was overwritten") }
        }
    }

    private static func preservesCorruptKnownMedia() {
        let device = MemoryBlockDevice(blockCount: 80)
        withScratch { scratch in
            var formatted = device
            guard case .formatted = Provider.format(
                &formatted,
                volumeIdentifier: volume(44),
                nodeCapacity: 8,
                scratch: scratch
            ) else { fail("fixture format failed") }
            formatted.bytes[124] ^= 0x80
            let before = formatted.bytes
            guard case .failure =
                SwiftFSPersistentVolumeBootstrap.openOrFormatBlank(
                    formatted,
                    volumeIdentifier: volume(44),
                    nodeCapacity: 8,
                    scratch: scratch
                )
            else { fail("corrupt filesystem unexpectedly mounted") }
            expect(formatted.bytes == before, "corrupt filesystem was changed")
        }
    }

    private static func withScratch(_ body: (UnsafeMutableRawBufferPointer) -> Void) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: 1_024,
            alignment: 16
        )
        defer { pointer.deallocate() }
        body(UnsafeMutableRawBufferPointer(start: pointer, count: 1_024))
    }

    private static func volume(_ value: UInt64) -> VFSVolumeIdentifier {
        VFSVolumeIdentifier(rawValue: value)!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: StaticString) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("persistent volume bootstrap test failed: \(message)")
    }
}
