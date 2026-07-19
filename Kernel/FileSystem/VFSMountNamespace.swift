enum VFSNamespaceLimits {
    static let maximumMountCount = 64
}

/// Caller-owned slot storage lets the namespace remain fixed-capacity without
/// a heap. Slots are intentionally opaque outside the VFS implementation.
struct VFSMountSlot {
    fileprivate var occupied = false
    fileprivate var mountIdentifierRaw: UInt32 = 0
    fileprivate var volumeIdentifierRaw: UInt64 = 0
    fileprivate var role: VFSVolumeRole = .system
    fileprivate var userAccess: VFSAccessRights = .none
    fileprivate var requiredCapabilityRaw: UInt64 = 0
    fileprivate var pathByteCount = 0
    fileprivate var pathComponentCount = 0
}

struct VFSMountDescriptor: Equatable {
    let mountIdentifier: VFSMountIdentifier
    let volume: VFSVolumeDescriptor
    let userAccess: VFSAccessRights
    let requiredCapability: VFSCapabilityIdentifier?
}

struct VFSRelativePathView {
    private let bytes: UnsafePointer<UInt8>?
    let byteCount: Int
    let componentCount: Int

    fileprivate init(
        bytes: UnsafePointer<UInt8>?,
        byteCount: Int,
        componentCount: Int
    ) {
        self.bytes = bytes
        self.byteCount = byteCount
        self.componentCount = componentCount
    }

    var isMountRoot: Bool { byteCount == 0 }

    func component(at requestedIndex: Int) -> VFSNameView? {
        guard requestedIndex >= 0, requestedIndex < componentCount,
              let bytes
        else { return nil }
        var componentIndex = 0
        var start = 0
        while start < byteCount {
            var end = start
            while end < byteCount, bytes[end] != 0x2f { end += 1 }
            if componentIndex == requestedIndex {
                let raw = UnsafeRawBufferPointer(
                    start: bytes + start,
                    count: end - start
                )
                if case .name(let name) = VFSNameValidator.validate(raw) {
                    return name
                }
                return nil
            }
            componentIndex += 1
            start = end + 1
        }
        return nil
    }
}

struct VFSResolvedMount {
    let mount: VFSMountDescriptor
    let relativePath: VFSRelativePathView
}

enum VFSSyntheticDirectory: UInt8, Equatable {
    /// Contains System, Users, Volumes, Devices, and Temporary when present.
    case root = 1
    /// Contains the names of externally mounted node providers.
    case volumes = 2
}

enum VFSMountResolutionResult {
    case mount(VFSResolvedMount)
    case syntheticDirectory(VFSSyntheticDirectory)
    case unmounted
}

enum VFSMountFailure: Equatable {
    case tableFull
    case pathStorageTooSmall
    case kernelOnlyVolume
    case rolePathMismatch
    case deviceCapabilityRequired
    case capabilityOnlyValidForDevices
    case accessExceedsRole
    case duplicateMountIdentifier
    case duplicateVolumeIdentifier
    case duplicatePath
}

enum VFSMountResult: Equatable {
    case mounted
    case failure(VFSMountFailure)
}

struct VFSUnmountedMount: Equatable {
    let mount: VFSMountDescriptor
    let revokedHandleCount: Int
}

enum VFSUnmountFailure: Equatable {
    case notFound
    case syntheticDirectory
    case corruptEntry
}

enum VFSUnmountResult: Equatable {
    case unmounted(VFSUnmountedMount)
    case failure(VFSUnmountFailure)
}

/// Checked, fixed-capacity mount topology. The root and `/Volumes` are virtual
/// directories owned by the namespace; providers may be attached only at:
///
/// - `/System` for immutable OS content
/// - `/Users` for durable user content
/// - `/Volumes/<name>` for additional user volumes
/// - `/Devices` for capability-gated device nodes
/// - `/Temporary` for ephemeral content
struct VFSMountNamespace {
    private let slots: UnsafeMutablePointer<VFSMountSlot>
    private let slotCount: Int
    private let pathStorage: UnsafeMutablePointer<UInt8>
    private let pathStride: Int
    private(set) var mountedCount = 0

    init?(
        uninitializedSlots: UnsafeMutablePointer<VFSMountSlot>?,
        slotCount: Int,
        pathStorage: UnsafeMutableRawBufferPointer,
        maximumPathByteCountPerMount pathStride: Int
    ) {
        guard slotCount > 0,
              slotCount <= VFSNamespaceLimits.maximumMountCount,
              pathStride > 0,
              pathStride <= VFSPathLimits.maximumPathByteCount,
              slotCount <= pathStorage.count / pathStride,
              let slots = uninitializedSlots,
              let pathBytes = pathStorage.baseAddress?
                  .assumingMemoryBound(to: UInt8.self)
        else { return nil }
        self.slots = slots
        self.slotCount = slotCount
        self.pathStorage = pathBytes
        self.pathStride = pathStride
        var index = 0
        while index < slotCount {
            (slots + index).initialize(to: VFSMountSlot())
            index += 1
        }
    }

    mutating func mount(
        _ volume: VFSVolumeDescriptor,
        at path: VFSCanonicalPath,
        mountIdentifier: VFSMountIdentifier,
        userAccess: VFSAccessRights,
        requiredCapability: VFSCapabilityIdentifier? = nil
    ) -> VFSMountResult {
        guard volume.visibility == .namespace else {
            return .failure(.kernelOnlyVolume)
        }
        guard role(volume.role, isValidAt: path) else {
            return .failure(.rolePathMismatch)
        }
        if volume.role == .device {
            guard requiredCapability != nil else {
                return .failure(.deviceCapabilityRequired)
            }
        } else if requiredCapability != nil {
            return .failure(.capabilityOnlyValidForDevices)
        }
        guard userAccess.isSubset(of: VFSRolePolicy.maximumAccess(for: volume.role)) else {
            return .failure(.accessExceedsRole)
        }
        guard path.byteCount <= pathStride else {
            return .failure(.pathStorageTooSmall)
        }

        var freeIndex: Int?
        var index = 0
        while index < slotCount {
            let slot = slots[index]
            if slot.occupied {
                if slot.mountIdentifierRaw == mountIdentifier.rawValue {
                    return .failure(.duplicateMountIdentifier)
                }
                if slot.volumeIdentifierRaw == volume.identifier.rawValue {
                    return .failure(.duplicateVolumeIdentifier)
                }
                if storedPath(at: index, equals: path) {
                    return .failure(.duplicatePath)
                }
            } else if freeIndex == nil {
                freeIndex = index
            }
            index += 1
        }
        guard let slotIndex = freeIndex else { return .failure(.tableFull) }

        let destination = pathStorage + slotIndex * pathStride
        index = 0
        while index < path.byteCount {
            destination[index] = path.byte(at: index)!
            index += 1
        }
        slots[slotIndex].occupied = true
        slots[slotIndex].mountIdentifierRaw = mountIdentifier.rawValue
        slots[slotIndex].volumeIdentifierRaw = volume.identifier.rawValue
        slots[slotIndex].role = volume.role
        slots[slotIndex].userAccess = userAccess
        slots[slotIndex].requiredCapabilityRaw = requiredCapability?.rawValue ?? 0
        slots[slotIndex].pathByteCount = path.byteCount
        slots[slotIndex].pathComponentCount = path.componentCount
        mountedCount += 1
        return .mounted
    }

    func resolve(_ path: VFSCanonicalPath) -> VFSMountResolutionResult {
        if path.isRoot { return .syntheticDirectory(.root) }
        if isSyntheticVolumesPath(path) {
            return .syntheticDirectory(.volumes)
        }

        var bestIndex: Int?
        var bestLength = 0
        var index = 0
        while index < slotCount {
            let slot = slots[index]
            if slot.occupied,
               slot.pathByteCount > bestLength,
               storedPath(at: index, isComponentPrefixOf: path) {
                bestIndex = index
                bestLength = slot.pathByteCount
            }
            index += 1
        }
        guard let slotIndex = bestIndex,
              let descriptor = descriptor(at: slotIndex)
        else { return .unmounted }

        let slot = slots[slotIndex]
        let relativeByteCount: Int
        let relativeBase: UnsafePointer<UInt8>?
        if path.byteCount == slot.pathByteCount {
            relativeByteCount = 0
            relativeBase = nil
        } else {
            relativeByteCount = path.byteCount - slot.pathByteCount - 1
            relativeBase = path.borrowedBaseAddress + slot.pathByteCount + 1
        }
        return .mount(
            VFSResolvedMount(
                mount: descriptor,
                relativePath: VFSRelativePathView(
                    bytes: relativeBase,
                    byteCount: relativeByteCount,
                    componentCount: path.componentCount - slot.pathComponentCount
                )
            )
        )
    }

    /// Revokes every outstanding handle before detaching the provider-facing
    /// descriptor. The caller may tear down that provider only after this
    /// serialized operation returns `.unmounted`.
    mutating func unmount(
        mountIdentifier: VFSMountIdentifier,
        revoking handles: inout VFSHandleTable
    ) -> VFSUnmountResult {
        var index = 0
        while index < slotCount {
            if slots[index].occupied,
               slots[index].mountIdentifierRaw == mountIdentifier.rawValue {
                return unmountSlot(at: index, revoking: &handles)
            }
            index += 1
        }
        return .failure(.notFound)
    }

    /// Exact-path detach; descendants never select a mount implicitly.
    mutating func unmount(
        at path: VFSCanonicalPath,
        revoking handles: inout VFSHandleTable
    ) -> VFSUnmountResult {
        if path.isRoot || isSyntheticVolumesPath(path) {
            return .failure(.syntheticDirectory)
        }
        var index = 0
        while index < slotCount {
            if slots[index].occupied, storedPath(at: index, equals: path) {
                return unmountSlot(at: index, revoking: &handles)
            }
            index += 1
        }
        return .failure(.notFound)
    }

    private mutating func unmountSlot(
        at index: Int,
        revoking handles: inout VFSHandleTable
    ) -> VFSUnmountResult {
        guard let detached = descriptor(at: index) else {
            return .failure(.corruptEntry)
        }
        let revoked = handles.revokeAll(for: detached.mountIdentifier)
        let byteCount = slots[index].pathByteCount
        let destination = pathStorage + index * pathStride
        var byteIndex = 0
        while byteIndex < byteCount {
            destination[byteIndex] = 0
            byteIndex += 1
        }
        slots[index] = VFSMountSlot()
        mountedCount -= 1
        return .unmounted(
            VFSUnmountedMount(
                mount: detached,
                revokedHandleCount: revoked
            )
        )
    }

    private func descriptor(at index: Int) -> VFSMountDescriptor? {
        let slot = slots[index]
        guard slot.occupied,
              let mountIdentifier = VFSMountIdentifier(
                  rawValue: slot.mountIdentifierRaw
              ),
              let volumeIdentifier = VFSVolumeIdentifier(
                  rawValue: slot.volumeIdentifierRaw
              )
        else { return nil }
        let capability: VFSCapabilityIdentifier?
        if slot.requiredCapabilityRaw == 0 {
            capability = nil
        } else {
            capability = VFSCapabilityIdentifier(
                rawValue: slot.requiredCapabilityRaw
            )
        }
        return VFSMountDescriptor(
            mountIdentifier: mountIdentifier,
            volume: VFSVolumeDescriptor(
                identifier: volumeIdentifier,
                role: slot.role,
                visibility: .namespace
            ),
            userAccess: slot.userAccess,
            requiredCapability: capability
        )
    }

    private func role(
        _ role: VFSVolumeRole,
        isValidAt path: VFSCanonicalPath
    ) -> Bool {
        switch role {
        case .system:
            return path.componentCount == 1
                && component(path, at: 0, equalsASCII: systemName)
        case .user:
            if path.componentCount == 1 {
                return component(path, at: 0, equalsASCII: usersName)
            }
            return path.componentCount == 2
                && component(path, at: 0, equalsASCII: volumesName)
        case .temporary:
            return path.componentCount == 1
                && component(path, at: 0, equalsASCII: temporaryName)
        case .device:
            return path.componentCount == 1
                && component(path, at: 0, equalsASCII: devicesName)
        }
    }

    private func isSyntheticVolumesPath(_ path: VFSCanonicalPath) -> Bool {
        path.componentCount == 1
            && component(path, at: 0, equalsASCII: volumesName)
    }

    private func component(
        _ path: VFSCanonicalPath,
        at index: Int,
        equalsASCII expected: StaticString
    ) -> Bool {
        guard let name = path.component(at: index),
              name.byteCount == expected.utf8CodeUnitCount
        else { return false }
        return expected.withUTF8Buffer { bytes in
            var offset = 0
            while offset < bytes.count {
                if name.byte(at: offset) != bytes[offset] { return false }
                offset += 1
            }
            return true
        }
    }

    private func storedPath(
        at slotIndex: Int,
        equals path: VFSCanonicalPath
    ) -> Bool {
        let slot = slots[slotIndex]
        guard slot.pathByteCount == path.byteCount else { return false }
        let stored = pathStorage + slotIndex * pathStride
        var index = 0
        while index < slot.pathByteCount {
            if stored[index] != path.byte(at: index) { return false }
            index += 1
        }
        return true
    }

    private func storedPath(
        at slotIndex: Int,
        isComponentPrefixOf path: VFSCanonicalPath
    ) -> Bool {
        let slot = slots[slotIndex]
        guard path.byteCount >= slot.pathByteCount else { return false }
        let stored = pathStorage + slotIndex * pathStride
        var index = 0
        while index < slot.pathByteCount {
            if stored[index] != path.byte(at: index) { return false }
            index += 1
        }
        return path.byteCount == slot.pathByteCount
            || path.byte(at: slot.pathByteCount) == 0x2f
    }

    private let systemName: StaticString = "System"
    private let usersName: StaticString = "Users"
    private let volumesName: StaticString = "Volumes"
    private let devicesName: StaticString = "Devices"
    private let temporaryName: StaticString = "Temporary"
}
