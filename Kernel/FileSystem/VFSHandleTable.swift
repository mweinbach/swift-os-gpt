enum VFSPrincipal: Equatable {
    case kernel
    case user(
        taskIdentifier: UInt64,
        deviceCapability: VFSCapabilityIdentifier?
    )
}

enum VFSAccessDenial: Equatable {
    case emptyRequest
    case invalidPrincipal
    case kernelOnlyVolume
    case volumeMismatch
    case nodeRoleMismatch
    case deniedByRole
    case deniedByMount
    case deniedByNode
    case missingDeviceCapability
}

enum VFSAccessDecision: Equatable {
    case granted
    case denied(VFSAccessDenial)
}

enum VFSAccessPolicy {
    static func authorize(
        principal: VFSPrincipal,
        mount: VFSMountDescriptor,
        metadata: VFSNodeMetadata,
        requested: VFSAccessRights
    ) -> VFSAccessDecision {
        guard !requested.isEmpty else { return .denied(.emptyRequest) }
        guard mount.volume.visibility == .namespace else {
            return .denied(.kernelOnlyVolume)
        }
        guard metadata.identifier.volume == mount.volume.identifier else {
            return .denied(.volumeMismatch)
        }
        if metadata.kind == .device, mount.volume.role != .device {
            return .denied(.nodeRoleMismatch)
        }
        if mount.volume.role == .device,
           metadata.kind != .device,
           metadata.kind != .directory {
            return .denied(.nodeRoleMismatch)
        }
        guard requested.isSubset(
            of: VFSRolePolicy.maximumAccess(for: mount.volume.role)
        ) else { return .denied(.deniedByRole) }

        switch principal {
        case .kernel:
            break
        case .user(let taskIdentifier, let deviceCapability):
            guard taskIdentifier != 0 else {
                return .denied(.invalidPrincipal)
            }
            guard requested.isSubset(of: mount.userAccess) else {
                return .denied(.deniedByMount)
            }
            if mount.volume.role == .device {
                guard let required = mount.requiredCapability,
                      required == deviceCapability
                else { return .denied(.missingDeviceCapability) }
            } else if mount.requiredCapability != nil {
                return .denied(.deniedByMount)
            }
        }
        guard requested.isSubset(of: metadata.availableAccess) else {
            return .denied(.deniedByNode)
        }
        return .granted
    }
}

struct VFSHandleToken: Equatable {
    let slot: UInt16
    let generation: UInt32
}

struct VFSOpenHandle: Equatable {
    let node: VFSNodeIdentifier
    let mountIdentifier: VFSMountIdentifier
    let access: VFSAccessRights
}

struct VFSHandleSlot {
    fileprivate var occupied = false
    fileprivate var generation: UInt32 = 1
    fileprivate var nodeVolumeRaw: UInt64 = 0
    fileprivate var nodeLocalValue: UInt64 = 0
    fileprivate var mountIdentifierRaw: UInt32 = 0
    fileprivate var accessRaw: UInt16 = 0
}

enum VFSHandleOpenResult: Equatable {
    case handle(VFSHandleToken)
    case denied(VFSAccessDenial)
    case tableFull
}

enum VFSHandleLookupFailure: Equatable {
    case invalidSlot
    case staleGeneration
    case closed
    case corruptSlot
}

enum VFSHandleLookupResult: Equatable {
    case handle(VFSOpenHandle)
    case failure(VFSHandleLookupFailure)
}

enum VFSHandleCloseResult: Equatable {
    case closed
    case failure(VFSHandleLookupFailure)
}

/// Fixed-capacity, generation-tagged handles prevent user tasks from receiving
/// provider objects, inode pointers, or raw block ranges. The surrounding VFS
/// serializes table mutation; no implicit allocator or lock is hidden here.
struct VFSHandleTable {
    private let slots: UnsafeMutablePointer<VFSHandleSlot>
    private let slotCount: Int
    private(set) var openCount = 0

    init?(
        uninitializedSlots: UnsafeMutablePointer<VFSHandleSlot>?,
        slotCount: Int,
        initialGeneration: UInt32 = 1
    ) {
        guard slotCount > 0, slotCount <= Int(UInt16.max),
              initialGeneration != 0,
              let slots = uninitializedSlots
        else { return nil }
        self.slots = slots
        self.slotCount = slotCount
        var index = 0
        while index < slotCount {
            var slot = VFSHandleSlot()
            slot.generation = initialGeneration
            (slots + index).initialize(to: slot)
            index += 1
        }
    }

    mutating func open(
        metadata: VFSNodeMetadata,
        on mount: VFSMountDescriptor,
        for principal: VFSPrincipal,
        requesting access: VFSAccessRights
    ) -> VFSHandleOpenResult {
        switch VFSAccessPolicy.authorize(
            principal: principal,
            mount: mount,
            metadata: metadata,
            requested: access
        ) {
        case .granted:
            break
        case .denied(let reason):
            return .denied(reason)
        }

        var index = 0
        while index < slotCount {
            if !slots[index].occupied, slots[index].generation != 0 {
                slots[index].occupied = true
                slots[index].nodeVolumeRaw = metadata.identifier.volume.rawValue
                slots[index].nodeLocalValue = metadata.identifier.localValue
                slots[index].mountIdentifierRaw = mount.mountIdentifier.rawValue
                slots[index].accessRaw = access.rawValue
                openCount += 1
                return .handle(
                    VFSHandleToken(
                        slot: UInt16(index),
                        generation: slots[index].generation
                    )
                )
            }
            index += 1
        }
        return .tableFull
    }

    func lookup(_ token: VFSHandleToken) -> VFSHandleLookupResult {
        let index = Int(token.slot)
        guard index < slotCount else { return .failure(.invalidSlot) }
        let slot = slots[index]
        guard token.generation != 0, token.generation == slot.generation else {
            return .failure(.staleGeneration)
        }
        guard slot.occupied else { return .failure(.closed) }
        guard let volume = VFSVolumeIdentifier(rawValue: slot.nodeVolumeRaw),
              let node = VFSNodeIdentifier(
                  volume: volume,
                  localValue: slot.nodeLocalValue
              ),
              let mount = VFSMountIdentifier(
                  rawValue: slot.mountIdentifierRaw
              ),
              let access = VFSAccessRights(rawValue: slot.accessRaw)
        else { return .failure(.corruptSlot) }
        return .handle(
            VFSOpenHandle(
                node: node,
                mountIdentifier: mount,
                access: access
            )
        )
    }

    mutating func close(_ token: VFSHandleToken) -> VFSHandleCloseResult {
        switch lookup(token) {
        case .handle:
            let index = Int(token.slot)
            retireSlot(at: index)
            return .closed
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Invalidates every handle attached to a mount before provider teardown.
    @discardableResult
    mutating func revokeAll(for mount: VFSMountIdentifier) -> Int {
        var revoked = 0
        var index = 0
        while index < slotCount {
            if slots[index].occupied,
               slots[index].mountIdentifierRaw == mount.rawValue {
                retireSlot(at: index)
                revoked += 1
            }
            index += 1
        }
        return revoked
    }

    private mutating func retireSlot(at index: Int) {
        slots[index].occupied = false
        slots[index].nodeVolumeRaw = 0
        slots[index].nodeLocalValue = 0
        slots[index].mountIdentifierRaw = 0
        slots[index].accessRaw = 0
        if slots[index].generation == UInt32.max {
            // Permanently poison the slot instead of wrapping to generation 1;
            // wrapping would eventually revive an ancient handle token.
            slots[index].generation = 0
        } else {
            slots[index].generation += 1
        }
        openCount -= 1
    }
}
