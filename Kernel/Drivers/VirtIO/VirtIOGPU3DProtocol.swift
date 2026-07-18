// Wire-level VirtIO-GPU 3D control protocol. This file deliberately stops at
// the OASIS controlq boundary: SUBMIT_3D payloads remain opaque and no virgl,
// Venus, or other renderer command stream is implemented here.

enum VirtIOGPU3DFeatureBit {
    static let virgl: UInt32 = 0
    static let edid: UInt32 = 1
    static let resourceUUID: UInt32 = 2
    static let resourceBlob: UInt32 = 3
    static let contextInitialization: UInt32 = 4
    static let blobAlignment: UInt32 = 5
}

struct VirtIOGPU3DFeatures: Equatable {
    static let knownMask: UInt64 = (UInt64(1) << 6) - 1
    /// The smallest accelerated contract SwiftOS can safely request before
    /// capset discovery.
    static let baseline3DRequestMask: UInt64 = UInt64(1)
        << UInt64(VirtIOGPU3DFeatureBit.virgl)
    /// Optional features consumed by the complete session. Feature selection
    /// intersects this mask with the offer, so VIRGL is still required by the
    /// session while context initialization is used when available.
    static let acceleratedRequestMask: UInt64 = baseline3DRequestMask
        | (UInt64(1) << UInt64(
            VirtIOGPU3DFeatureBit.contextInitialization
        ))
    static let none = VirtIOGPU3DFeatures(uncheckedRawValue: 0)

    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue & ~Self.knownMask == 0 else { return nil }
        let hasVirgl = rawValue & Self.mask(VirtIOGPU3DFeatureBit.virgl) != 0
        let hasResourceBlob = rawValue
            & Self.mask(VirtIOGPU3DFeatureBit.resourceBlob) != 0
        let hasContextInitialization = rawValue
            & Self.mask(VirtIOGPU3DFeatureBit.contextInitialization) != 0
        let hasBlobAlignment = rawValue
            & Self.mask(VirtIOGPU3DFeatureBit.blobAlignment) != 0
        guard !hasContextInitialization || hasVirgl,
              !hasBlobAlignment || hasResourceBlob
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    static func negotiated(
        offered: UInt64,
        requested: UInt64
    ) -> VirtIOGPU3DFeatures? {
        guard requested & ~knownMask == 0,
              requested & ~offered == 0
        else {
            return nil
        }
        return VirtIOGPU3DFeatures(rawValue: requested)
    }

    var supports3D: Bool {
        contains(bit: VirtIOGPU3DFeatureBit.virgl)
    }

    var supportsContextInitialization: Bool {
        contains(bit: VirtIOGPU3DFeatureBit.contextInitialization)
    }

    func contains(bit: UInt32) -> Bool {
        guard bit < 64 else { return false }
        return rawValue & Self.mask(bit) != 0
    }

    private init(uncheckedRawValue: UInt64) {
        rawValue = uncheckedRawValue
    }

    private static func mask(_ bit: UInt32) -> UInt64 {
        UInt64(1) << UInt64(bit)
    }
}

enum VirtIOGPU3DControlType {
    static let getCapsetInfo: UInt32 = 0x0108
    static let getCapset: UInt32 = 0x0109

    static let contextCreate: UInt32 = 0x0200
    static let contextDestroy: UInt32 = 0x0201
    static let contextAttachResource: UInt32 = 0x0202
    static let contextDetachResource: UInt32 = 0x0203
    static let resourceCreate3D: UInt32 = 0x0204
    static let transferToHost3D: UInt32 = 0x0205
    static let transferFromHost3D: UInt32 = 0x0206
    static let submit3D: UInt32 = 0x0207

    static let responseOKNoData: UInt32 = 0x1100
    static let responseOKCapsetInfo: UInt32 = 0x1102
    static let responseOKCapset: UInt32 = 0x1103

    static func isRequest(_ value: UInt32) -> Bool {
        value == getCapsetInfo
            || value == getCapset
            || value == contextCreate
            || value == contextDestroy
            || value == contextAttachResource
            || value == contextDetachResource
            || value == resourceCreate3D
            || value == transferToHost3D
            || value == transferFromHost3D
            || value == submit3D
    }

    static func requires3D(_ value: UInt32) -> Bool {
        value >= contextCreate && value <= submit3D
    }

    static func usesContext(_ value: UInt32) -> Bool {
        value == contextCreate
            || value == contextDestroy
            || value == contextAttachResource
            || value == contextDetachResource
            || value == transferToHost3D
            || value == transferFromHost3D
            || value == submit3D
    }
}

enum VirtIOGPU3DCapsetID {
    static let virgl: UInt32 = 1
    static let virgl2: UInt32 = 2
    static let gfxstream: UInt32 = 3
    static let venus: UInt32 = 4
    static let crossDomain: UInt32 = 5

    static func isDefined(_ value: UInt32) -> Bool {
        value >= virgl && value <= crossDomain
    }
}

enum VirtIOGPU3DResourceFlag {
    static let yOriginTop: UInt32 = 1 << 0
}

enum VirtIOGPU3DWireLayout {
    static let controlHeaderByteCount: UInt32 = 24
    static let getCapsetInfoByteCount: UInt32 = 32
    static let getCapsetByteCount: UInt32 = 32
    static let capsetInfoResponseByteCount: UInt32 = 40
    static let contextCreateByteCount: UInt32 = 96
    static let contextDestroyByteCount: UInt32 = 24
    static let contextResourceByteCount: UInt32 = 32
    static let resourceCreate3DByteCount: UInt32 = 72
    static let transfer3DByteCount: UInt32 = 72
    static let submit3DHeaderByteCount: UInt32 = 32
    static let debugNameCapacity: UInt32 = 64
}

struct VirtIOGPU3DFencedHeader: Equatable {
    static let fenceFlag: UInt32 = 1 << 0
    static let informationRingIndexFlag: UInt32 = 1 << 1
    static let maximumRingIndex: UInt8 = 63

    let type: UInt32
    let flags: UInt32
    let fenceID: UInt64
    let contextID: UInt32
    let ringIndex: UInt8

    init?(
        type: UInt32,
        fenceID: UInt64,
        contextID: UInt32 = 0,
        ringIndex: UInt8? = nil,
        features: VirtIOGPU3DFeatures
    ) {
        guard VirtIOGPU3DControlType.isRequest(type),
              !VirtIOGPU3DControlType.requires3D(type)
                || features.supports3D,
              !VirtIOGPU3DControlType.usesContext(type)
                || contextID != 0,
              VirtIOGPU3DControlType.usesContext(type)
                || contextID == 0
        else {
            return nil
        }

        var encodedFlags = Self.fenceFlag
        var encodedRingIndex: UInt8 = 0
        if let ringIndex {
            guard features.supportsContextInitialization,
                  ringIndex <= Self.maximumRingIndex
            else {
                return nil
            }
            encodedFlags |= Self.informationRingIndexFlag
            encodedRingIndex = ringIndex
        }

        self.type = type
        flags = encodedFlags
        self.fenceID = fenceID
        self.contextID = contextID
        self.ringIndex = encodedRingIndex
    }

    func write(at address: UInt64, capacity: UInt32) -> UInt32? {
        let byteCount = VirtIOGPU3DWireLayout.controlHeaderByteCount
        guard VirtIOGPU3DProtocol.prepare(
            address: address,
            capacity: capacity,
            byteCount: byteCount
        ) else {
            return nil
        }
        writePrepared(at: address)
        return byteCount
    }

    fileprivate func writePrepared(at address: UInt64) {
        PhysicalBytes.writeLE32(type, at: address)
        PhysicalBytes.writeLE32(flags, at: address + 4)
        PhysicalBytes.writeLE64(fenceID, at: address + 8)
        PhysicalBytes.writeLE32(contextID, at: address + 16)
        PhysicalBytes.write8(ringIndex, at: address + 20)
        // Bytes 21...23 are padding and were cleared by prepare().
    }
}

struct VirtIOGPU3DCapsetInfo: Equatable {
    let id: UInt32
    let maximumVersion: UInt32
    let maximumByteCount: UInt32
}

struct VirtIOGPU3DByteRange: Equatable {
    let address: UInt64
    let byteCount: UInt32
}

struct VirtIOGPU3DResourceDescriptor: Equatable {
    let resourceID: UInt32
    let target: UInt32
    let format: UInt32
    let bind: UInt32
    let width: UInt32
    let height: UInt32
    let depth: UInt32
    let arraySize: UInt32
    let lastLevel: UInt32
    let sampleCount: UInt32
    let flags: UInt32

    init?(
        resourceID: UInt32,
        target: UInt32,
        format: UInt32,
        bind: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        arraySize: UInt32,
        lastLevel: UInt32,
        sampleCount: UInt32,
        flags: UInt32
    ) {
        guard resourceID != 0,
              width != 0,
              height != 0,
              depth != 0,
              arraySize != 0
        else {
            return nil
        }
        self.resourceID = resourceID
        self.target = target
        self.format = format
        self.bind = bind
        self.width = width
        self.height = height
        self.depth = depth
        self.arraySize = arraySize
        self.lastLevel = lastLevel
        self.sampleCount = sampleCount
        self.flags = flags
    }
}

struct VirtIOGPU3DBox: Equatable {
    let x: UInt32
    let y: UInt32
    let z: UInt32
    let width: UInt32
    let height: UInt32
    let depth: UInt32

    init?(
        x: UInt32,
        y: UInt32,
        z: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32
    ) {
        guard width != 0,
              height != 0,
              depth != 0,
              UInt64(x) + UInt64(width) <= UInt64(UInt32.max),
              UInt64(y) + UInt64(height) <= UInt64(UInt32.max),
              UInt64(z) + UInt64(depth) <= UInt64(UInt32.max)
        else {
            return nil
        }
        self.x = x
        self.y = y
        self.z = z
        self.width = width
        self.height = height
        self.depth = depth
    }
}

struct VirtIOGPU3DTransfer: Equatable {
    let box: VirtIOGPU3DBox
    let offset: UInt64
    let resourceID: UInt32
    let level: UInt32
    let stride: UInt32
    let layerStride: UInt32

    init?(
        box: VirtIOGPU3DBox,
        offset: UInt64,
        resourceID: UInt32,
        level: UInt32,
        stride: UInt32,
        layerStride: UInt32
    ) {
        guard resourceID != 0 else { return nil }
        self.box = box
        self.offset = offset
        self.resourceID = resourceID
        self.level = level
        self.stride = stride
        self.layerStride = layerStride
    }
}

enum VirtIOGPU3DProtocol {
    static let contextInitializationCapsetIDMask: UInt32 = 0x0000_00ff

    static func writeGetCapsetInfo(
        header: VirtIOGPU3DFencedHeader,
        capsetIndex: UInt32,
        availableCapsetCount: UInt32,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        let byteCount = VirtIOGPU3DWireLayout.getCapsetInfoByteCount
        guard header.type == VirtIOGPU3DControlType.getCapsetInfo,
              capsetIndex < availableCapsetCount,
              prepare(address: address, capacity: capacity, byteCount: byteCount)
        else {
            return nil
        }
        header.writePrepared(at: address)
        PhysicalBytes.writeLE32(capsetIndex, at: address + 24)
        return byteCount
    }

    static func writeGetCapset(
        header: VirtIOGPU3DFencedHeader,
        capsetID: UInt32,
        version: UInt32,
        maximumVersion: UInt32,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        let byteCount = VirtIOGPU3DWireLayout.getCapsetByteCount
        guard header.type == VirtIOGPU3DControlType.getCapset,
              VirtIOGPU3DCapsetID.isDefined(capsetID),
              version <= maximumVersion,
              prepare(address: address, capacity: capacity, byteCount: byteCount)
        else {
            return nil
        }
        header.writePrepared(at: address)
        PhysicalBytes.writeLE32(capsetID, at: address + 24)
        PhysicalBytes.writeLE32(version, at: address + 28)
        return byteCount
    }

    static func writeContextCreate(
        header: VirtIOGPU3DFencedHeader,
        contextInitialization: UInt32,
        features: VirtIOGPU3DFeatures,
        debugNameAddress: UInt64,
        debugNameByteCount: UInt32,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        let byteCount = VirtIOGPU3DWireLayout.contextCreateByteCount
        guard header.type == VirtIOGPU3DControlType.contextCreate,
              contextInitialization & ~contextInitializationCapsetIDMask == 0,
              contextInitialization == 0
                || features.supportsContextInitialization,
              contextInitialization == 0
                || VirtIOGPU3DCapsetID.isDefined(contextInitialization),
              debugNameByteCount <= VirtIOGPU3DWireLayout.debugNameCapacity,
              sourceIsUsable(
                  address: debugNameAddress,
                  byteCount: debugNameByteCount,
                  destinationAddress: address,
                  destinationByteCount: byteCount
              ),
              prepare(address: address, capacity: capacity, byteCount: byteCount)
        else {
            return nil
        }
        header.writePrepared(at: address)
        PhysicalBytes.writeLE32(debugNameByteCount, at: address + 24)
        PhysicalBytes.writeLE32(contextInitialization, at: address + 28)
        copyBytes(
            from: debugNameAddress,
            to: address + 32,
            byteCount: debugNameByteCount
        )
        return byteCount
    }

    static func writeContextDestroy(
        header: VirtIOGPU3DFencedHeader,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        guard header.type == VirtIOGPU3DControlType.contextDestroy else {
            return nil
        }
        return header.write(at: address, capacity: capacity)
    }

    static func writeContextAttachResource(
        header: VirtIOGPU3DFencedHeader,
        resourceID: UInt32,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        writeContextResource(
            expectedType: VirtIOGPU3DControlType.contextAttachResource,
            header: header,
            resourceID: resourceID,
            at: address,
            capacity: capacity
        )
    }

    static func writeContextDetachResource(
        header: VirtIOGPU3DFencedHeader,
        resourceID: UInt32,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        writeContextResource(
            expectedType: VirtIOGPU3DControlType.contextDetachResource,
            header: header,
            resourceID: resourceID,
            at: address,
            capacity: capacity
        )
    }

    static func writeResourceCreate3D(
        header: VirtIOGPU3DFencedHeader,
        resource: VirtIOGPU3DResourceDescriptor,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        let byteCount = VirtIOGPU3DWireLayout.resourceCreate3DByteCount
        guard header.type == VirtIOGPU3DControlType.resourceCreate3D,
              prepare(address: address, capacity: capacity, byteCount: byteCount)
        else {
            return nil
        }
        header.writePrepared(at: address)
        PhysicalBytes.writeLE32(resource.resourceID, at: address + 24)
        PhysicalBytes.writeLE32(resource.target, at: address + 28)
        PhysicalBytes.writeLE32(resource.format, at: address + 32)
        PhysicalBytes.writeLE32(resource.bind, at: address + 36)
        PhysicalBytes.writeLE32(resource.width, at: address + 40)
        PhysicalBytes.writeLE32(resource.height, at: address + 44)
        PhysicalBytes.writeLE32(resource.depth, at: address + 48)
        PhysicalBytes.writeLE32(resource.arraySize, at: address + 52)
        PhysicalBytes.writeLE32(resource.lastLevel, at: address + 56)
        PhysicalBytes.writeLE32(resource.sampleCount, at: address + 60)
        PhysicalBytes.writeLE32(resource.flags, at: address + 64)
        return byteCount
    }

    static func writeTransferToHost3D(
        header: VirtIOGPU3DFencedHeader,
        transfer: VirtIOGPU3DTransfer,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        writeTransfer3D(
            expectedType: VirtIOGPU3DControlType.transferToHost3D,
            header: header,
            transfer: transfer,
            at: address,
            capacity: capacity
        )
    }

    static func writeTransferFromHost3D(
        header: VirtIOGPU3DFencedHeader,
        transfer: VirtIOGPU3DTransfer,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        writeTransfer3D(
            expectedType: VirtIOGPU3DControlType.transferFromHost3D,
            header: header,
            transfer: transfer,
            at: address,
            capacity: capacity
        )
    }

    static func writeSubmit3D(
        header: VirtIOGPU3DFencedHeader,
        commandStreamAddress: UInt64,
        commandStreamByteCount: UInt32,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        let prefixByteCount = VirtIOGPU3DWireLayout.submit3DHeaderByteCount
        guard header.type == VirtIOGPU3DControlType.submit3D,
              commandStreamByteCount != 0,
              commandStreamByteCount <= UInt32.max - prefixByteCount
        else {
            return nil
        }
        let byteCount = prefixByteCount + commandStreamByteCount
        guard sourceIsUsable(
                  address: commandStreamAddress,
                  byteCount: commandStreamByteCount,
                  destinationAddress: address,
                  destinationByteCount: byteCount
              ),
              prepare(address: address, capacity: capacity, byteCount: byteCount)
        else {
            return nil
        }
        header.writePrepared(at: address)
        PhysicalBytes.writeLE32(commandStreamByteCount, at: address + 24)
        copyBytes(
            from: commandStreamAddress,
            to: address + UInt64(prefixByteCount),
            byteCount: commandStreamByteCount
        )
        return byteCount
    }

    static func readCapsetInfoResponse(
        at address: UInt64,
        byteCount: UInt32,
        fenceID: UInt64
    ) -> VirtIOGPU3DCapsetInfo? {
        guard byteCount == VirtIOGPU3DWireLayout.capsetInfoResponseByteCount,
              responseHeaderIsValid(
                  at: address,
                  byteCount: byteCount,
                  expectedType: VirtIOGPU3DControlType.responseOKCapsetInfo,
                  fenceID: fenceID
              )
        else {
            return nil
        }
        let id = PhysicalBytes.readLE32(at: address + 24)
        // Capset identifiers are an extensible VirtIO namespace. Preserve
        // unknown nonzero IDs so a bounded selector can ignore capabilities it
        // does not implement instead of rejecting an otherwise usable device.
        guard id != 0 else { return nil }
        return VirtIOGPU3DCapsetInfo(
            id: id,
            maximumVersion: PhysicalBytes.readLE32(at: address + 28),
            maximumByteCount: PhysicalBytes.readLE32(at: address + 32)
        )
    }

    static func readCapsetResponse(
        at address: UInt64,
        byteCount: UInt32,
        expectedPayloadByteCount: UInt32,
        fenceID: UInt64
    ) -> VirtIOGPU3DByteRange? {
        let headerByteCount = VirtIOGPU3DWireLayout.controlHeaderByteCount
        guard expectedPayloadByteCount <= UInt32.max - headerByteCount,
              byteCount == headerByteCount + expectedPayloadByteCount,
              responseHeaderIsValid(
                  at: address,
                  byteCount: byteCount,
                  expectedType: VirtIOGPU3DControlType.responseOKCapset,
                  fenceID: fenceID
              )
        else {
            return nil
        }
        return VirtIOGPU3DByteRange(
            address: address + UInt64(headerByteCount),
            byteCount: expectedPayloadByteCount
        )
    }

    static func noDataResponseIsValid(
        at address: UInt64,
        byteCount: UInt32,
        fenceID: UInt64
    ) -> Bool {
        byteCount == VirtIOGPU3DWireLayout.controlHeaderByteCount
            && responseHeaderIsValid(
                at: address,
                byteCount: byteCount,
                expectedType: VirtIOGPU3DControlType.responseOKNoData,
                fenceID: fenceID
            )
    }

    fileprivate static func prepare(
        address: UInt64,
        capacity: UInt32,
        byteCount: UInt32
    ) -> Bool {
        guard capacity >= byteCount else { return false }
        return PhysicalBytes.zero(
            address: address,
            byteCount: UInt64(byteCount)
        )
    }

    private static func writeContextResource(
        expectedType: UInt32,
        header: VirtIOGPU3DFencedHeader,
        resourceID: UInt32,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        let byteCount = VirtIOGPU3DWireLayout.contextResourceByteCount
        guard header.type == expectedType,
              resourceID != 0,
              prepare(address: address, capacity: capacity, byteCount: byteCount)
        else {
            return nil
        }
        header.writePrepared(at: address)
        PhysicalBytes.writeLE32(resourceID, at: address + 24)
        return byteCount
    }

    private static func writeTransfer3D(
        expectedType: UInt32,
        header: VirtIOGPU3DFencedHeader,
        transfer: VirtIOGPU3DTransfer,
        at address: UInt64,
        capacity: UInt32
    ) -> UInt32? {
        let byteCount = VirtIOGPU3DWireLayout.transfer3DByteCount
        guard header.type == expectedType,
              prepare(address: address, capacity: capacity, byteCount: byteCount)
        else {
            return nil
        }
        header.writePrepared(at: address)
        PhysicalBytes.writeLE32(transfer.box.x, at: address + 24)
        PhysicalBytes.writeLE32(transfer.box.y, at: address + 28)
        PhysicalBytes.writeLE32(transfer.box.z, at: address + 32)
        PhysicalBytes.writeLE32(transfer.box.width, at: address + 36)
        PhysicalBytes.writeLE32(transfer.box.height, at: address + 40)
        PhysicalBytes.writeLE32(transfer.box.depth, at: address + 44)
        PhysicalBytes.writeLE64(transfer.offset, at: address + 48)
        PhysicalBytes.writeLE32(transfer.resourceID, at: address + 56)
        PhysicalBytes.writeLE32(transfer.level, at: address + 60)
        PhysicalBytes.writeLE32(transfer.stride, at: address + 64)
        PhysicalBytes.writeLE32(transfer.layerStride, at: address + 68)
        return byteCount
    }

    private static func responseHeaderIsValid(
        at address: UInt64,
        byteCount: UInt32,
        expectedType: UInt32,
        fenceID: UInt64
    ) -> Bool {
        let headerByteCount = VirtIOGPU3DWireLayout.controlHeaderByteCount
        return byteCount >= headerByteCount
            && rangeIsUsable(address: address, byteCount: byteCount)
            && PhysicalBytes.readLE32(at: address) == expectedType
            && PhysicalBytes.readLE32(at: address + 4)
                & VirtIOGPU3DFencedHeader.fenceFlag != 0
            && PhysicalBytes.readLE64(at: address + 8) == fenceID
    }

    private static func sourceIsUsable(
        address: UInt64,
        byteCount: UInt32,
        destinationAddress: UInt64,
        destinationByteCount: UInt32
    ) -> Bool {
        if byteCount == 0 { return true }
        return rangeIsUsable(address: address, byteCount: byteCount)
            && !rangesOverlap(
                firstAddress: address,
                firstByteCount: byteCount,
                secondAddress: destinationAddress,
                secondByteCount: destinationByteCount
            )
    }

    private static func rangeIsUsable(
        address: UInt64,
        byteCount: UInt32
    ) -> Bool {
        guard address <= UInt64(UInt.max),
              UInt64(byteCount) <= UInt64(Int.max),
              UInt64(byteCount) <= UInt64.max - address,
              UnsafeRawPointer(bitPattern: UInt(address)) != nil
        else {
            return false
        }
        return true
    }

    private static func rangesOverlap(
        firstAddress: UInt64,
        firstByteCount: UInt32,
        secondAddress: UInt64,
        secondByteCount: UInt32
    ) -> Bool {
        guard firstByteCount != 0, secondByteCount != 0 else { return false }
        let firstEnd = firstAddress + UInt64(firstByteCount)
        let secondEnd = secondAddress + UInt64(secondByteCount)
        return firstAddress < secondEnd && secondAddress < firstEnd
    }

    private static func copyBytes(
        from sourceAddress: UInt64,
        to destinationAddress: UInt64,
        byteCount: UInt32
    ) {
        var offset: UInt32 = 0
        while offset < byteCount {
            PhysicalBytes.write8(
                PhysicalBytes.read8(at: sourceAddress + UInt64(offset)),
                at: destinationAddress + UInt64(offset)
            )
            offset += 1
        }
    }
}
