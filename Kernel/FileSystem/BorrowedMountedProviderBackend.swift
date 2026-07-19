/// A platform-neutral `VFSFileServiceBackend` over one mounted provider.
///
/// Both pointers are borrowed for the complete lifetime of this value. They
/// must address stable, initialized storage and must not be deinitialized or
/// moved while a backend copy exists. Copies alias the same namespace and
/// provider; they never copy a block transport, DMA queue, filesystem cache, or
/// provider state. The owner serializes all namespace/provider access and must
/// revoke process handles before unmounting or replacing either object.
struct BorrowedMountedProviderBackend<Provider: VFSNodeProvider>:
    VFSFileServiceBackend {
    private let namespace: UnsafeMutablePointer<VFSMountNamespace>
    private let provider: UnsafeMutablePointer<Provider>
    private let boundMountIdentifier: VFSMountIdentifier
    private let boundVolumeIdentifier: VFSVolumeIdentifier
    private let providerRoot: VFSNodeIdentifier

    init?(
        borrowing namespace: UnsafeMutablePointer<VFSMountNamespace>?,
        provider: UnsafeMutablePointer<Provider>?,
        mountIdentifier: VFSMountIdentifier,
        rootNode: VFSNodeIdentifier
    ) {
        guard let namespace,
              let provider,
              Self.isAligned(namespace),
              Self.isAligned(provider),
              rootNode.volume == provider.pointee.volumeIdentifier
        else { return nil }
        self.namespace = namespace
        self.provider = provider
        boundMountIdentifier = mountIdentifier
        boundVolumeIdentifier = rootNode.volume
        providerRoot = rootNode
    }

    mutating func resolve(
        path: VFSCanonicalPath
    ) -> FileServicePathResolutionResult {
        guard providerIdentityIsStable else {
            return .failure(.unavailable)
        }
        switch namespace.pointee.resolve(path) {
        case .syntheticDirectory:
            return .syntheticDirectory
        case .unmounted:
            return .notMounted
        case .mount(let resolution):
            guard resolution.mount.mountIdentifier == boundMountIdentifier else {
                // A registry may chain one such backend per provider. This
                // instance must never send another mount to its provider.
                return .notMounted
            }
            guard resolution.mount.volume.identifier == boundVolumeIdentifier,
                  resolution.mount.volume.visibility == .namespace
            else { return .failure(.corrupt) }
            return resolve(
                relativePath: resolution.relativePath,
                mount: resolution.mount
            )
        }
    }

    mutating func metadata(
        for handle: VFSOpenHandle
    ) -> VFSMetadataResult {
        guard let failure = handleFailure(handle) else {
            switch provider.pointee.metadata(for: handle.node) {
            case .metadata(let metadata):
                guard metadata.identifier == handle.node else {
                    return .failure(.corrupt)
                }
                return .metadata(metadata)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .failure(failure)
    }

    mutating func read(
        from handle: VFSOpenHandle,
        at offset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSDataIOResult {
        guard let failure = handleFailure(handle) else {
            return provider.pointee.read(
                node: handle.node,
                at: offset,
                into: output
            )
        }
        return .failure(failure)
    }

    mutating func write(
        to handle: VFSOpenHandle,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> VFSDataIOResult {
        guard let failure = handleFailure(handle) else {
            return provider.pointee.write(
                node: handle.node,
                at: offset,
                from: input
            )
        }
        return .failure(failure)
    }

    mutating func readDirectory(
        from handle: VFSOpenHandle,
        after cookie: VFSDirectoryCookie,
        nameOutput: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult {
        guard let failure = handleFailure(handle) else {
            switch provider.pointee.readDirectory(
                node: handle.node,
                after: cookie,
                nameOutput: nameOutput
            ) {
            case .entry(let entry, let nextCookie):
                guard entry.identifier.volume == boundVolumeIdentifier else {
                    return .failure(.corrupt)
                }
                return .entry(entry, nextCookie: nextCookie)
            case .end:
                return .end
            case .staleCookie:
                return .staleCookie
            case .nameBufferTooSmall(let requiredByteCount):
                return .nameBufferTooSmall(
                    requiredByteCount: requiredByteCount
                )
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .failure(failure)
    }

    private mutating func resolve(
        relativePath: VFSRelativePathView,
        mount: VFSMountDescriptor
    ) -> FileServicePathResolutionResult {
        guard relativePath.componentCount >= 0,
              relativePath.componentCount
                <= VFSPathLimits.maximumComponentCount
        else { return .failure(.corrupt) }
        if relativePath.isMountRoot {
            guard relativePath.componentCount == 0 else {
                return .failure(.corrupt)
            }
        } else if relativePath.componentCount == 0 {
            return .failure(.corrupt)
        }

        let rootMetadata: VFSNodeMetadata
        switch provider.pointee.metadata(for: providerRoot) {
        case .metadata(let metadata):
            guard metadata.identifier == providerRoot,
                  metadata.kind == .directory
            else { return .failure(.corrupt) }
            rootMetadata = metadata
        case .failure(let failure):
            return .failure(failure)
        }
        if relativePath.isMountRoot {
            return .node(mount: mount, metadata: rootMetadata)
        }

        var current = rootMetadata
        var componentIndex = 0
        while componentIndex < relativePath.componentCount {
            guard current.kind == .directory else {
                return .failure(.notDirectory)
            }
            guard let component = relativePath.component(at: componentIndex) else {
                return .failure(.corrupt)
            }
            switch provider.pointee.lookup(
                parent: current.identifier,
                name: component
            ) {
            case .node(let metadata):
                guard metadata.identifier.volume == boundVolumeIdentifier else {
                    return .failure(.corrupt)
                }
                current = metadata
            case .failure(let failure):
                return .failure(failure)
            }
            componentIndex += 1
        }
        return .node(mount: mount, metadata: current)
    }

    private var providerIdentityIsStable: Bool {
        provider.pointee.volumeIdentifier == boundVolumeIdentifier
            && providerRoot.volume == boundVolumeIdentifier
    }

    private func handleFailure(
        _ handle: VFSOpenHandle
    ) -> VFSProviderFailure? {
        guard providerIdentityIsStable else { return .unavailable }
        guard handle.mountIdentifier == boundMountIdentifier else {
            return .unavailable
        }
        guard handle.node.volume == boundVolumeIdentifier else {
            return .corrupt
        }
        return nil
    }

    private static func isAligned<T>(_ pointer: UnsafeMutablePointer<T>) -> Bool {
        UInt(bitPattern: pointer) & UInt(MemoryLayout<T>.alignment - 1) == 0
    }
}
