enum VirtIOGPUControlType {
    static let getDisplayInfo: UInt32 = 0x0100
    static let resourceCreate2D: UInt32 = 0x0101
    static let setScanout: UInt32 = 0x0103
    static let resourceFlush: UInt32 = 0x0104
    static let transferToHost2D: UInt32 = 0x0105
    static let resourceAttachBacking: UInt32 = 0x0106

    static let responseOKNoData: UInt32 = 0x1100
    static let responseOKDisplayInfo: UInt32 = 0x1101
}

struct VirtIOGPURectangle: Equatable {
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32
}

enum VirtIOGPUProtocol {
    static let controlHeaderByteCount: UInt32 = 24
    static let fenceFlag: UInt32 = 1
    static let b8g8r8x8UNorm: UInt32 = 2
    static let maximumScanoutCount = 16
    static let displayInfoResponseByteCount: UInt32 = 408

    static func writeHeader(
        type: UInt32,
        fenceID: UInt64,
        at address: UInt64
    ) {
        PhysicalBytes.writeLE32(type, at: address)
        PhysicalBytes.writeLE32(fenceFlag, at: address + 4)
        PhysicalBytes.writeLE64(fenceID, at: address + 8)
        PhysicalBytes.writeLE32(0, at: address + 16)
        PhysicalBytes.writeLE32(0, at: address + 20)
    }

    static func writeRectangle(
        _ rectangle: VirtIOGPURectangle,
        at address: UInt64
    ) {
        PhysicalBytes.writeLE32(rectangle.x, at: address)
        PhysicalBytes.writeLE32(rectangle.y, at: address + 4)
        PhysicalBytes.writeLE32(rectangle.width, at: address + 8)
        PhysicalBytes.writeLE32(rectangle.height, at: address + 12)
    }

    static func responseIsValid(
        at address: UInt64,
        byteCount: UInt32,
        expectedType: UInt32,
        fenceID: UInt64
    ) -> Bool {
        byteCount >= controlHeaderByteCount
            && PhysicalBytes.readLE32(at: address) == expectedType
            && PhysicalBytes.readLE32(at: address + 4) & fenceFlag != 0
            && PhysicalBytes.readLE64(at: address + 8) == fenceID
    }

    static func firstEnabledScanout(
        responseAddress: UInt64,
        responseByteCount: UInt32,
        minimumWidth: UInt32,
        minimumHeight: UInt32
    ) -> UInt32? {
        guard responseByteCount >= displayInfoResponseByteCount else {
            return nil
        }
        var index = 0
        while index < maximumScanoutCount {
            let mode = responseAddress + UInt64(controlHeaderByteCount)
                + UInt64(index * 24)
            let width = PhysicalBytes.readLE32(at: mode + 8)
            let height = PhysicalBytes.readLE32(at: mode + 12)
            let enabled = PhysicalBytes.readLE32(at: mode + 16)
            if enabled != 0,
               width >= minimumWidth,
               height >= minimumHeight {
                return UInt32(index)
            }
            index += 1
        }
        return nil
    }
}

/// VirtIO GPU 2D scanout. Rendering remains entirely in Swift on the CPU; this
/// driver owns the transport, GPU resource, backing attachment and explicit
/// transfer/flush lifecycle needed to put those pixels on a real device model.
struct VirtIOGPU {
    static let readyMarker: StaticString = "SWIFTOS:VIRTIO_GPU_OK\n"
    static let transportReadyMarker: StaticString = "SWIFTOS:VIRTIO_MMIO_OK\n"

    private static let resourceID: UInt32 = 1
    private var transport: VirtIOMMIOTransport
    private let scanout: ScanoutBuffer
    private let framebufferByteCount: UInt32
    private let rectangle: VirtIOGPURectangle
    private var scanoutID: UInt32 = 0
    private var nextFenceID: UInt64 = 1
    private(set) var isConfigured = false

    init?(
        transport: VirtIOMMIOTransport,
        scanout: ScanoutBuffer
    ) {
        let mode = scanout.mode
        guard mode.pixelFormat == .b8g8r8x8,
              scanout.mapping.coherency == .hardwareCoherent,
              scanout.requiredByteCount <= UInt64(UInt32.max)
        else {
            return nil
        }
        self.transport = transport
        self.scanout = scanout
        framebufferByteCount = UInt32(scanout.requiredByteCount)
        rectangle = VirtIOGPURectangle(
            x: 0,
            y: 0,
            width: mode.widthInPixels,
            height: mode.heightInPixels
        )
    }

    mutating func configure() -> Bool {
        guard queryDisplay(),
              createResource(),
              attachBacking(),
              selectScanout()
        else {
            transport.failDevice()
            return false
        }
        isConfigured = true
        return true
    }

    mutating func present(_ damage: DamageRectangle) -> Bool {
        guard isConfigured else { return false }
        guard let rectangle = protocolRectangle(for: damage) else {
            return false
        }
        AArch64.synchronizeData()
        guard transferToHost(rectangle), flushResource(rectangle) else {
            isConfigured = false
            transport.failDevice()
            return false
        }
        return true
    }

    private mutating func queryDisplay() -> Bool {
        guard transport.prepareBuffers() else { return false }
        let fence = takeFence()
        VirtIOGPUProtocol.writeHeader(
            type: VirtIOGPUControlType.getDisplayInfo,
            fenceID: fence,
            at: transport.requestAddress
        )
        guard let responseByteCount = submit(
                  byteCount: VirtIOGPUProtocol.controlHeaderByteCount,
                  responseCapacity:
                    VirtIOGPUProtocol.displayInfoResponseByteCount,
                  expectedType: VirtIOGPUControlType.responseOKDisplayInfo,
                  fenceID: fence
              ),
              let selected = VirtIOGPUProtocol.firstEnabledScanout(
                  responseAddress: transport.responseAddress,
                  responseByteCount: responseByteCount,
                  minimumWidth: rectangle.width,
                  minimumHeight: rectangle.height
              )
        else {
            return false
        }
        scanoutID = selected
        return true
    }

    private mutating func createResource() -> Bool {
        guard transport.prepareBuffers() else { return false }
        let fence = takeFence()
        let request = transport.requestAddress
        VirtIOGPUProtocol.writeHeader(
            type: VirtIOGPUControlType.resourceCreate2D,
            fenceID: fence,
            at: request
        )
        PhysicalBytes.writeLE32(Self.resourceID, at: request + 24)
        PhysicalBytes.writeLE32(
            VirtIOGPUProtocol.b8g8r8x8UNorm,
            at: request + 28
        )
        PhysicalBytes.writeLE32(rectangle.width, at: request + 32)
        PhysicalBytes.writeLE32(rectangle.height, at: request + 36)
        return submitNoData(byteCount: 40, fenceID: fence)
    }

    private mutating func attachBacking() -> Bool {
        guard transport.prepareBuffers() else { return false }
        let fence = takeFence()
        let request = transport.requestAddress
        VirtIOGPUProtocol.writeHeader(
            type: VirtIOGPUControlType.resourceAttachBacking,
            fenceID: fence,
            at: request
        )
        PhysicalBytes.writeLE32(Self.resourceID, at: request + 24)
        PhysicalBytes.writeLE32(1, at: request + 28)
        PhysicalBytes.writeLE64(
            scanout.mapping.deviceAddress,
            at: request + 32
        )
        PhysicalBytes.writeLE32(framebufferByteCount, at: request + 40)
        PhysicalBytes.writeLE32(0, at: request + 44)
        return submitNoData(byteCount: 48, fenceID: fence)
    }

    private mutating func selectScanout() -> Bool {
        guard transport.prepareBuffers() else { return false }
        let fence = takeFence()
        let request = transport.requestAddress
        VirtIOGPUProtocol.writeHeader(
            type: VirtIOGPUControlType.setScanout,
            fenceID: fence,
            at: request
        )
        VirtIOGPUProtocol.writeRectangle(rectangle, at: request + 24)
        PhysicalBytes.writeLE32(scanoutID, at: request + 40)
        PhysicalBytes.writeLE32(Self.resourceID, at: request + 44)
        return submitNoData(byteCount: 48, fenceID: fence)
    }

    private mutating func transferToHost(
        _ damage: VirtIOGPURectangle
    ) -> Bool {
        guard transport.prepareBuffers() else { return false }
        let fence = takeFence()
        let request = transport.requestAddress
        VirtIOGPUProtocol.writeHeader(
            type: VirtIOGPUControlType.transferToHost2D,
            fenceID: fence,
            at: request
        )
        VirtIOGPUProtocol.writeRectangle(damage, at: request + 24)
        let offset = UInt64(damage.y) * scanout.bytesPerRow
            + UInt64(damage.x) * scanout.mode.pixelFormat.bytesPerPixel
        PhysicalBytes.writeLE64(offset, at: request + 40)
        PhysicalBytes.writeLE32(Self.resourceID, at: request + 48)
        PhysicalBytes.writeLE32(0, at: request + 52)
        return submitNoData(byteCount: 56, fenceID: fence)
    }

    private mutating func flushResource(
        _ damage: VirtIOGPURectangle
    ) -> Bool {
        guard transport.prepareBuffers() else { return false }
        let fence = takeFence()
        let request = transport.requestAddress
        VirtIOGPUProtocol.writeHeader(
            type: VirtIOGPUControlType.resourceFlush,
            fenceID: fence,
            at: request
        )
        VirtIOGPUProtocol.writeRectangle(damage, at: request + 24)
        PhysicalBytes.writeLE32(Self.resourceID, at: request + 40)
        PhysicalBytes.writeLE32(0, at: request + 44)
        return submitNoData(byteCount: 48, fenceID: fence)
    }

    private mutating func submitNoData(
        byteCount: UInt32,
        fenceID: UInt64
    ) -> Bool {
        submit(
            byteCount: byteCount,
            responseCapacity: VirtIOGPUProtocol.controlHeaderByteCount,
            expectedType: VirtIOGPUControlType.responseOKNoData,
            fenceID: fenceID
        ) != nil
    }

    private mutating func submit(
        byteCount: UInt32,
        responseCapacity: UInt32,
        expectedType: UInt32,
        fenceID: UInt64
    ) -> UInt32? {
        switch transport.submit(
            requestByteCount: byteCount,
            responseCapacity: responseCapacity
        ) {
        case let .completed(responseByteCount):
            guard VirtIOGPUProtocol.responseIsValid(
                at: transport.responseAddress,
                byteCount: responseByteCount,
                expectedType: expectedType,
                fenceID: fenceID
            ) else {
                return nil
            }
            return responseByteCount
        case .invalidRequest, .timedOut, .malformedCompletion,
             .deviceNeedsReset:
            return nil
        }
    }

    private func protocolRectangle(
        for damage: DamageRectangle
    ) -> VirtIOGPURectangle? {
        let horizontalEnd = UInt64(damage.x) + UInt64(damage.width)
        let verticalEnd = UInt64(damage.y) + UInt64(damage.height)
        guard damage.width > 0,
              damage.height > 0,
              horizontalEnd <= UInt64(scanout.mode.widthInPixels),
              verticalEnd <= UInt64(scanout.mode.heightInPixels)
        else {
            return nil
        }
        return VirtIOGPURectangle(
            x: damage.x,
            y: damage.y,
            width: damage.width,
            height: damage.height
        )
    }

    private mutating func takeFence() -> UInt64 {
        let fence = nextFenceID
        nextFenceID &+= 1
        if nextFenceID == 0 { nextFenceID = 1 }
        return fence
    }
}
