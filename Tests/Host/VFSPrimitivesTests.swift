@main
struct VFSPrimitivesTests {
    static func main() {
        normalizesBoundedAbsolutePaths()
        rejectsTraversalMalformedUTF8AndOverflow()
        validatesStableNamesAndMetadata()
        enforcesTheRootNamespaceLayout()
        resolvesOnlyAtComponentBoundaries()
        appliesRoleMountNodeAndCapabilityPolicy()
        invalidatesStaleGenerationHandles()
        detachesProvidersOnlyAfterHandleRevocation()
        poisonsExhaustedHandleGenerations()
        print("VFS primitives host tests: 9 groups passed")
    }

    private static func normalizesBoundedAbsolutePaths() {
        withCanonical("///Users//alice///Notes/") { path in
            expectPath(path, equals: "/Users/alice/Notes")
            expect(path.componentCount == 3, "component count changed")
            expectName(path.component(at: 0), equals: "Users")
            expectName(path.component(at: 1), equals: "alice")
            expectName(path.component(at: 2), equals: "Notes")
            expect(path.component(at: 3) == nil, "out-of-range component exists")
        }
        withCanonical("////") { path in
            expect(path.isRoot, "separator-only path was not root")
            expectPath(path, equals: "/")
        }
        withCanonicalBytes([0x2f, 0xc3, 0xa9]) { path in
            expect(path.componentCount == 1, "UTF-8 component disappeared")
            guard let name = path.component(at: 0) else {
                fail("missing UTF-8 component")
            }
            expect(name.byteCount == 2, "UTF-8 byte count changed")
            expect(name.byte(at: 0) == 0xc3, "UTF-8 byte zero changed")
            expect(name.byte(at: 1) == 0xa9, "UTF-8 byte one changed")
        }
    }

    private static func rejectsTraversalMalformedUTF8AndOverflow() {
        expectPathFailure("Users/alice", .notAbsolute)
        expectPathFailure("/Users/../System", .traversalComponent(componentIndex: 1))
        expectPathFailure("/./System", .traversalComponent(componentIndex: 0))
        expectPathFailureBytes(
            [0x2f, 0x61, 0, 0x62],
            .nulByte(offset: 2)
        )
        expectPathFailureBytes(
            [0x2f, 0x61, 0x1f, 0x62],
            .controlByte(offset: 2)
        )
        expectPathFailureBytes(
            [0x2f, 0xf0, 0x80, 0x80, 0x80],
            .invalidUTF8(offset: 1)
        )

        var longComponent = [UInt8](repeating: 0x61, count: 257)
        longComponent[0] = 0x2f
        expectPathFailureBytes(
            longComponent,
            .componentTooLong(componentIndex: 0)
        )

        var tooMany = [UInt8](repeating: 0x2f, count: 1)
        var index = 0
        while index < 65 {
            tooMany.append(0x61)
            tooMany.append(0x2f)
            index += 1
        }
        expectPathFailureBytes(tooMany, .tooManyComponents)
        expectPathFailureBytes(
            [UInt8](repeating: 0x2f, count: 1_025),
            .inputTooLong
        )

        withRawBytes("/abcdef") { input in
            var output = [UInt8](repeating: 0, count: 3)
            output.withUnsafeMutableBytes { destination in
                guard case .failure(.outputTooSmall(requiredByteCount: 7)) =
                    VFSPathNormalizer.normalize(input, into: destination)
                else { fail("small path output was accepted") }
            }
        }
        withRawBytes("bad/name") { name in
            guard case .failure(.separatorInName(offset: 3)) =
                VFSNameValidator.validate(name)
            else { fail("separator in a name was accepted") }
        }
    }

    private static func validatesStableNamesAndMetadata() {
        expect(VFSVolumeIdentifier(rawValue: 0) == nil, "zero volume ID accepted")
        expect(VFSVolumeRole.system.isPersistent, "System role became ephemeral")
        expect(VFSVolumeRole.user.isPersistent, "Users role became ephemeral")
        expect(!VFSVolumeRole.temporary.isPersistent, "Temporary became persistent")
        let volume = VFSVolumeIdentifier(rawValue: 1)!
        expect(
            VFSNodeIdentifier(volume: volume, localValue: 0) == nil,
            "zero node ID accepted"
        )
        expect(
            VFSTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 1_000_000_000) == nil,
            "invalid timestamp accepted"
        )
        let timestamp = VFSTimestamp(
            secondsSinceUnixEpoch: 1_700_000_000,
            nanoseconds: 123
        )!
        let node = VFSNodeIdentifier(volume: volume, localValue: 42)!
        expect(
            VFSNodeMetadata(
                identifier: node,
                kind: .regularFile,
                byteCount: 99,
                linkCount: 1,
                generation: 7,
                createdAt: timestamp,
                modifiedAt: timestamp,
                availableAccess: .enumerate
            ) == nil,
            "directory rights were attached to a regular file"
        )
        let metadata = VFSNodeMetadata(
            identifier: node,
            kind: .regularFile,
            byteCount: 99,
            linkCount: 1,
            generation: 7,
            createdAt: timestamp,
            modifiedAt: timestamp,
            availableAccess: .readData.union(.readMetadata)
        )!
        expect(metadata.byteCount == 99, "metadata byte count changed")
        expect(metadata.generation == 7, "metadata generation changed")

        withValidatedName("Report.swift") { name in
            let entry = VFSDirectoryEntry(
                identifier: node,
                kind: .regularFile,
                name: name
            )
            expectName(entry.name, equals: "Report.swift")
            let cookie = VFSDirectoryCookie(rawValue: 18)
            let result = VFSDirectoryReadResult.entry(entry, nextCookie: cookie)
            guard case .entry(let decoded, let next) = result else {
                fail("directory entry contract changed")
            }
            expect(decoded.identifier == node, "directory node ID changed")
            expect(next.rawValue == 18, "directory cookie changed")
        }
    }

    private static func enforcesTheRootNamespaceLayout() {
        withNamespace(slotCount: 8) { namespace in
            expectSynthetic(namespace, path: "/", expected: .root)
            expectSynthetic(namespace, path: "/Volumes", expected: .volumes)

            let system = volume(1, role: .system)
            expectMount(
                &namespace,
                system,
                path: "/System",
                mountID: 1,
                access: .readData.union(.traverse).union(.readMetadata)
            )
            expectMount(
                &namespace,
                volume(2, role: .user),
                path: "/Users",
                mountID: 2,
                access: .all
            )
            expectMount(
                &namespace,
                volume(3, role: .user),
                path: "/Volumes/Media",
                mountID: 3,
                access: .readData.union(.writeData).union(.readMetadata)
            )
            expectMount(
                &namespace,
                volume(4, role: .temporary),
                path: "/Temporary",
                mountID: 4,
                access: .all
            )

            expectMountFailure(
                &namespace,
                volume(5, role: .device),
                path: "/Devices",
                mountID: 5,
                access: .readData,
                capability: nil,
                expected: .deviceCapabilityRequired
            )
            expectMount(
                &namespace,
                volume(5, role: .device),
                path: "/Devices",
                mountID: 5,
                access: .readData.union(.writeData).union(.readMetadata),
                capability: VFSCapabilityIdentifier(rawValue: 55)
            )

            expectMountFailure(
                &namespace,
                volume(6, role: .system),
                path: "/Users/System",
                mountID: 6,
                access: .readData,
                expected: .rolePathMismatch
            )
            expectMountFailure(
                &namespace,
                volume(7, role: .user),
                path: "/Volumes",
                mountID: 7,
                access: .readData,
                expected: .rolePathMismatch
            )
            expectMountFailure(
                &namespace,
                volume(8, role: .system),
                path: "/System",
                mountID: 8,
                access: .writeData,
                expected: .accessExceedsRole
            )
            expectMountFailure(
                &namespace,
                volume(11, role: .user),
                path: "/Users",
                mountID: 11,
                access: .readData,
                expected: .duplicatePath
            )
            expectMountFailure(
                &namespace,
                volume(12, role: .user),
                path: "/Volumes/Backup",
                mountID: 2,
                access: .readData,
                expected: .duplicateMountIdentifier
            )
            expectMountFailure(
                &namespace,
                volume(2, role: .user),
                path: "/Volumes/Backup",
                mountID: 12,
                access: .readData,
                expected: .duplicateVolumeIdentifier
            )

            let kernelLog = VFSVolumeDescriptor(
                identifier: VFSVolumeIdentifier(rawValue: 9)!,
                role: .user,
                visibility: .kernelOnly
            )
            expectMountFailure(
                &namespace,
                kernelLog,
                path: "/Volumes/KernelLog",
                mountID: 9,
                access: .readData,
                expected: .kernelOnlyVolume
            )
            let rawMedia = VFSVolumeDescriptor(
                identifier: VFSVolumeIdentifier(rawValue: 10)!,
                role: .device,
                visibility: .kernelOnly
            )
            expectMountFailure(
                &namespace,
                rawMedia,
                path: "/Devices",
                mountID: 10,
                access: .readData,
                capability: VFSCapabilityIdentifier(rawValue: 99),
                expected: .kernelOnlyVolume
            )
            expect(namespace.mountedCount == 5, "rejected mounts consumed slots")
        }
        withNamespace(slotCount: 1) { namespace in
            expectMount(
                &namespace,
                volume(100, role: .system),
                path: "/System",
                mountID: 100,
                access: .readData
            )
            expectMountFailure(
                &namespace,
                volume(101, role: .user),
                path: "/Users",
                mountID: 101,
                access: .readData,
                expected: .tableFull
            )
        }
    }

    private static func resolvesOnlyAtComponentBoundaries() {
        withNamespace(slotCount: 3) { namespace in
            expectMount(
                &namespace,
                volume(20, role: .user),
                path: "/Users",
                mountID: 20,
                access: .all
            )
            expectMount(
                &namespace,
                volume(21, role: .user),
                path: "/Volumes/Media",
                mountID: 21,
                access: .all
            )

            withCanonical("/Users/alice/Documents") { path in
                guard case .mount(let resolution) = namespace.resolve(path) else {
                    fail("user path did not resolve")
                }
                expect(
                    resolution.mount.mountIdentifier.rawValue == 20,
                    "user path resolved to wrong mount"
                )
                expect(resolution.relativePath.componentCount == 2, "relative count")
                expectName(
                    resolution.relativePath.component(at: 0),
                    equals: "alice"
                )
                expectName(
                    resolution.relativePath.component(at: 1),
                    equals: "Documents"
                )
            }
            expectUnmounted(namespace, path: "/Users-old/private")
            expectUnmounted(namespace, path: "/DevicesX")
            withCanonical("/Volumes/Media/photos") { path in
                guard case .mount(let resolution) = namespace.resolve(path) else {
                    fail("external volume path did not resolve")
                }
                expect(
                    resolution.mount.mountIdentifier.rawValue == 21,
                    "external path resolved to wrong mount"
                )
                expectName(
                    resolution.relativePath.component(at: 0),
                    equals: "photos"
                )
            }
            expectSynthetic(namespace, path: "/Volumes", expected: .volumes)
        }
    }

    private static func appliesRoleMountNodeAndCapabilityPolicy() {
        withNamespace(slotCount: 3) { namespace in
            expectMount(
                &namespace,
                volume(30, role: .system),
                path: "/System",
                mountID: 30,
                access: .readData.union(.readMetadata).union(.execute)
            )
            expectMount(
                &namespace,
                volume(31, role: .user),
                path: "/Users",
                mountID: 31,
                access: .readData.union(.readMetadata)
            )
            expectMount(
                &namespace,
                volume(32, role: .device),
                path: "/Devices",
                mountID: 32,
                access: .readData.union(.writeData).union(.readMetadata),
                capability: VFSCapabilityIdentifier(rawValue: 320)
            )
            let systemMount = resolvedMount(namespace, path: "/System/Kernel")
            let userMount = resolvedMount(namespace, path: "/Users/alice")
            let deviceMount = resolvedMount(namespace, path: "/Devices/Keyboard")
            let systemNode = metadata(
                volume: 30,
                local: 1,
                kind: .regularFile,
                access: .readData.union(.writeData).union(.readMetadata).union(.execute)
            )
            let userNode = metadata(
                volume: 31,
                local: 2,
                kind: .regularFile,
                access: .readData.union(.writeData).union(.readMetadata)
            )
            let deviceNode = metadata(
                volume: 32,
                local: 3,
                kind: .device,
                access: .readData.union(.writeData).union(.readMetadata)
            )

            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(taskIdentifier: 1, deviceCapability: nil),
                    mount: systemMount,
                    metadata: systemNode,
                    requested: .writeData
                ) == .denied(.deniedByRole),
                "immutable System volume allowed a write"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(taskIdentifier: 1, deviceCapability: nil),
                    mount: userMount,
                    metadata: userNode,
                    requested: .writeData
                ) == .denied(.deniedByMount),
                "read-only user mount allowed a write"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(taskIdentifier: 1, deviceCapability: nil),
                    mount: userMount,
                    metadata: userNode,
                    requested: .readData
                ) == .granted,
                "readable user node was denied"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(taskIdentifier: 0, deviceCapability: nil),
                    mount: userMount,
                    metadata: userNode,
                    requested: .readData
                ) == .denied(.invalidPrincipal),
                "zero task principal was accepted"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(taskIdentifier: 1, deviceCapability: nil),
                    mount: deviceMount,
                    metadata: deviceNode,
                    requested: .readData
                ) == .denied(.missingDeviceCapability),
                "device opened without a capability"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(
                        taskIdentifier: 1,
                        deviceCapability: VFSCapabilityIdentifier(rawValue: 999)
                    ),
                    mount: deviceMount,
                    metadata: deviceNode,
                    requested: .readData
                ) == .denied(.missingDeviceCapability),
                "wrong device capability was accepted"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(
                        taskIdentifier: 1,
                        deviceCapability: VFSCapabilityIdentifier(rawValue: 320)
                    ),
                    mount: deviceMount,
                    metadata: deviceNode,
                    requested: .readData
                ) == .granted,
                "matching device capability was denied"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .kernel,
                    mount: deviceMount,
                    metadata: deviceNode,
                    requested: .writeData
                ) == .granted,
                "kernel-mediated device access was denied"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .kernel,
                    mount: userMount,
                    metadata: systemNode,
                    requested: .readData
                ) == .denied(.volumeMismatch),
                "cross-volume node was accepted"
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .kernel,
                    mount: userMount,
                    metadata: userNode,
                    requested: .none
                ) == .denied(.emptyRequest),
                "empty access request was accepted"
            )
            let misplacedDevice = metadata(
                volume: 31,
                local: 4,
                kind: .device,
                access: .readData
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .kernel,
                    mount: userMount,
                    metadata: misplacedDevice,
                    requested: .readData
                ) == .denied(.nodeRoleMismatch),
                "device node escaped the Devices role"
            )
            let malformedDeviceMount = VFSMountDescriptor(
                mountIdentifier: VFSMountIdentifier(rawValue: 320)!,
                volume: volume(32, role: .device),
                userAccess: .readData,
                requiredCapability: nil
            )
            expect(
                VFSAccessPolicy.authorize(
                    principal: .user(taskIdentifier: 1, deviceCapability: nil),
                    mount: malformedDeviceMount,
                    metadata: deviceNode,
                    requested: .readData
                ) == .denied(.missingDeviceCapability),
                "malformed device mount bypassed capability policy"
            )
        }
    }

    private static func invalidatesStaleGenerationHandles() {
        withNamespace(slotCount: 1) { namespace in
            expectMount(
                &namespace,
                volume(40, role: .user),
                path: "/Users",
                mountID: 40,
                access: .readData.union(.readMetadata)
            )
            let mount = resolvedMount(namespace, path: "/Users/alice")
            let node = metadata(
                volume: 40,
                local: 8,
                kind: .regularFile,
                access: .readData.union(.readMetadata)
            )
            withHandleTable(slotCount: 2) { table in
                let first = openedHandle(
                    &table,
                    metadata: node,
                    mount: mount,
                    access: .readData
                )
                let second = openedHandle(
                    &table,
                    metadata: node,
                    mount: mount,
                    access: .readMetadata
                )
                expect(table.openCount == 2, "open count changed")
                expect(
                    table.open(
                        metadata: node,
                        on: mount,
                        for: .user(taskIdentifier: 1, deviceCapability: nil),
                        requesting: .readData
                    ) == .tableFull,
                    "full handle table accepted another handle"
                )
                guard case .handle(let open) = table.lookup(first) else {
                    fail("fresh handle did not resolve")
                }
                expect(open.node == node.identifier, "handle node changed")
                expect(table.close(first) == .closed, "fresh handle did not close")
                expect(
                    table.lookup(first) == .failure(.staleGeneration),
                    "closed generation remained usable"
                )

                let replacement = openedHandle(
                    &table,
                    metadata: node,
                    mount: mount,
                    access: .readData
                )
                expect(replacement.slot == first.slot, "free slot was not reused")
                expect(
                    replacement.generation != first.generation,
                    "slot reuse did not advance generation"
                )
                expect(
                    table.close(first) == .failure(.staleGeneration),
                    "stale token closed a replacement handle"
                )
                expect(
                    table.revokeAll(for: mount.mountIdentifier) == 2,
                    "mount revocation count changed"
                )
                expect(table.openCount == 0, "revocation left handles open")
                expect(
                    table.lookup(second) == .failure(.staleGeneration),
                    "revoked handle remained usable"
                )
                expect(
                    table.lookup(
                        VFSHandleToken(slot: UInt16.max, generation: 1)
                    ) == .failure(.invalidSlot),
                    "out-of-range handle slot was accepted"
                )
            }
        }
    }

    private static func detachesProvidersOnlyAfterHandleRevocation() {
        withNamespace(slotCount: 2) { namespace in
            expectMount(
                &namespace,
                volume(50, role: .user),
                path: "/Users",
                mountID: 50,
                access: .readData
            )
            expectMount(
                &namespace,
                volume(51, role: .user),
                path: "/Volumes/Media",
                mountID: 51,
                access: .readData
            )
            let usersMount = resolvedMount(namespace, path: "/Users/alice")
            let mediaMount = resolvedMount(namespace, path: "/Volumes/Media/file")
            let usersNode = metadata(
                volume: 50,
                local: 1,
                kind: .regularFile,
                access: .readData
            )
            let mediaNode = metadata(
                volume: 51,
                local: 2,
                kind: .regularFile,
                access: .readData
            )
            withHandleTable(slotCount: 3) { table in
                let usersHandle = openedHandle(
                    &table,
                    metadata: usersNode,
                    mount: usersMount,
                    access: .readData
                )
                let mediaHandle = openedHandle(
                    &table,
                    metadata: mediaNode,
                    mount: mediaMount,
                    access: .readData
                )
                var pathResult: VFSUnmountResult?
                withCanonical("/Volumes/Media") { path in
                    pathResult = namespace.unmount(at: path, revoking: &table)
                }
                guard case .unmounted(let detached)? = pathResult else {
                    fail("exact-path unmount failed")
                }
                expect(
                    detached.mount.mountIdentifier.rawValue == 51,
                    "wrong provider detached"
                )
                expect(detached.revokedHandleCount == 1, "revoke count changed")
                expect(
                    table.lookup(mediaHandle) == .failure(.staleGeneration),
                    "detached provider handle remained live"
                )
                guard case .handle = table.lookup(usersHandle) else {
                    fail("unrelated mount handle was revoked")
                }
                expectUnmounted(namespace, path: "/Volumes/Media/file")

                expect(
                    namespace.unmount(
                        mountIdentifier: VFSMountIdentifier(rawValue: 50)!,
                        revoking: &table
                    ) == .unmounted(
                        VFSUnmountedMount(
                            mount: usersMount,
                            revokedHandleCount: 1
                        )
                    ),
                    "identifier unmount failed"
                )
                expect(
                    table.lookup(usersHandle) == .failure(.staleGeneration),
                    "identifier unmount left handle live"
                )
                expect(
                    namespace.unmount(
                        mountIdentifier: VFSMountIdentifier(rawValue: 50)!,
                        revoking: &table
                    ) == .failure(.notFound),
                    "missing mount detached twice"
                )
                var syntheticResult: VFSUnmountResult?
                withCanonical("/Volumes") { path in
                    syntheticResult = namespace.unmount(at: path, revoking: &table)
                }
                expect(
                    syntheticResult == .failure(.syntheticDirectory),
                    "synthetic directory was detached"
                )
            }
        }
    }

    private static func poisonsExhaustedHandleGenerations() {
        withNamespace(slotCount: 1) { namespace in
            expectMount(
                &namespace,
                volume(60, role: .user),
                path: "/Users",
                mountID: 60,
                access: .readData
            )
            let mount = resolvedMount(namespace, path: "/Users/a")
            let node = metadata(
                volume: 60,
                local: 1,
                kind: .regularFile,
                access: .readData
            )
            withHandleTable(slotCount: 1, initialGeneration: UInt32.max) { table in
                let finalGeneration = openedHandle(
                    &table,
                    metadata: node,
                    mount: mount,
                    access: .readData
                )
                expect(
                    finalGeneration.generation == UInt32.max,
                    "max-generation fixture changed"
                )
                expect(
                    table.close(finalGeneration) == .closed,
                    "max-generation handle did not close"
                )
                expect(
                    table.lookup(finalGeneration) == .failure(.staleGeneration),
                    "max-generation handle revived after close"
                )
                expect(
                    table.open(
                        metadata: node,
                        on: mount,
                        for: .user(taskIdentifier: 1, deviceCapability: nil),
                        requesting: .readData
                    ) == .tableFull,
                    "poisoned generation slot was reused"
                )
            }
        }
    }

    private static func volume(
        _ value: UInt64,
        role: VFSVolumeRole
    ) -> VFSVolumeDescriptor {
        VFSVolumeDescriptor(
            identifier: VFSVolumeIdentifier(rawValue: value)!,
            role: role,
            visibility: .namespace
        )
    }

    private static func metadata(
        volume: UInt64,
        local: UInt64,
        kind: VFSNodeKind,
        access: VFSAccessRights
    ) -> VFSNodeMetadata {
        let volumeID = VFSVolumeIdentifier(rawValue: volume)!
        let timestamp = VFSTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)!
        return VFSNodeMetadata(
            identifier: VFSNodeIdentifier(volume: volumeID, localValue: local)!,
            kind: kind,
            byteCount: 0,
            linkCount: 1,
            generation: 1,
            createdAt: timestamp,
            modifiedAt: timestamp,
            availableAccess: access
        )!
    }

    private static func expectMount(
        _ namespace: inout VFSMountNamespace,
        _ volume: VFSVolumeDescriptor,
        path: StaticString,
        mountID: UInt32,
        access: VFSAccessRights,
        capability: VFSCapabilityIdentifier? = nil
    ) {
        withCanonical(path) { canonical in
            expect(
                namespace.mount(
                    volume,
                    at: canonical,
                    mountIdentifier: VFSMountIdentifier(rawValue: mountID)!,
                    userAccess: access,
                    requiredCapability: capability
                ) == .mounted,
                "valid namespace mount failed"
            )
        }
    }

    private static func expectMountFailure(
        _ namespace: inout VFSMountNamespace,
        _ volume: VFSVolumeDescriptor,
        path: StaticString,
        mountID: UInt32,
        access: VFSAccessRights,
        capability: VFSCapabilityIdentifier? = nil,
        expected: VFSMountFailure
    ) {
        withCanonical(path) { canonical in
            expect(
                namespace.mount(
                    volume,
                    at: canonical,
                    mountIdentifier: VFSMountIdentifier(rawValue: mountID)!,
                    userAccess: access,
                    requiredCapability: capability
                ) == .failure(expected),
                "invalid namespace mount was accepted"
            )
        }
    }

    private static func resolvedMount(
        _ namespace: VFSMountNamespace,
        path: StaticString
    ) -> VFSMountDescriptor {
        var result: VFSMountDescriptor?
        withCanonical(path) { canonical in
            if case .mount(let resolution) = namespace.resolve(canonical) {
                result = resolution.mount
            }
        }
        guard let result else { fail("expected path was not mounted") }
        return result
    }

    private static func expectSynthetic(
        _ namespace: VFSMountNamespace,
        path: StaticString,
        expected: VFSSyntheticDirectory
    ) {
        withCanonical(path) { canonical in
            guard case .syntheticDirectory(let directory) = namespace.resolve(canonical),
                  directory == expected
            else { fail("synthetic namespace directory did not resolve") }
        }
    }

    private static func expectUnmounted(
        _ namespace: VFSMountNamespace,
        path: StaticString
    ) {
        withCanonical(path) { canonical in
            guard case .unmounted = namespace.resolve(canonical) else {
                fail("unmounted path unexpectedly resolved")
            }
        }
    }

    private static func openedHandle(
        _ table: inout VFSHandleTable,
        metadata: VFSNodeMetadata,
        mount: VFSMountDescriptor,
        access: VFSAccessRights
    ) -> VFSHandleToken {
        guard case .handle(let token) = table.open(
            metadata: metadata,
            on: mount,
            for: .user(taskIdentifier: 1, deviceCapability: nil),
            requesting: access
        ) else { fail("authorized handle open failed") }
        return token
    }

    private static func withNamespace(
        slotCount: Int,
        _ body: (inout VFSMountNamespace) -> Void
    ) {
        let slots = UnsafeMutablePointer<VFSMountSlot>.allocate(capacity: slotCount)
        let pathByteCount = slotCount * VFSPathLimits.maximumPathByteCount
        let paths = UnsafeMutableRawPointer.allocate(
            byteCount: pathByteCount,
            alignment: 8
        )
        defer {
            slots.deinitialize(count: slotCount)
            slots.deallocate()
            paths.deallocate()
        }
        var namespace = VFSMountNamespace(
            uninitializedSlots: slots,
            slotCount: slotCount,
            pathStorage: UnsafeMutableRawBufferPointer(
                start: paths,
                count: pathByteCount
            ),
            maximumPathByteCountPerMount: VFSPathLimits.maximumPathByteCount
        )!
        body(&namespace)
    }

    private static func withHandleTable(
        slotCount: Int,
        initialGeneration: UInt32 = 1,
        _ body: (inout VFSHandleTable) -> Void
    ) {
        let slots = UnsafeMutablePointer<VFSHandleSlot>.allocate(capacity: slotCount)
        defer {
            slots.deinitialize(count: slotCount)
            slots.deallocate()
        }
        var table = VFSHandleTable(
            uninitializedSlots: slots,
            slotCount: slotCount,
            initialGeneration: initialGeneration
        )!
        body(&table)
    }

    private static func withCanonical(
        _ input: StaticString,
        _ body: (VFSCanonicalPath) -> Void
    ) {
        input.withUTF8Buffer { bytes in
            withCanonicalBytes(Array(bytes), body)
        }
    }

    private static func withCanonicalBytes(
        _ input: [UInt8],
        _ body: (VFSCanonicalPath) -> Void
    ) {
        input.withUnsafeBytes { source in
            var output = [UInt8](
                repeating: 0,
                count: VFSPathLimits.maximumPathByteCount
            )
            output.withUnsafeMutableBytes { destination in
                guard case .path(let path) = VFSPathNormalizer.normalize(
                    source,
                    into: destination
                ) else { fail("test path did not normalize") }
                body(path)
            }
        }
    }

    private static func withValidatedName(
        _ input: StaticString,
        _ body: (VFSNameView) -> Void
    ) {
        withRawBytes(input) { bytes in
            guard case .name(let name) = VFSNameValidator.validate(bytes) else {
                fail("test name did not validate")
            }
            body(name)
        }
    }

    private static func withRawBytes(
        _ input: StaticString,
        _ body: (UnsafeRawBufferPointer) -> Void
    ) {
        input.withUTF8Buffer { bytes in
            body(UnsafeRawBufferPointer(bytes))
        }
    }

    private static func expectPathFailure(
        _ input: StaticString,
        _ expected: VFSPathFailure
    ) {
        withRawBytes(input) { bytes in
            expectPathFailure(bytes, expected)
        }
    }

    private static func expectPathFailureBytes(
        _ input: [UInt8],
        _ expected: VFSPathFailure
    ) {
        input.withUnsafeBytes { bytes in
            expectPathFailure(bytes, expected)
        }
    }

    private static func expectPathFailure(
        _ input: UnsafeRawBufferPointer,
        _ expected: VFSPathFailure
    ) {
        var output = [UInt8](
            repeating: 0,
            count: VFSPathLimits.maximumPathByteCount
        )
        output.withUnsafeMutableBytes { destination in
            guard case .failure(let failure) = VFSPathNormalizer.normalize(
                input,
                into: destination
            ), failure == expected else {
                fail("invalid path was accepted or returned the wrong failure")
            }
        }
    }

    private static func expectPath(
        _ path: VFSCanonicalPath,
        equals expected: StaticString
    ) {
        expect(
            path.byteCount == expected.utf8CodeUnitCount,
            "canonical path byte count changed"
        )
        expected.withUTF8Buffer { bytes in
            var index = 0
            while index < bytes.count {
                expect(path.byte(at: index) == bytes[index], "canonical path changed")
                index += 1
            }
        }
    }

    private static func expectName(
        _ name: VFSNameView?,
        equals expected: StaticString
    ) {
        guard let name else { fail("expected name is missing") }
        expectName(name, equals: expected)
    }

    private static func expectName(
        _ name: VFSNameView,
        equals expected: StaticString
    ) {
        expect(name.byteCount == expected.utf8CodeUnitCount, "name length changed")
        expected.withUTF8Buffer { bytes in
            var index = 0
            while index < bytes.count {
                expect(name.byte(at: index) == bytes[index], "name bytes changed")
                index += 1
            }
        }
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
