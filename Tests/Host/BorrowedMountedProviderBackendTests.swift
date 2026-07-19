private struct BridgeTestProvider: VFSNodeProvider {
    var volumeIdentifier = VFSVolumeIdentifier(rawValue: 41)!
    var fileBytes: [UInt8] = Array("seed".utf8)
    var lookupCallCount = 0
    var metadataCallCount = 0
    var readCallCount = 0
    var writeCallCount = 0
    var directoryCallCount = 0
    var returnForeignLookup = false
    var returnForeignDirectoryEntry = false
    var returnWrongMetadata = false

    mutating func metadata(for node: VFSNodeIdentifier) -> VFSMetadataResult {
        metadataCallCount += 1
        guard node.volume == volumeIdentifier else { return .failure(.notFound) }
        if returnWrongMetadata, node.localValue == 3 {
            return .metadata(makeMetadata(local: 2, kind: .directory))
        }
        switch node.localValue {
        case 1, 2, 5:
            return .metadata(makeMetadata(local: node.localValue, kind: .directory))
        case 3:
            return .metadata(
                makeMetadata(
                    local: 3,
                    kind: .regularFile,
                    byteCount: UInt64(fileBytes.count)
                )
            )
        case 4:
            return .metadata(makeMetadata(local: 4, kind: .symbolicLink))
        default:
            return .failure(.notFound)
        }
    }

    mutating func lookup(
        parent: VFSNodeIdentifier,
        name: VFSNameView
    ) -> VFSLookupResult {
        lookupCallCount += 1
        guard parent.volume == volumeIdentifier else { return .failure(.notFound) }
        let local: UInt64?
        switch parent.localValue {
        case 1:
            if nameEquals(name, "alice") { local = 2 }
            else if nameEquals(name, "link") { local = 4 }
            else if nameEquals(name, "loop") { local = 5 }
            else { local = nil }
        case 2:
            local = nameEquals(name, "note") ? 3 : nil
        case 5:
            local = nameEquals(name, "loop") ? 5 : nil
        default:
            return .failure(.notDirectory)
        }
        guard let local else { return .failure(.notFound) }
        if returnForeignLookup {
            return .node(
                makeTestMetadata(
                    volume: VFSVolumeIdentifier(rawValue: 99)!,
                    local: local,
                    kind: local == 3 ? .regularFile : .directory
                )
            )
        }
        return metadata(for: VFSNodeIdentifier(volume: volumeIdentifier, localValue: local)!)
            .asLookupResult
    }

    mutating func readDirectory(
        node: VFSNodeIdentifier,
        after cookie: VFSDirectoryCookie,
        nameOutput: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult {
        directoryCallCount += 1
        guard node.volume == volumeIdentifier else { return .failure(.notFound) }
        if cookie.rawValue != 0 { return .end }
        let childLocal: UInt64
        let childKind: VFSNodeKind
        let name: StaticString
        switch node.localValue {
        case 1:
            childLocal = 2
            childKind = .directory
            name = "alice"
        case 2:
            childLocal = 3
            childKind = .regularFile
            name = "note"
        default:
            return .failure(.notDirectory)
        }
        return name.withUTF8Buffer { source in
            guard nameOutput.count >= source.count else {
                return .nameBufferTooSmall(requiredByteCount: source.count)
            }
            var index = 0
            while index < source.count {
                nameOutput[index] = source[index]
                index += 1
            }
            let raw = UnsafeRawBufferPointer(
                start: nameOutput.baseAddress,
                count: source.count
            )
            guard case .name(let view) = VFSNameValidator.validate(raw) else {
                return .failure(.corrupt)
            }
            let entryVolume = returnForeignDirectoryEntry
                ? VFSVolumeIdentifier(rawValue: 99)!
                : volumeIdentifier
            return .entry(
                VFSDirectoryEntry(
                    identifier: VFSNodeIdentifier(
                        volume: entryVolume,
                        localValue: childLocal
                    )!,
                    kind: childKind,
                    name: view
                ),
                nextCookie: VFSDirectoryCookie(rawValue: 1)
            )
        }
    }

    mutating func read(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSDataIOResult {
        readCallCount += 1
        guard node.volume == volumeIdentifier, node.localValue == 3 else {
            return .failure(.notFound)
        }
        guard offset <= UInt64(fileBytes.count) else {
            return .failure(.invalidOffset)
        }
        let available = fileBytes.count - Int(offset)
        let count = available < output.count ? available : output.count
        var index = 0
        while index < count {
            output[index] = fileBytes[Int(offset) + index]
            index += 1
        }
        return .transferred(byteCount: count)
    }

    mutating func write(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> VFSDataIOResult {
        writeCallCount += 1
        guard node.volume == volumeIdentifier, node.localValue == 3 else {
            return .failure(.notFound)
        }
        guard UInt64(input.count) <= UInt64.max - offset,
              offset + UInt64(input.count) <= UInt64(Int.max)
        else { return .failure(.invalidOffset) }
        let end = Int(offset) + input.count
        if end > fileBytes.count {
            fileBytes.append(contentsOf: repeatElement(0, count: end - fileBytes.count))
        }
        var index = 0
        while index < input.count {
            fileBytes[Int(offset) + index] = input[index]
            index += 1
        }
        return .transferred(byteCount: input.count)
    }

    private func makeMetadata(
        local: UInt64,
        kind: VFSNodeKind,
        byteCount: UInt64 = 0
    ) -> VFSNodeMetadata {
        makeTestMetadata(
            volume: volumeIdentifier,
            local: local,
            kind: kind,
            byteCount: byteCount
        )
    }
}

private extension VFSMetadataResult {
    var asLookupResult: VFSLookupResult {
        switch self {
        case .metadata(let value): return .node(value)
        case .failure(let failure): return .failure(failure)
        }
    }
}

private final class BridgeMemoryBlockDevice: BlockDevice {
    let geometry: BlockDeviceGeometry
    var bytes: [UInt8]

    init(blockCount: UInt64) {
        geometry = BlockDeviceGeometry(
            logicalBlockByteCount: 512,
            logicalBlockCount: blockCount
        )!
        bytes = [UInt8](repeating: 0, count: Int(blockCount) * 512)
    }

    func readBlock(
        at logicalBlock: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard logicalBlock < geometry.logicalBlockCount else { return .invalidBlock }
        guard output.count >= 512, let destination = output.baseAddress else {
            return .invalidBuffer
        }
        bytes.withUnsafeBytes { source in
            destination.copyMemory(
                from: source.baseAddress!.advanced(by: Int(logicalBlock) * 512),
                byteCount: 512
            )
        }
        return .success
    }

    func writeBlock(
        at logicalBlock: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> BlockDeviceIOResult {
        guard logicalBlock < geometry.logicalBlockCount else { return .invalidBlock }
        guard input.count >= 512, let source = input.baseAddress else {
            return .invalidBuffer
        }
        bytes.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: Int(logicalBlock) * 512)
                .copyMemory(from: source, byteCount: 512)
        }
        return .success
    }

    func synchronize() -> BlockDeviceIOResult { .success }
}

@main
struct BorrowedMountedProviderBackendTests {
    private typealias Backend = BorrowedMountedProviderBackend<BridgeTestProvider>

    static func main() {
        validatesBorrowedBindingAndNamespaceRouting()
        traversesCanonicalPathsWithinTheBound()
        rejectsProviderAndHandleCrossing()
        forwardsInPlaceProviderOperations()
        bridgesARealSwiftFSPersistentProvider()
        print("borrowed mounted provider backend host tests: 5 groups passed")
    }

    private static func validatesBorrowedBindingAndNamespaceRouting() {
        withHarness(includeSystemMount: true) { backend, provider, namespace in
            withCanonical("/") { path in
                guard case .syntheticDirectory = backend.resolve(path: path) else {
                    fail("synthetic root did not resolve")
                }
            }
            withCanonical("/Volumes") { path in
                guard case .syntheticDirectory = backend.resolve(path: path) else {
                    fail("synthetic Volumes did not resolve")
                }
            }
            withCanonical("/Temporary/cache") { path in
                guard case .notMounted = backend.resolve(path: path) else {
                    fail("unmounted path reached provider")
                }
            }
            withCanonical("/System/Kernel") { path in
                guard case .notMounted = backend.resolve(path: path) else {
                    fail("different mounted provider was crossed")
                }
            }
            withCanonical("/Users") { path in
                let value = requireResolvedNode(&backend, path: path)
                expect(value.metadata.identifier.localValue == 1, "mount root node")
                expect(value.mount.mountIdentifier == mountID(1), "mount identity")
            }

            let handleSlots = UnsafeMutablePointer<VFSHandleSlot>.allocate(capacity: 1)
            defer {
                handleSlots.deinitialize(count: 1)
                handleSlots.deallocate()
            }
            var handles = VFSHandleTable(
                uninitializedSlots: handleSlots,
                slotCount: 1
            )!
            expect(
                namespace.pointee.unmount(
                    mountIdentifier: mountID(1),
                    revoking: &handles
                ) == .unmounted(
                    VFSUnmountedMount(
                        mount: userMount,
                        revokedHandleCount: 0
                    )
                ),
                "test mount did not detach"
            )
            withCanonical("/Users/alice") { path in
                guard case .notMounted = backend.resolve(path: path) else {
                    fail("borrowed backend retained a copied namespace")
                }
            }
            expect(provider.pointee.lookupCallCount == 0,
                   "namespace-only routes called provider lookup")
        }

        let providerPointer = UnsafeMutablePointer<BridgeTestProvider>.allocate(capacity: 1)
        providerPointer.initialize(to: BridgeTestProvider())
        defer {
            providerPointer.deinitialize(count: 1)
            providerPointer.deallocate()
        }
        let wrongRoot = VFSNodeIdentifier(
            volume: VFSVolumeIdentifier(rawValue: 99)!,
            localValue: 1
        )!
        if case .some = Backend(
            borrowing: nil,
            provider: providerPointer,
            mountIdentifier: mountID(1),
            rootNode: rootNode
        ) { fail("nil namespace binding succeeded") }
        if case .some = Backend(
            borrowing: UnsafeMutablePointer<VFSMountNamespace>(bitPattern: 1),
            provider: providerPointer,
            mountIdentifier: mountID(1),
            rootNode: rootNode
        ) { fail("misaligned namespace binding succeeded") }
        if case .some = Backend(
            borrowing: UnsafeMutablePointer<VFSMountNamespace>(bitPattern: 8),
            provider: UnsafeMutablePointer<BridgeTestProvider>(bitPattern: 1),
            mountIdentifier: mountID(1),
            rootNode: rootNode
        ) { fail("misaligned provider binding succeeded") }
        withNamespacePointer { namespace in
            if case .some = Backend(
                borrowing: namespace,
                provider: providerPointer,
                mountIdentifier: mountID(1),
                rootNode: wrongRoot
            ) { fail("provider/root volume mismatch succeeded") }
        }
    }

    private static func traversesCanonicalPathsWithinTheBound() {
        withHarness { backend, provider, _ in
            withCanonical("/Users/alice/note") { path in
                let resolved = requireResolvedNode(&backend, path: path)
                expect(resolved.metadata.identifier.localValue == 3, "nested file node")
                expect(resolved.metadata.kind == .regularFile, "nested file kind")
            }
            withCanonical("/Users/missing") { path in
                guard case .failure(.notFound) = backend.resolve(path: path) else {
                    fail("missing child resolved")
                }
            }
            withCanonical("/Users/alice/note/child") { path in
                guard case .failure(.notDirectory) = backend.resolve(path: path) else {
                    fail("regular file was traversed")
                }
            }
            withCanonical("/Users/link") { path in
                let resolved = requireResolvedNode(&backend, path: path)
                expect(resolved.metadata.kind == .symbolicLink, "final link metadata")
            }
            withCanonical("/Users/link/child") { path in
                guard case .failure(.notDirectory) = backend.resolve(path: path) else {
                    fail("symbolic link was followed")
                }
            }

            var maximumPath = "/Users"
            var component = 0
            while component < VFSPathLimits.maximumComponentCount - 1 {
                maximumPath += "/loop"
                component += 1
            }
            let before = provider.pointee.lookupCallCount
            withCanonical(maximumPath) { path in
                let resolved = requireResolvedNode(&backend, path: path)
                expect(resolved.metadata.identifier.localValue == 5, "bounded loop node")
            }
            expect(
                provider.pointee.lookupCallCount - before
                    == VFSPathLimits.maximumComponentCount - 1,
                "maximum canonical traversal count"
            )
        }
    }

    private static func rejectsProviderAndHandleCrossing() {
        withHarness { backend, provider, _ in
            provider.pointee.returnForeignLookup = true
            withCanonical("/Users/alice") { path in
                guard case .failure(.corrupt) = backend.resolve(path: path) else {
                    fail("foreign-volume lookup crossed provider")
                }
            }
            provider.pointee.returnForeignLookup = false

            let foreignHandle = VFSOpenHandle(
                node: VFSNodeIdentifier(
                    volume: VFSVolumeIdentifier(rawValue: 99)!,
                    localValue: 3
                )!,
                mountIdentifier: mountID(1),
                access: .readData
            )
            var output = [UInt8](repeating: 0, count: 8)
            output.withUnsafeMutableBytes {
                expect(
                    backend.read(from: foreignHandle, at: 0, into: $0)
                        == .failure(.corrupt),
                    "foreign-volume handle reached provider"
                )
            }
            let wrongMount = VFSOpenHandle(
                node: fileNode,
                mountIdentifier: mountID(2),
                access: .readData
            )
            output.withUnsafeMutableBytes {
                expect(
                    backend.read(from: wrongMount, at: 0, into: $0)
                        == .failure(.unavailable),
                    "wrong-mount handle reached provider"
                )
            }
            expect(provider.pointee.readCallCount == 0, "rejected handles called read")

            provider.pointee.returnForeignDirectoryEntry = true
            var name = [UInt8](repeating: 0, count: 32)
            name.withUnsafeMutableBytes {
                guard case .failure(.corrupt) = backend.readDirectory(
                    from: directoryHandle,
                    after: .start,
                    nameOutput: $0
                ) else { fail("foreign directory entry crossed provider") }
            }
            provider.pointee.volumeIdentifier = VFSVolumeIdentifier(rawValue: 42)!
            withCanonical("/Users") { path in
                guard case .failure(.unavailable) = backend.resolve(path: path) else {
                    fail("replaced provider identity was accepted")
                }
            }
        }
    }

    private static func forwardsInPlaceProviderOperations() {
        withHarness { backend, provider, _ in
            provider.pointee.fileBytes = Array("external".utf8)
            withCanonical("/Users/alice/note") { path in
                let resolved = requireResolvedNode(&backend, path: path)
                expect(resolved.metadata.byteCount == 8, "external mutation invisible")
            }

            var output = [UInt8](repeating: 0, count: 16)
            let transferred = output.withUnsafeMutableBytes { bytes -> Int in
                guard case .transferred(let count) = backend.read(
                    from: fileHandle,
                    at: 0,
                    into: bytes
                ) else { fail("backend read failed") }
                return count
            }
            expect(Array(output.prefix(transferred)) == Array("external".utf8),
                   "backend read bytes")

            let replacement = Array("FS".utf8)
            replacement.withUnsafeBytes {
                expect(
                    backend.write(to: fileHandle, at: 2, from: $0)
                        == .transferred(byteCount: 2),
                    "backend write failed"
                )
            }
            expect(provider.pointee.fileBytes == Array("exFSrnal".utf8),
                   "backend copied provider state")
            guard case .metadata(let metadata) = backend.metadata(for: fileHandle)
            else { fail("backend metadata failed") }
            expect(metadata.byteCount == 8, "forwarded metadata size")

            var name = [UInt8](repeating: 0, count: 32)
            name.withUnsafeMutableBytes {
                guard case .entry(let entry, let next) = backend.readDirectory(
                    from: directoryHandle,
                    after: .start,
                    nameOutput: $0
                ) else { fail("backend directory read failed") }
                expectName(entry.name, "note")
                expect(next.rawValue == 1, "directory cookie")
            }
            expect(provider.pointee.readCallCount == 1, "read forwarding count")
            expect(provider.pointee.writeCallCount == 1, "write forwarding count")
            expect(provider.pointee.directoryCallCount == 1, "directory forwarding count")

            provider.pointee.returnWrongMetadata = true
            guard case .failure(.corrupt) = backend.metadata(for: fileHandle) else {
                fail("mismatched provider metadata escaped")
            }
        }
    }

    private static func bridgesARealSwiftFSPersistentProvider() {
        typealias PersistentProvider = SwiftFSPersistentProvider<BridgeMemoryBlockDevice>
        typealias PersistentBackend = BorrowedMountedProviderBackend<PersistentProvider>
        let device = BridgeMemoryBlockDevice(blockCount: 96)
        let providerScratch = UnsafeMutableRawPointer.allocate(
            byteCount: 1_024,
            alignment: 8
        )
        defer { providerScratch.deallocate() }
        let scratch = UnsafeMutableRawBufferPointer(
            start: providerScratch,
            count: 1_024
        )
        var formattedDevice = device
        guard case .formatted = PersistentProvider.format(
            &formattedDevice,
            volumeIdentifier: VFSVolumeIdentifier(rawValue: 51)!,
            nodeCapacity: 8,
            scratch: scratch
        ) else { fail("SwiftFS bridge fixture format") }
        var provider: PersistentProvider
        switch PersistentProvider.mount(
            device,
            expectedVolumeIdentifier: VFSVolumeIdentifier(rawValue: 51)!,
            scratch: scratch
        ) {
        case .mounted(let mounted): provider = mounted
        case .failure: fail("SwiftFS bridge fixture mount")
        }

        withNamespace(
            volumeIdentifier: VFSVolumeIdentifier(rawValue: 51)!
        ) { namespace in
            withUnsafeMutablePointer(to: &namespace) { namespacePointer in
                withUnsafeMutablePointer(to: &provider) { providerPointer in
                    var backend = PersistentBackend(
                        borrowing: namespacePointer,
                        provider: providerPointer,
                        mountIdentifier: mountID(1),
                        rootNode: providerPointer.pointee.rootNodeIdentifier
                    )!
                    let alice = createSwiftFSNode(
                        &providerPointer.pointee,
                        parent: providerPointer.pointee.rootNodeIdentifier,
                        name: "alice",
                        kind: .directory
                    )
                    let note = createSwiftFSNode(
                        &providerPointer.pointee,
                        parent: alice,
                        name: "note",
                        kind: .regularFile
                    )
                    withCanonical("/Users/alice/note") { path in
                        let resolved = requireResolvedNode(&backend, path: path)
                        expect(resolved.metadata.identifier == note,
                               "SwiftFS nested resolution")
                    }
                    let handle = VFSOpenHandle(
                        node: note,
                        mountIdentifier: mountID(1),
                        access: .readData.union(.writeData).union(.readMetadata)
                    )
                    let payload = Array("persistent bridge".utf8)
                    payload.withUnsafeBytes {
                        expect(
                            backend.write(to: handle, at: 0, from: $0)
                                == .transferred(byteCount: payload.count),
                            "SwiftFS backend write"
                        )
                    }
                    var output = [UInt8](repeating: 0, count: 32)
                    let count = output.withUnsafeMutableBytes { bytes -> Int in
                        guard case .transferred(let count) = backend.read(
                            from: handle,
                            at: 0,
                            into: bytes
                        ) else { fail("SwiftFS backend read") }
                        return count
                    }
                    expect(Array(output.prefix(count)) == payload,
                           "SwiftFS bridge round trip")
                }
            }
        }
    }

    private static func withHarness(
        includeSystemMount: Bool = false,
        _ body: (
            inout Backend,
            UnsafeMutablePointer<BridgeTestProvider>,
            UnsafeMutablePointer<VFSMountNamespace>
        ) -> Void
    ) {
        withNamespacePointer(includeSystemMount: includeSystemMount) { namespace in
            let provider = UnsafeMutablePointer<BridgeTestProvider>.allocate(capacity: 1)
            provider.initialize(to: BridgeTestProvider())
            defer {
                provider.deinitialize(count: 1)
                provider.deallocate()
            }
            var backend = Backend(
                borrowing: namespace,
                provider: provider,
                mountIdentifier: mountID(1),
                rootNode: rootNode
            )!
            body(&backend, provider, namespace)
        }
    }

    private static func withNamespacePointer(
        includeSystemMount: Bool = false,
        _ body: (UnsafeMutablePointer<VFSMountNamespace>) -> Void
    ) {
        withNamespace { namespace in
            if includeSystemMount { mountSystemVolume(&namespace) }
            withUnsafeMutablePointer(to: &namespace) { body($0) }
        }
    }

    private static func withNamespace(
        volumeIdentifier: VFSVolumeIdentifier = VFSVolumeIdentifier(rawValue: 41)!,
        _ body: (inout VFSMountNamespace) -> Void
    ) {
        let slots = UnsafeMutablePointer<VFSMountSlot>.allocate(capacity: 4)
        let pathStorage = UnsafeMutableRawPointer.allocate(
            byteCount: 4 * VFSPathLimits.maximumPathByteCount,
            alignment: 8
        )
        defer {
            slots.deinitialize(count: 4)
            slots.deallocate()
            pathStorage.deallocate()
        }
        var namespace = VFSMountNamespace(
            uninitializedSlots: slots,
            slotCount: 4,
            pathStorage: UnsafeMutableRawBufferPointer(
                start: pathStorage,
                count: 4 * VFSPathLimits.maximumPathByteCount
            ),
            maximumPathByteCountPerMount: VFSPathLimits.maximumPathByteCount
        )!
        withCanonical("/Users") { path in
            expect(
                namespace.mount(
                    VFSVolumeDescriptor(
                        identifier: volumeIdentifier,
                        role: .user,
                        visibility: .namespace
                    ),
                    at: path,
                    mountIdentifier: mountID(1),
                    userAccess: .all
                ) == .mounted,
                "custom user mount"
            )
        }
        body(&namespace)
    }

    private static func mountUserVolume(_ namespace: inout VFSMountNamespace) {
        withCanonical("/Users") { path in
            expect(
                namespace.mount(
                    userMount.volume,
                    at: path,
                    mountIdentifier: userMount.mountIdentifier,
                    userAccess: userMount.userAccess
                ) == .mounted,
                "user mount"
            )
        }
    }

    private static func mountSystemVolume(_ namespace: inout VFSMountNamespace) {
        withCanonical("/System") { path in
            expect(
                namespace.mount(
                    VFSVolumeDescriptor(
                        identifier: VFSVolumeIdentifier(rawValue: 42)!,
                        role: .system,
                        visibility: .namespace
                    ),
                    at: path,
                    mountIdentifier: mountID(2),
                    userAccess: .readData.union(.traverse).union(.readMetadata)
                ) == .mounted,
                "system mount"
            )
        }
    }

    private static func createSwiftFSNode<Device: BlockDevice>(
        _ provider: inout SwiftFSPersistentProvider<Device>,
        parent: VFSNodeIdentifier,
        name: String,
        kind: VFSNodeKind
    ) -> VFSNodeIdentifier {
        withName(name) { view in
            guard case .created(let metadata) = provider.create(
                parent: parent,
                name: view,
                kind: kind,
                timestamp: VFSTimestamp(secondsSinceUnixEpoch: 1, nanoseconds: 0)!
            ) else { fail("SwiftFS bridge fixture create") }
            return metadata.identifier
        }
    }

    private static func requireResolvedNode<B: VFSFileServiceBackend>(
        _ backend: inout B,
        path: VFSCanonicalPath
    ) -> (mount: VFSMountDescriptor, metadata: VFSNodeMetadata) {
        guard case .node(let mount, let metadata) = backend.resolve(path: path) else {
            fail("expected resolved node")
        }
        return (mount, metadata)
    }

    private static func withCanonical(
        _ string: String,
        _ body: (VFSCanonicalPath) -> Void
    ) {
        let input = Array(string.utf8)
        var output = [UInt8](repeating: 0, count: VFSPathLimits.maximumPathByteCount)
        input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard case .path(let path) = VFSPathNormalizer.normalize(
                    source,
                    into: destination
                ) else { fail("invalid test canonical path") }
                body(path)
            }
        }
    }

    private static func withName<T>(
        _ string: String,
        _ body: (VFSNameView) -> T
    ) -> T {
        let bytes = Array(string.utf8)
        return bytes.withUnsafeBytes {
            guard case .name(let name) = VFSNameValidator.validate($0) else {
                fail("invalid test name")
            }
            return body(name)
        }
    }

    private static func expectName(_ name: VFSNameView, _ expected: StaticString) {
        expected.withUTF8Buffer { bytes in
            expect(name.byteCount == bytes.count, "entry name size")
            var index = 0
            while index < bytes.count {
                expect(name.byte(at: index) == bytes[index], "entry name byte")
                index += 1
            }
        }
    }

    private static var userMount: VFSMountDescriptor {
        VFSMountDescriptor(
            mountIdentifier: mountID(1),
            volume: VFSVolumeDescriptor(
                identifier: VFSVolumeIdentifier(rawValue: 41)!,
                role: .user,
                visibility: .namespace
            ),
            userAccess: .all,
            requiredCapability: nil
        )
    }

    private static var rootNode: VFSNodeIdentifier {
        VFSNodeIdentifier(
            volume: VFSVolumeIdentifier(rawValue: 41)!,
            localValue: 1
        )!
    }

    private static var fileNode: VFSNodeIdentifier {
        VFSNodeIdentifier(
            volume: VFSVolumeIdentifier(rawValue: 41)!,
            localValue: 3
        )!
    }

    private static var fileHandle: VFSOpenHandle {
        VFSOpenHandle(
            node: fileNode,
            mountIdentifier: mountID(1),
            access: .readData.union(.writeData).union(.readMetadata)
        )
    }

    private static var directoryHandle: VFSOpenHandle {
        VFSOpenHandle(
            node: VFSNodeIdentifier(
                volume: VFSVolumeIdentifier(rawValue: 41)!,
                localValue: 2
            )!,
            mountIdentifier: mountID(1),
            access: .enumerate.union(.readMetadata)
        )
    }

    private static func mountID(_ value: UInt32) -> VFSMountIdentifier {
        VFSMountIdentifier(rawValue: value)!
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

private func nameEquals(_ name: VFSNameView, _ expected: StaticString) -> Bool {
    expected.withUTF8Buffer { bytes in
        guard name.byteCount == bytes.count else { return false }
        var index = 0
        while index < bytes.count {
            if name.byte(at: index) != bytes[index] { return false }
            index += 1
        }
        return true
    }
}

private func makeTestMetadata(
    volume: VFSVolumeIdentifier,
    local: UInt64,
    kind: VFSNodeKind,
    byteCount: UInt64 = 0
) -> VFSNodeMetadata {
    let access: VFSAccessRights
    switch kind {
    case .regularFile:
        access = .readData.union(.writeData).union(.readMetadata).union(.writeMetadata)
    case .directory:
        access = .enumerate.union(.traverse).union(.create).union(.remove)
            .union(.readMetadata).union(.writeMetadata)
    case .symbolicLink:
        access = .readMetadata.union(.writeMetadata)
    case .device:
        access = .readData.union(.writeData).union(.readMetadata)
    }
    let timestamp = VFSTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)!
    return VFSNodeMetadata(
        identifier: VFSNodeIdentifier(volume: volume, localValue: local)!,
        kind: kind,
        byteCount: byteCount,
        linkCount: 1,
        generation: 1,
        createdAt: timestamp,
        modifiedAt: timestamp,
        availableAccess: access
    )!
}
