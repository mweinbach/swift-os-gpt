// The real transport is volatile MMIO. This deterministic transport shim
// behaves like one VIRGL2 device and rejects any lifecycle packet that arrives
// out of order or with the wrong fields.

enum VirtIOMMIORequestResult: Equatable {
    case completed(responseByteCount: UInt32)
    case invalidRequest
    case timedOut
    case malformedCompletion
    case deviceNeedsReset
}

enum AArch64 {
    static func synchronizeData() {}
}

struct VirtIOMMIOTransport {
    enum Behavior: Equatable {
        case normal
        case timeoutAt(step: Int)
        case wrongFenceAt(step: Int)
        case noEnabledScanout
    }

    var requestAddress: UInt64 = 0
    var responseAddress: UInt64 = 0
    var negotiatedFeatures: UInt64
    var configuration: VirtIOGPUDeviceConfiguration
    var behavior: Behavior
    private var step = 0

    init(
        negotiatedFeatures: UInt64,
        configuration: VirtIOGPUDeviceConfiguration,
        behavior: Behavior
    ) {
        self.negotiatedFeatures = negotiatedFeatures
        self.configuration = configuration
        self.behavior = behavior
    }

    mutating func readGPUDeviceConfiguration(
        maximumAttempts: Int = 8
    ) -> VirtIOGPUDeviceConfigurationReadResult {
        guard maximumAttempts > 0 else { return .invalidAttemptLimit }
        return .ready(configuration)
    }

    mutating func submit(
        buffers: VirtIOQueueBufferPair,
        pollLimit: UInt64 = 5_000_000
    ) -> VirtIOMMIORequestResult {
        guard pollLimit > 0 else { return .invalidRequest }
        if behavior == .timeoutAt(step: step) {
            return .timedOut
        }
        guard requestIsValid(
                  at: buffers.request.cpuPhysicalAddress,
                  byteCount: buffers.requestByteCount,
                  step: step
              )
        else {
            return .invalidRequest
        }
        let responseByteCount = writeResponse(
            at: buffers.response.cpuPhysicalAddress,
            capacity: buffers.responseCapacity,
            requestAddress: buffers.request.cpuPhysicalAddress,
            step: step
        )
        guard responseByteCount >= 24 else {
            return .malformedCompletion
        }
        step += 1
        return .completed(responseByteCount: responseByteCount)
    }

    // Required only because the production 2D driver shares its source file
    // with VirtIOGPUProtocol in this host build.
    mutating func prepareBuffers() -> Bool { false }

    mutating func submit(
        requestByteCount: UInt32,
        responseCapacity: UInt32
    ) -> VirtIOMMIORequestResult {
        _ = requestByteCount
        _ = responseCapacity
        return .invalidRequest
    }

    mutating func failDevice() {}

    private func requestIsValid(
        at address: UInt64,
        byteCount: UInt32,
        step: Int
    ) -> Bool {
        let expectedType: UInt32
        let expectedByteCount: UInt32?
        switch step {
        case 0:
            expectedType = VirtIOGPUControlType.getDisplayInfo
            expectedByteCount = 24
        case 1:
            expectedType = VirtIOGPU3DControlType.getCapsetInfo
            expectedByteCount = 32
        case 2:
            expectedType = VirtIOGPU3DControlType.getCapsetInfo
            expectedByteCount = 32
        case 3:
            expectedType = VirtIOGPU3DControlType.getCapset
            expectedByteCount = 32
        case 4:
            expectedType = VirtIOGPU3DControlType.contextCreate
            expectedByteCount = 96
        case 5:
            expectedType = VirtIOGPU3DControlType.resourceCreate3D
            expectedByteCount = 72
        case 6:
            expectedType = VirtIOGPU3DControlType.contextAttachResource
            expectedByteCount = 32
        case 7:
            expectedType = VirtIOGPU3DControlType.resourceCreate3D
            expectedByteCount = 72
        case 8:
            expectedType = VirtIOGPU3DControlType.contextAttachResource
            expectedByteCount = 32
        case 9:
            expectedType = VirtIOGPU3DControlType.resourceCreate3D
            expectedByteCount = 72
        case 10:
            expectedType = VirtIOGPU3DControlType.contextAttachResource
            expectedByteCount = 32
        case 11:
            expectedType = VirtIOGPU3DControlType.submit3D
            expectedByteCount = 128
        case 12, 13:
            expectedType = VirtIOGPU3DControlType.submit3D
            expectedByteCount = 3_104
        case 14:
            expectedType = VirtIOGPU3DControlType.submit3D
            expectedByteCount = 3_052
        case 15:
            expectedType = VirtIOGPU3DControlType.submit3D
            expectedByteCount = 2_252
        case 16:
            expectedType = VirtIOGPUControlType.setScanout
            expectedByteCount = 48
        case 17:
            expectedType = VirtIOGPUControlType.resourceFlush
            expectedByteCount = 48
        case 18:
            expectedType = VirtIOGPU3DControlType.submit3D
            expectedByteCount = 132
        case 19:
            expectedType = VirtIOGPUControlType.resourceFlush
            expectedByteCount = 48
        default:
            return false
        }
        guard (expectedByteCount == nil || byteCount == expectedByteCount),
              PhysicalBytes.readLE32(at: address) == expectedType,
              PhysicalBytes.readLE32(at: address + 4)
                & VirtIOGPUProtocol.fenceFlag != 0,
              PhysicalBytes.readLE64(at: address + 8) == UInt64(step + 1)
        else {
            return false
        }

        switch step {
        case 0:
            return PhysicalBytes.readLE32(at: address + 16) == 0
        case 1:
            return PhysicalBytes.readLE32(at: address + 24) == 0
                && PhysicalBytes.readLE32(at: address + 16) == 0
        case 2:
            return PhysicalBytes.readLE32(at: address + 24) == 1
                && PhysicalBytes.readLE32(at: address + 16) == 0
        case 3:
            return PhysicalBytes.readLE32(at: address + 24) == 2
                && PhysicalBytes.readLE32(at: address + 28) == 2
        case 4:
            return PhysicalBytes.readLE32(at: address + 16) == 1
                && PhysicalBytes.readLE32(at: address + 24) == 0
                && PhysicalBytes.readLE32(at: address + 28)
                    == (negotiatedFeatures & (1 << 4) != 0 ? 2 : 0)
        case 5:
            return PhysicalBytes.readLE32(at: address + 16) == 0
                && PhysicalBytes.readLE32(at: address + 24) == 1
                && PhysicalBytes.readLE32(at: address + 28) == 2
                && PhysicalBytes.readLE32(at: address + 32) == 100
                && PhysicalBytes.readLE32(at: address + 36) == 0x0004_0002
                && PhysicalBytes.readLE32(at: address + 40) == 1_920
                && PhysicalBytes.readLE32(at: address + 44) == 1_080
                && PhysicalBytes.readLE32(at: address + 48) == 1
                && PhysicalBytes.readLE32(at: address + 52) == 1
                && PhysicalBytes.readLE32(at: address + 56) == 0
                && PhysicalBytes.readLE32(at: address + 60) == 0
                && PhysicalBytes.readLE32(at: address + 64) == 1
        case 6:
            return PhysicalBytes.readLE32(at: address + 16) == 1
                && PhysicalBytes.readLE32(at: address + 24) == 1
        case 7:
            return PhysicalBytes.readLE32(at: address + 16) == 0
                && PhysicalBytes.readLE32(at: address + 24) == 2
                && PhysicalBytes.readLE32(at: address + 28) == 0
                && PhysicalBytes.readLE32(at: address + 32) == 64
                && PhysicalBytes.readLE32(at: address + 36) == 0x10
                && PhysicalBytes.readLE32(at: address + 40) == 48
                && PhysicalBytes.readLE32(at: address + 44) == 1
                && PhysicalBytes.readLE32(at: address + 48) == 1
                && PhysicalBytes.readLE32(at: address + 52) == 1
                && PhysicalBytes.readLE32(at: address + 56) == 0
                && PhysicalBytes.readLE32(at: address + 60) == 0
                && PhysicalBytes.readLE32(at: address + 64) == 0
        case 8:
            return PhysicalBytes.readLE32(at: address + 16) == 1
                && PhysicalBytes.readLE32(at: address + 24) == 2
        case 9:
            return PhysicalBytes.readLE32(at: address + 16) == 0
                && PhysicalBytes.readLE32(at: address + 24) == 3
                && PhysicalBytes.readLE32(at: address + 28) == 2
                && PhysicalBytes.readLE32(at: address + 32) == 64
                && PhysicalBytes.readLE32(at: address + 36) == 0x8
                && PhysicalBytes.readLE32(at: address + 40) == 112
                && PhysicalBytes.readLE32(at: address + 44) == 54
                && PhysicalBytes.readLE32(at: address + 48) == 1
                && PhysicalBytes.readLE32(at: address + 52) == 1
                && PhysicalBytes.readLE32(at: address + 56) == 0
                && PhysicalBytes.readLE32(at: address + 60) == 0
                && PhysicalBytes.readLE32(at: address + 64) == 0
        case 10:
            return PhysicalBytes.readLE32(at: address + 16) == 1
                && PhysicalBytes.readLE32(at: address + 24) == 3
        case 11:
            return unitQuadUploadIsValid(at: address)
        case 12:
            return glyphAtlasUploadIsValid(
                at: address,
                requestByteCount: byteCount,
                uploadIndex: 0
            )
        case 13:
            return glyphAtlasUploadIsValid(
                at: address,
                requestByteCount: byteCount,
                uploadIndex: 1
            )
        case 14:
            return pipelineInitializationCommandStreamIsValid(
                at: address,
                requestByteCount: byteCount
            )
        case 15:
            return initialRenderCommandStreamIsValid(
                at: address,
                requestByteCount: byteCount
            )
        case 16:
            return rectangleIsFullDisplay(at: address + 24)
                && PhysicalBytes.readLE32(at: address + 40) == 0
                && PhysicalBytes.readLE32(at: address + 44) == 1
        case 17:
            return rectangleIsFullDisplay(at: address + 24)
                && PhysicalBytes.readLE32(at: address + 40) == 1
                && PhysicalBytes.readLE32(at: address + 44) == 0
        case 18:
            return subsequentRenderCommandStreamIsValid(
                at: address,
                requestByteCount: byteCount
            )
        case 19:
            return rectangleIsFullDisplay(at: address + 24)
                && PhysicalBytes.readLE32(at: address + 40) == 1
                && PhysicalBytes.readLE32(at: address + 44) == 0
        default:
            return false
        }
    }

    private func unitQuadUploadIsValid(at address: UInt64) -> Bool {
        let expected: [UInt32] = [
            0x0017_0009,
            2, 0, 0x82, 0, 0,
            0, 0, 0, 48, 1, 1,
            0, 0,
            0x3f80_0000, 0,
            0, 0x3f80_0000,
            0, 0x3f80_0000,
            0x3f80_0000, 0,
            0x3f80_0000, 0x3f80_0000,
        ]
        guard PhysicalBytes.readLE32(at: address + 16) == 1,
              PhysicalBytes.readLE32(at: address + 24) == 96
        else {
            return false
        }
        var index = 0
        while index < expected.count {
            if PhysicalBytes.readLE32(
                at: address + 32 + UInt64(index * 4)
            ) != expected[index] {
                return false
            }
            index += 1
        }
        return true
    }

    private func glyphAtlasUploadIsValid(
        at address: UInt64,
        requestByteCount: UInt32,
        uploadIndex: Int
    ) -> Bool {
        guard uploadIndex == 0 || uploadIndex == 1,
              requestByteCount == 3_104,
              PhysicalBytes.readLE32(at: address + 16) == 1,
              PhysicalBytes.readLE32(at: address + 24) == 3_072
        else {
            return false
        }

        let stream = address + 32
        let expectedY: UInt32 = uploadIndex == 0 ? 0 : 27
        guard PhysicalBytes.readLE32(at: stream) == 0x02ff_0009,
              PhysicalBytes.readLE32(at: stream + 4) == 3,
              PhysicalBytes.readLE32(at: stream + 8) == 0,
              PhysicalBytes.readLE32(at: stream + 12) == 0x82,
              PhysicalBytes.readLE32(at: stream + 16) == 112,
              PhysicalBytes.readLE32(at: stream + 20) == 3_024,
              PhysicalBytes.readLE32(at: stream + 24) == 0,
              PhysicalBytes.readLE32(at: stream + 28) == expectedY,
              PhysicalBytes.readLE32(at: stream + 32) == 0,
              PhysicalBytes.readLE32(at: stream + 36) == 112,
              PhysicalBytes.readLE32(at: stream + 40) == 27,
              PhysicalBytes.readLE32(at: stream + 44) == 1
        else {
            return false
        }

        let data = stream + 48
        if uploadIndex == 0 {
            // Capital A, atlas row 19, columns 8...12.
            return bytesMatch(
                [0, 255, 255, 255, 0],
                at: data + 2_136
            )
        }

        // Lowercase a in local row 10 and the replacement glyph in row 19
        // prove that the second strip was generated rather than repeated.
        return bytesMatch(
            [0, 255, 255, 255, 0],
            at: data + 1_128
        ) && bytesMatch(
            [255, 255, 255, 255, 255],
            at: data + 2_234
        )
    }

    private func bytesMatch(_ expected: [UInt8], at address: UInt64) -> Bool {
        var index = 0
        while index < expected.count {
            if PhysicalBytes.read8(at: address + UInt64(index))
                != expected[index] {
                return false
            }
            index += 1
        }
        return true
    }

    private func pipelineInitializationCommandStreamIsValid(
        at address: UInt64,
        requestByteCount: UInt32
    ) -> Bool {
        guard PhysicalBytes.readLE32(at: address + 16) == 1,
              requestByteCount == 3_052,
              PhysicalBytes.readLE32(at: address + 24) == 3_020
        else {
            return false
        }
        let stream = address + 32
        let commandByteCount = requestByteCount - 32
        var offset: UInt32 = 0
        var surfaceCount = 0
        var shaderCreateMask: UInt8 = 0
        var shaderCreateCount = 0
        var samplerViewCount = 0
        var samplerStateMask: UInt8 = 0
        var samplerStateCount = 0
        var packetCount = 0
        while offset < commandByteCount {
            let packet = stream + UInt64(offset)
            let header = PhysicalBytes.readLE32(at: packet)
            let payloadDWords = header >> 16
            let packetByteCount = (payloadDWords + 1) * 4
            guard packetByteCount > 4,
                  packetByteCount <= commandByteCount - offset
            else {
                return false
            }
            let command = UInt8(truncatingIfNeeded: header)
            let objectType = UInt8(truncatingIfNeeded: header >> 8)
            packetCount += 1
            switch command {
            case 1 where objectType == 8:
                surfaceCount += 1
                guard PhysicalBytes.readLE32(at: packet + 4) == 0x100,
                      PhysicalBytes.readLE32(at: packet + 8) == 1,
                      PhysicalBytes.readLE32(at: packet + 12) == 100
                else {
                    return false
                }
            case 1 where objectType == 4:
                shaderCreateCount += 1
                let handle = PhysicalBytes.readLE32(at: packet + 4)
                let stage = PhysicalBytes.readLE32(at: packet + 8)
                switch (handle, stage) {
                case (0x101, 0): shaderCreateMask |= 1 << 0
                case (0x102, 1): shaderCreateMask |= 1 << 1
                case (0x108, 0): shaderCreateMask |= 1 << 2
                case (0x109, 1): shaderCreateMask |= 1 << 3
                case (0x10a, 0): shaderCreateMask |= 1 << 4
                case (0x10b, 1): shaderCreateMask |= 1 << 5
                default: return false
                }
            case 1 where objectType == 6:
                samplerViewCount += 1
                guard PhysicalBytes.readLE32(at: packet + 4) == 0x10c,
                      PhysicalBytes.readLE32(at: packet + 8) == 3,
                      PhysicalBytes.readLE32(at: packet + 12) == 64,
                      PhysicalBytes.readLE32(at: packet + 16) == 0,
                      PhysicalBytes.readLE32(at: packet + 20) == 0,
                      PhysicalBytes.readLE32(at: packet + 24) == 0
                else {
                    return false
                }
            case 1 where objectType == 7:
                samplerStateCount += 1
                let handle = PhysicalBytes.readLE32(at: packet + 4)
                let packedState = PhysicalBytes.readLE32(at: packet + 8)
                switch (handle, packedState) {
                case (0x10d, 0x1092): samplerStateMask |= 1 << 0
                case (0x10e, 0x3292): samplerStateMask |= 1 << 1
                default: return false
                }
            case 1:
                break
            default:
                return false
            }
            offset += packetByteCount
        }
        return offset == commandByteCount
            && packetCount == 15
            && surfaceCount == 1
            && shaderCreateCount == 6
            && shaderCreateMask == 0x3f
            && samplerViewCount == 1
            && samplerStateCount == 2
            && samplerStateMask == 0x3
    }

    private func initialRenderCommandStreamIsValid(
        at address: UInt64,
        requestByteCount: UInt32
    ) -> Bool {
        guard PhysicalBytes.readLE32(at: address + 16) == 1,
              requestByteCount == 2_252,
              PhysicalBytes.readLE32(at: address + 24) == 2_220
        else {
            return false
        }
        let stream = address + 32
        let commandByteCount = requestByteCount - 32
        var offset: UInt32 = 0
        var shaderBindMask: UInt8 = 0
        var shaderBindCount = 0
        var framebufferCount = 0
        var clearCount = 0
        var scissorCount = 0
        var sawFullScissor = false
        var sawLogicalScissor = false
        var sawTextScissor = false
        var vertexBufferCount = 0
        var drawCount = 0
        var samplerViewBindCount = 0
        var samplerStateBindCount = 0
        var packetCount = 0
        while offset < commandByteCount {
            let packet = stream + UInt64(offset)
            let header = PhysicalBytes.readLE32(at: packet)
            let payloadDWords = header >> 16
            let packetByteCount = (payloadDWords + 1) * 4
            guard packetByteCount > 4,
                  packetByteCount <= commandByteCount - offset
            else {
                return false
            }
            let command = UInt8(truncatingIfNeeded: header)
            packetCount += 1
            switch command {
            case 1, 9:
                return false
            case 5:
                framebufferCount += 1
            case 6:
                vertexBufferCount += 1
                guard PhysicalBytes.readLE32(at: packet + 4) == 8,
                      PhysicalBytes.readLE32(at: packet + 8) == 0,
                      PhysicalBytes.readLE32(at: packet + 12) == 2
                else {
                    return false
                }
            case 7:
                clearCount += 1
            case 8:
                drawCount += 1
                guard PhysicalBytes.readLE32(at: packet + 8) == 6,
                      PhysicalBytes.readLE32(at: packet + 12) == 4
                else {
                    return false
                }
            case 10:
                samplerViewBindCount += 1
                guard PhysicalBytes.readLE32(at: packet + 4) == 1,
                      PhysicalBytes.readLE32(at: packet + 8) == 0,
                      PhysicalBytes.readLE32(at: packet + 12) == 0x10c
                else {
                    return false
                }
            case 15:
                scissorCount += 1
                let minimum = PhysicalBytes.readLE32(at: packet + 8)
                let maximum = PhysicalBytes.readLE32(at: packet + 12)
                sawFullScissor = sawFullScissor
                    || (minimum == 0
                        && maximum
                            == UInt32(1_920) | (UInt32(1_080) << 16))
                sawLogicalScissor = sawLogicalScissor
                    || (minimum
                            == UInt32(560) | (UInt32(240) << 16)
                        && maximum
                            == UInt32(1_360) | (UInt32(840) << 16))
                sawTextScissor = sawTextScissor
                    || (minimum
                            == UInt32(560) | (UInt32(796) << 16)
                        && maximum
                            == UInt32(1_360) | (UInt32(840) << 16))
            case 18:
                samplerStateBindCount += 1
                guard PhysicalBytes.readLE32(at: packet + 4) == 1,
                      PhysicalBytes.readLE32(at: packet + 8) == 0,
                      PhysicalBytes.readLE32(at: packet + 12) == 0x10d
                else {
                    return false
                }
            case 31:
                shaderBindCount += 1
                let handle = PhysicalBytes.readLE32(at: packet + 4)
                let stage = PhysicalBytes.readLE32(at: packet + 8)
                switch (handle, stage) {
                case (0x101, 0): shaderBindMask |= 1 << 0
                case (0x102, 1): shaderBindMask |= 1 << 1
                case (0x108, 0): shaderBindMask |= 1 << 2
                case (0x109, 1): shaderBindMask |= 1 << 3
                case (0x10a, 0): shaderBindMask |= 1 << 4
                case (0x10b, 1): shaderBindMask |= 1 << 5
                default: return false
                }
            default:
                break
            }
            offset += packetByteCount
        }
        return offset == commandByteCount
            && packetCount == 55
            && shaderBindCount == 6
            && shaderBindMask == 0x3f
            && framebufferCount == 2
            && clearCount == 1
            && scissorCount == 4
            && sawFullScissor
            && sawLogicalScissor
            && sawTextScissor
            && vertexBufferCount == 2
            && drawCount == 12
            && samplerViewBindCount == 1
            && samplerStateBindCount == 1
    }

    private func subsequentRenderCommandStreamIsValid(
        at address: UInt64,
        requestByteCount: UInt32
    ) -> Bool {
        guard PhysicalBytes.readLE32(at: address + 16) == 1,
              requestByteCount == 132,
              PhysicalBytes.readLE32(at: address + 24) == 100
        else {
            return false
        }
        let stream = address + 32
        return PhysicalBytes.readLE32(at: stream) == 0x0003_0005
            && PhysicalBytes.readLE32(at: stream + 12) == 0x100
            && PhysicalBytes.readLE32(at: stream + 64) == 0x0008_0007
    }

    private func rectangleIsFullDisplay(at address: UInt64) -> Bool {
        PhysicalBytes.readLE32(at: address) == 0
            && PhysicalBytes.readLE32(at: address + 4) == 0
            && PhysicalBytes.readLE32(at: address + 8) == 1_920
            && PhysicalBytes.readLE32(at: address + 12) == 1_080
    }

    private func writeResponse(
        at address: UInt64,
        capacity: UInt32,
        requestAddress: UInt64,
        step: Int
    ) -> UInt32 {
        guard PhysicalBytes.zero(
                  address: address,
                  byteCount: UInt64(capacity)
              )
        else {
            return 0
        }
        var fence = PhysicalBytes.readLE64(at: requestAddress + 8)
        if behavior == .wrongFenceAt(step: step) { fence &+= 1 }

        let responseType: UInt32
        let byteCount: UInt32
        switch step {
        case 0:
            responseType = VirtIOGPUControlType.responseOKDisplayInfo
            byteCount = 408
        case 1:
            responseType = VirtIOGPU3DControlType.responseOKCapsetInfo
            byteCount = 40
        case 2:
            responseType = VirtIOGPU3DControlType.responseOKCapsetInfo
            byteCount = 40
        case 3:
            responseType = VirtIOGPU3DControlType.responseOKCapset
            byteCount = 1_400
        default:
            responseType = VirtIOGPU3DControlType.responseOKNoData
            byteCount = 24
        }
        guard byteCount <= capacity else { return 0 }
        VirtIOGPUProtocol.writeHeader(
            type: responseType,
            fenceID: fence,
            at: address
        )

        switch step {
        case 0:
            let mode = address + 24
            PhysicalBytes.writeLE32(1_920, at: mode + 8)
            PhysicalBytes.writeLE32(1_080, at: mode + 12)
            PhysicalBytes.writeLE32(
                behavior == .noEnabledScanout ? 0 : 1,
                at: mode + 16
            )
        case 1:
            // Unknown but valid extension: the session must count and ignore
            // it while continuing bounded enumeration.
            PhysicalBytes.writeLE32(0x80, at: address + 24)
            PhysicalBytes.writeLE32(7, at: address + 28)
            PhysicalBytes.writeLE32(64, at: address + 32)
        case 2:
            PhysicalBytes.writeLE32(2, at: address + 24)
            PhysicalBytes.writeLE32(2, at: address + 28)
            PhysicalBytes.writeLE32(1_376, at: address + 32)
        case 3:
            writeValidVirGL2Capabilities(at: address + 24)
        default:
            break
        }
        return byteCount
    }

    private func writeValidVirGL2Capabilities(at address: UInt64) {
        PhysicalBytes.writeLE32(2, at: address)
        PhysicalBytes.writeLE32(1, at: address + 3 * 4)
        PhysicalBytes.writeLE32(1 << 2, at: address + 17 * 4)
        PhysicalBytes.writeLE32(1 << 4, at: address + 20 * 4)
        PhysicalBytes.writeLE32(120, at: address + 66 * 4)
        PhysicalBytes.writeLE32(8, at: address + 70 * 4)
        PhysicalBytes.writeLE32(1 << 4, at: address + 72 * 4)
        PhysicalBytes.writeLE32(8_192, at: address + 121 * 4)
        PhysicalBytes.writeLE32(1 << 2, at: address + 156 * 4)
        PhysicalBytes.writeLE32(1 << 4, at: address + 159 * 4)
    }
}

@main
struct VirtIOGPU3DSessionTests {
    static func main() {
        testGPURetainedDesktopCrossing()
        testFeatureAndMemoryRejections()
        testTransportFailureIsExact()
        testFencedResponseIsRequired()
        testEnabledScanoutIsRequired()
        testReusableFrameSubmission()
        print("VirtIO-GPU 3D session host tests: 6 groups passed")
    }

    private static func testGPURetainedDesktopCrossing() {
        withMappings { command, request, response, queue in
            var session = makeSession(
                command: command,
                request: request,
                response: response,
                queue: queue,
                behavior: .normal
            )
            let result = session.configureAndRenderDesktop()
            guard case .configured(let configured) = result else {
                fatalError("valid retained GPU desktop failed: \(result)")
            }
            expect(configured.scanoutID == 0, "wrong scanout selected")
            expect(
                configured.width == 1_920 && configured.height == 1_080,
                "display mode was not preserved"
            )
            expect(
                configured.contextID == 1
                    && configured.resourceID == 1
                    && configured.unitQuadResourceID == 2
                    && configured.glyphAtlasResourceID == 3
                    && configured.colorSurfaceHandle == 0x100,
                "nonzero object identifiers were not preserved"
            )
            expect(
                configured.capabilities.capset.kind == .virgl2,
                "VIRGL2 capset was not selected"
            )
            expect(
                configured.completionFenceID == 18,
                "dependent operation did not complete on the eighteenth fence"
            )
            expect(session.isConfigured, "configured state was not published")
            expect(
                session.configureAndRenderDesktop()
                    == .failed(.alreadyConfigured),
                "configured session accepted a second bootstrap"
            )
        }
    }

    private static func testFeatureAndMemoryRejections() {
        withMappings { command, request, response, queue in
            var missingFeature = makeSession(
                command: command,
                request: request,
                response: response,
                queue: queue,
                behavior: .normal,
                negotiatedFeatures: 0
            )
            expect(
                missingFeature.configureAndRenderDesktop()
                    == .failed(.invalidNegotiatedFeatures),
                "session accepted a transport without VIRGL"
            )

            var overlapping = makeSession(
                command: request,
                request: request,
                response: response,
                queue: queue,
                behavior: .normal
            )
            expect(
                overlapping.configureAndRenderDesktop()
                    == .failed(.invalidMemoryLayout),
                "session accepted aliased command and request arenas"
            )
        }
    }

    private static func testTransportFailureIsExact() {
        withMappings { command, request, response, queue in
            var session = makeSession(
                command: command,
                request: request,
                response: response,
                queue: queue,
                behavior: .timeoutAt(step: 11)
            )
            expect(
                session.configureAndRenderDesktop()
                    == .failed(.transport(.timedOut)),
                "unit-quad SUBMIT_3D timeout lost its transport error"
            )
            expect(!session.isConfigured, "failed session was published")
        }
    }

    private static func testFencedResponseIsRequired() {
        withMappings { command, request, response, queue in
            var session = makeSession(
                command: command,
                request: request,
                response: response,
                queue: queue,
                behavior: .wrongFenceAt(step: 17)
            )
            expect(
                session.configureAndRenderDesktop()
                    == .failed(.malformedResponse(
                        commandType: VirtIOGPUControlType.resourceFlush
                    )),
                "flush accepted a response for the wrong fence"
            )
            expect(!session.isConfigured, "unflushed session was published")
        }
    }

    private static func testEnabledScanoutIsRequired() {
        withMappings { command, request, response, queue in
            var session = makeSession(
                command: command,
                request: request,
                response: response,
                queue: queue,
                behavior: .noEnabledScanout
            )
            expect(
                session.configureAndRenderDesktop()
                    == .failed(.noEnabledScanout),
                "disabled display was selected for scanout"
            )
        }
    }

    private static func testReusableFrameSubmission() {
        withMappings { command, request, response, queue in
            var session = makeSession(
                command: command,
                request: request,
                response: response,
                queue: queue,
                behavior: .normal
            )
            guard case .configured = session.configureAndRenderDesktop(),
                  let target = GPURenderTargetID(rawValue: 1),
                  let extent = GPUPixelExtent(width: 1_920, height: 1_080),
                  let commandID = GPUCommandBufferID(rawValue: 2),
                  var recorder = GPUCommandRecorder(id: commandID, capacity: 2)
            else {
                fatalError("reusable session bootstrap")
            }
            let pass = GPURenderPassDescriptor(
                target: target,
                extent: extent,
                format: .bgra8UNormSRGB,
                loadAction: .clear(.opaqueBlack),
                storeAction: .store
            )
            expect(
                recorder.record(.beginRenderPass(pass)) == .recorded(index: 0),
                "record reusable frame pass"
            )
            expect(
                recorder.record(.endRenderPass) == .recorded(index: 1),
                "record reusable frame end"
            )
            guard case .sealed(let frame) = recorder.seal() else {
                fatalError("seal reusable frame")
            }
            expect(
                session.render(frame)
                    == .presented(completionFenceID: 20),
                "reusable GPU frame was not submitted and flushed"
            )
            expect(session.isConfigured, "successful frame invalidated session")
        }
    }

    private static func makeSession(
        command: DMAMapping,
        request: DMAMapping,
        response: DMAMapping,
        queue: DMAMapping,
        behavior: VirtIOMMIOTransport.Behavior,
        negotiatedFeatures: UInt64 = 1 | (1 << 4)
    ) -> VirtIOGPU3DSession {
        guard let configuration = VirtIOGPUDeviceConfiguration(
                  pendingEvents: 0,
                  scanoutCount: 1,
                  capsetCount: 2
              )
        else {
            fatalError("test configuration was rejected")
        }
        return VirtIOGPU3DSession(
            transport: VirtIOMMIOTransport(
                negotiatedFeatures: negotiatedFeatures,
                configuration: configuration,
                behavior: behavior
            ),
            commandArenaMapping: command,
            requestMapping: request,
            responseMapping: response,
            protectedQueueMapping: queue
        )
    }

    private static func withMappings(
        _ body: (DMAMapping, DMAMapping, DMAMapping, DMAMapping) -> Void
    ) {
        let command = UnsafeMutableRawPointer.allocate(
            byteCount: 4_096,
            alignment: 4_096
        )
        let request = UnsafeMutableRawPointer.allocate(
            byteCount: 4_096,
            alignment: 4_096
        )
        let response = UnsafeMutableRawPointer.allocate(
            byteCount: 4_096,
            alignment: 4_096
        )
        let queue = UnsafeMutableRawPointer.allocate(
            byteCount: 4_096,
            alignment: 4_096
        )
        defer {
            command.deallocate()
            request.deallocate()
            response.deallocate()
            queue.deallocate()
        }
        guard let commandMapping = mapping(for: command, byteCount: 4_096),
              let requestMapping = mapping(for: request, byteCount: 4_096),
              let responseMapping = mapping(for: response, byteCount: 4_096),
              let queueMapping = mapping(for: queue, byteCount: 4_096)
        else {
            fatalError("test DMA mapping was rejected")
        }
        body(
            commandMapping,
            requestMapping,
            responseMapping,
            queueMapping
        )
    }

    private static func mapping(
        for pointer: UnsafeMutableRawPointer,
        byteCount: UInt64
    ) -> DMAMapping? {
        let address = UInt64(UInt(bitPattern: pointer))
        return DMAMapping(
            cpuPhysicalAddress: address,
            deviceAddress: address,
            byteCount: byteCount,
            deviceAddressWidth: .bits64,
            coherency: .hardwareCoherent
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
