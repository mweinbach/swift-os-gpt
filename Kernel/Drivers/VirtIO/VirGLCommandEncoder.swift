// Allocation-free encoder for the VirGL context command stream carried by a
// VirtIO-GPU SUBMIT_3D request.
//
// Wire layout source (protocol definitions, not implementation code):
// https://android.googlesource.com/platform/external/virglrenderer/+/b15ac6f9cbcd64c47015d745c3124fd66fb9bc72/src/virgl_protocol.h
// Capability-bit source:
// https://android.googlesource.com/platform/external/virglrenderer/+/b15ac6f9cbcd64c47015d745c3124fd66fb9bc72/src/virgl_hw.h
//
// This layer only serializes validated packets. It does not interpret TGSI,
// allocate GPU resources, submit a VirtIO request, or claim rendered output.

enum VirGLCommand: UInt8 {
    case nop = 0
    case createObject = 1
    case bindObject = 2
    case destroyObject = 3
    case setViewportState = 4
    case setFramebufferState = 5
    case setVertexBuffers = 6
    case clear = 7
    case drawVBO = 8
    case resourceInlineWrite = 9
    case setSamplerViews = 10
    case setIndexBuffer = 11
    case setConstantBuffer = 12
    case setStencilReference = 13
    case setBlendColor = 14
    case setScissorState = 15
    case bindShader = 31
    case clearTexture = 47
    case linkShader = 52
}

enum VirGLObjectType: UInt8 {
    case null = 0
    case blend = 1
    case rasterizer = 2
    case depthStencilAlpha = 3
    case shader = 4
    case vertexElements = 5
    case samplerView = 6
    case samplerState = 7
    case surface = 8
    case query = 9
    case streamOutputTarget = 10
    case multisampleSurface = 11
}

enum VirGLShaderStage: UInt32 {
    case vertex = 0
    case fragment = 1
    case geometry = 2
    case tessellationControl = 3
    case tessellationEvaluation = 4
    case compute = 5
}

enum VirGLPrimitiveTopology: UInt32 {
    case points = 0
    case lines = 1
    case lineLoop = 2
    case lineStrip = 3
    case triangles = 4
    case triangleStrip = 5
    case triangleFan = 6
    case quads = 7
    case quadStrip = 8
    case polygon = 9
    case linesAdjacency = 10
    case lineStripAdjacency = 11
    case trianglesAdjacency = 12
    case triangleStripAdjacency = 13
    case patches = 14
}

enum VirGLEncodeRejection: Equatable {
    case invalidObjectType
    case invalidObjectHandle
    case invalidResourceHandle
    case invalidFormat
    case invalidCount
    case invalidState
    case invalidSurfaceView
    case invalidShaderFragment
    case invalidDataSize
    case unsupportedCapability
    case payloadTooLarge
    case capacityExhausted
}

/// The legacy clear-texture command is legal only for a VIRGL2 capset whose
/// returned `virgl_caps_v2.capability_bits` contains VIRGL_CAP_CLEAR_TEXTURE.
/// Public virglrenderer exposes VIRGL2 versions 0, 1, and 2 with the same v2
/// layout. Unknown later versions stay disabled until their layout is checked.
struct VirGLContextCapabilities: Equatable {
    static let virgl2CapsetID: UInt32 = 2
    static let maximumKnownVirGL2Version: UInt32 = 2
    static let clearTextureBit: UInt32 = 1 << 30
    static let separateShaderObjectsBit: UInt32 = 1 << 9

    let capsetID: UInt32
    let capsetVersion: UInt32
    let capabilityBits: UInt32
    let capabilityBitsV2: UInt32

    var supportsExplicitShaderBinding: Bool {
        capsetID == Self.virgl2CapsetID
            && capsetVersion <= Self.maximumKnownVirGL2Version
    }

    var supportsClearTexture: Bool {
        supportsExplicitShaderBinding
            && capabilityBits & Self.clearTextureBit != 0
    }

    var supportsShaderLink: Bool {
        supportsExplicitShaderBinding
            && capabilityBitsV2 & Self.separateShaderObjectsBit != 0
    }
}

enum VirGLEncodeResult: Equatable {
    case encoded(startDWord: Int, dwordCount: Int)
    case rejected(VirGLEncodeRejection)
}

enum VirGLWire {
    static let maximumPayloadDWordCount = Int(UInt16.max)
    static let maximumColorAttachmentCount = 8
    static let maximumShaderByteCount: UInt32 = 0x7fff_ffff

    static func packetHeader(
        command: VirGLCommand,
        objectType: VirGLObjectType = .null,
        payloadDWordCount: Int
    ) -> UInt32? {
        guard payloadDWordCount >= 0,
              payloadDWordCount <= maximumPayloadDWordCount
        else {
            return nil
        }
        return UInt32(command.rawValue)
            | (UInt32(objectType.rawValue) << 8)
            | (UInt32(payloadDWordCount) << 16)
    }
}

struct VirGLViewport: Equatable {
    let scaleXBits: UInt32
    let scaleYBits: UInt32
    let scaleZBits: UInt32
    let translateXBits: UInt32
    let translateYBits: UInt32
    let translateZBits: UInt32
}

struct VirGLScissorRectangle: Equatable {
    let minimumX: UInt16
    let minimumY: UInt16
    let maximumX: UInt16
    let maximumY: UInt16

    init?(
        minimumX: UInt32,
        minimumY: UInt32,
        maximumX: UInt32,
        maximumY: UInt32
    ) {
        guard minimumX <= maximumX,
              minimumY <= maximumY,
              maximumX <= UInt32(UInt16.max),
              maximumY <= UInt32(UInt16.max)
        else {
            return nil
        }
        self.minimumX = UInt16(minimumX)
        self.minimumY = UInt16(minimumY)
        self.maximumX = UInt16(maximumX)
        self.maximumY = UInt16(maximumY)
    }

    var packedMinimum: UInt32 {
        UInt32(minimumX) | (UInt32(minimumY) << 16)
    }

    var packedMaximum: UInt32 {
        UInt32(maximumX) | (UInt32(maximumY) << 16)
    }
}

enum VirGLSurfaceView: Equatable {
    case buffer(firstElement: UInt32, lastElement: UInt32)
    case texture(level: UInt32, firstLayer: UInt32, lastLayer: UInt32)
}

struct VirGLBlendGlobalState: Equatable {
    static let knownFlagMask: UInt32 = 0x1f

    let flags: UInt32
    let logicOperation: UInt8

    init?(flags: UInt32, logicOperation: UInt8) {
        guard flags & ~Self.knownFlagMask == 0, logicOperation <= 0x0f else {
            return nil
        }
        self.flags = flags
        self.logicOperation = logicOperation
    }
}

struct VirGLBlendTargetState: Equatable {
    let blendEnabled: Bool
    let rgbFunction: UInt8
    let rgbSourceFactor: UInt8
    let rgbDestinationFactor: UInt8
    let alphaFunction: UInt8
    let alphaSourceFactor: UInt8
    let alphaDestinationFactor: UInt8
    let colorMask: UInt8

    init?(
        blendEnabled: Bool,
        rgbFunction: UInt8,
        rgbSourceFactor: UInt8,
        rgbDestinationFactor: UInt8,
        alphaFunction: UInt8,
        alphaSourceFactor: UInt8,
        alphaDestinationFactor: UInt8,
        colorMask: UInt8
    ) {
        guard rgbFunction <= 0x07,
              rgbSourceFactor <= 0x1f,
              rgbDestinationFactor <= 0x1f,
              alphaFunction <= 0x07,
              alphaSourceFactor <= 0x1f,
              alphaDestinationFactor <= 0x1f,
              colorMask <= 0x0f
        else {
            return nil
        }
        self.blendEnabled = blendEnabled
        self.rgbFunction = rgbFunction
        self.rgbSourceFactor = rgbSourceFactor
        self.rgbDestinationFactor = rgbDestinationFactor
        self.alphaFunction = alphaFunction
        self.alphaSourceFactor = alphaSourceFactor
        self.alphaDestinationFactor = alphaDestinationFactor
        self.colorMask = colorMask
    }

    var packedDWord: UInt32 {
        (blendEnabled ? 1 : 0)
            | (UInt32(rgbFunction) << 1)
            | (UInt32(rgbSourceFactor) << 4)
            | (UInt32(rgbDestinationFactor) << 9)
            | (UInt32(alphaFunction) << 14)
            | (UInt32(alphaSourceFactor) << 17)
            | (UInt32(alphaDestinationFactor) << 22)
            | (UInt32(colorMask) << 27)
    }
}

struct VirGLDepthStencilAlphaState: Equatable {
    static let knownDepthAlphaMask: UInt32 = 0x0000_0f1f
    static let knownStencilMask: UInt32 = 0x1fff_ffff

    let depthAlphaDWord: UInt32
    let frontStencilDWord: UInt32
    let backStencilDWord: UInt32
    let alphaReferenceBits: UInt32

    init?(
        depthAlphaDWord: UInt32,
        frontStencilDWord: UInt32,
        backStencilDWord: UInt32,
        alphaReferenceBits: UInt32
    ) {
        guard depthAlphaDWord & ~Self.knownDepthAlphaMask == 0,
              frontStencilDWord & ~Self.knownStencilMask == 0,
              backStencilDWord & ~Self.knownStencilMask == 0
        else {
            return nil
        }
        self.depthAlphaDWord = depthAlphaDWord
        self.frontStencilDWord = frontStencilDWord
        self.backStencilDWord = backStencilDWord
        self.alphaReferenceBits = alphaReferenceBits
    }
}

struct VirGLRasterizerState: Equatable {
    let flags: UInt32
    let pointSizeBits: UInt32
    let spriteCoordinateEnableMask: UInt32
    let lineAndClipState: UInt32
    let lineWidthBits: UInt32
    let offsetUnitsBits: UInt32
    let offsetScaleBits: UInt32
    let offsetClampBits: UInt32
}

struct VirGLVertexBuffer: Equatable {
    let stride: UInt32
    let offset: UInt32
    let resourceHandle: UInt32
}

struct VirGLVertexElement: Equatable {
    let sourceOffset: UInt32
    let instanceDivisor: UInt32
    let vertexBufferIndex: UInt32
    let sourceFormat: UInt32
}

struct VirGLClearValue: Equatable {
    static let knownBufferMask: UInt32 = 0x0000_03ff

    let bufferMask: UInt32
    let color0Bits: UInt32
    let color1Bits: UInt32
    let color2Bits: UInt32
    let color3Bits: UInt32
    let depthBits: UInt64
    let stencil: UInt32

    init?(
        bufferMask: UInt32,
        color0Bits: UInt32,
        color1Bits: UInt32,
        color2Bits: UInt32,
        color3Bits: UInt32,
        depthBits: UInt64,
        stencil: UInt32
    ) {
        guard bufferMask != 0,
              bufferMask & ~Self.knownBufferMask == 0
        else {
            return nil
        }
        self.bufferMask = bufferMask
        self.color0Bits = color0Bits
        self.color1Bits = color1Bits
        self.color2Bits = color2Bits
        self.color3Bits = color3Bits
        self.depthBits = depthBits
        self.stencil = stencil
    }
}

struct VirGLTextureBox: Equatable {
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
        guard width != 0, height != 0, depth != 0 else { return nil }
        let endX = x.addingReportingOverflow(width)
        let endY = y.addingReportingOverflow(height)
        let endZ = z.addingReportingOverflow(depth)
        guard !endX.overflow, !endY.overflow, !endZ.overflow else {
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

/// Format geometry used only to prove that inline data exactly covers its
/// transfer box. These values are not serialized; they come from the already
/// validated resource format. A byte-addressed vertex buffer uses 1/1/1.
struct VirGLTransferBlockLayout: Equatable {
    let blockWidth: UInt32
    let blockHeight: UInt32
    let blockDepth: UInt32
    let bytesPerBlock: UInt32

    init?(
        blockWidth: UInt32,
        blockHeight: UInt32,
        blockDepth: UInt32 = 1,
        bytesPerBlock: UInt32
    ) {
        guard blockWidth != 0,
              blockHeight != 0,
              blockDepth != 0,
              bytesPerBlock != 0
        else {
            return nil
        }
        self.blockWidth = blockWidth
        self.blockHeight = blockHeight
        self.blockDepth = blockDepth
        self.bytesPerBlock = bytesPerBlock
    }
}

/// Exactly 16 bytes, as required by VIRGL_CLEAR_TEXTURE_SIZE. Interpretation
/// is determined by the destination resource's negotiated format.
struct VirGLClearTextureValue: Equatable {
    let word0: UInt32
    let word1: UInt32
    let word2: UInt32
    let word3: UInt32
}

struct VirGLDrawDescriptor: Equatable {
    let start: UInt32
    let count: UInt32
    let topology: VirGLPrimitiveTopology
    let indexed: Bool
    let instanceCount: UInt32
    let indexBias: Int32
    let startInstance: UInt32
    let primitiveRestartEnabled: Bool
    let restartIndex: UInt32
    let minimumIndex: UInt32
    let maximumIndex: UInt32
    let countFromStreamOutputHandle: UInt32?
}

/// Six shader slots in exact VIRGL_LINK_SHADER payload order. A program is
/// either compute-only or a graphics pipeline containing vertex and fragment
/// stages. A tessellation-control shader cannot exist without evaluation.
struct VirGLShaderProgramHandles: Equatable {
    let vertex: UInt32
    let fragment: UInt32
    let geometry: UInt32
    let tessellationControl: UInt32
    let tessellationEvaluation: UInt32
    let compute: UInt32

    init?(
        vertex: UInt32 = 0,
        fragment: UInt32 = 0,
        geometry: UInt32 = 0,
        tessellationControl: UInt32 = 0,
        tessellationEvaluation: UInt32 = 0,
        compute: UInt32 = 0
    ) {
        let graphicsHandlePresent = vertex != 0
            || fragment != 0
            || geometry != 0
            || tessellationControl != 0
            || tessellationEvaluation != 0
        let isCompute = compute != 0 && !graphicsHandlePresent
        let isGraphics = compute == 0
            && vertex != 0
            && fragment != 0
            && (tessellationControl == 0 || tessellationEvaluation != 0)
        guard isCompute || isGraphics else { return nil }
        self.vertex = vertex
        self.fragment = fragment
        self.geometry = geometry
        self.tessellationControl = tessellationControl
        self.tessellationEvaluation = tessellationEvaluation
        self.compute = compute
    }
}

private enum VirGLPacketReservation {
    case ready(startDWord: Int)
    case rejected(VirGLEncodeRejection)
}

/// A cursor over caller-owned command memory. Copying this value aliases the
/// storage, so one mutable owner must serialize access to a given arena.
struct VirGLDWordArena {
    private let storage: UnsafeMutableBufferPointer<UInt32>
    private(set) var dwordCount: Int = 0

    init?(storage: UnsafeMutableBufferPointer<UInt32>) {
        guard storage.count > 0, storage.baseAddress != nil else { return nil }
        self.storage = storage
    }

    var capacity: Int { storage.count }
    var remainingCapacity: Int { capacity - dwordCount }

    mutating func reset() {
        dwordCount = 0
    }

    func dword(at index: Int) -> UInt32? {
        guard index >= 0, index < dwordCount else { return nil }
        return UInt32(littleEndian: storage[index])
    }

    mutating func encodeCreateObject(
        type: VirGLObjectType,
        handle: UInt32,
        stateDWords: UnsafeBufferPointer<UInt32>
    ) -> VirGLEncodeResult {
        guard type != .null else {
            return .rejected(.invalidObjectType)
        }
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        guard let payloadCount = Self.checkedAdd(1, stateDWords.count) else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .createObject,
            objectType: type,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle)
        var index = 0
        while index < stateDWords.count {
            appendUnchecked(stateDWords[index])
            index += 1
        }
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    /// A nil handle is an explicit unbind. A present handle must be nonzero.
    mutating func encodeBindObject(
        type: VirGLObjectType,
        handle: UInt32?
    ) -> VirGLEncodeResult {
        guard type != .null else {
            return .rejected(.invalidObjectType)
        }
        if let handle, handle == 0 {
            return .rejected(.invalidObjectHandle)
        }
        let reservation = reservePacket(
            command: .bindObject,
            objectType: type,
            payloadDWordCount: 1
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle ?? 0)
        return .encoded(startDWord: start, dwordCount: 2)
    }

    mutating func encodeDestroyObject(
        type: VirGLObjectType,
        handle: UInt32
    ) -> VirGLEncodeResult {
        guard type != .null else {
            return .rejected(.invalidObjectType)
        }
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        let reservation = reservePacket(
            command: .destroyObject,
            objectType: type,
            payloadDWordCount: 1
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle)
        return .encoded(startDWord: start, dwordCount: 2)
    }

    mutating func encodeCreateSurface(
        handle: UInt32,
        resourceHandle: UInt32,
        format: UInt32,
        view: VirGLSurfaceView
    ) -> VirGLEncodeResult {
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        guard resourceHandle != 0 else {
            return .rejected(.invalidResourceHandle)
        }
        guard format != 0 else { return .rejected(.invalidFormat) }

        let word3: UInt32
        let word4: UInt32
        switch view {
        case .buffer(let firstElement, let lastElement):
            guard firstElement <= lastElement else {
                return .rejected(.invalidSurfaceView)
            }
            word3 = firstElement
            word4 = lastElement
        case .texture(let level, let firstLayer, let lastLayer):
            guard firstLayer <= lastLayer,
                  lastLayer <= UInt32(UInt16.max)
            else {
                return .rejected(.invalidSurfaceView)
            }
            word3 = level
            word4 = firstLayer | (lastLayer << 16)
        }

        let reservation = reservePacket(
            command: .createObject,
            objectType: .surface,
            payloadDWordCount: 5
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle)
        appendUnchecked(resourceHandle)
        appendUnchecked(format)
        appendUnchecked(word3)
        appendUnchecked(word4)
        return .encoded(startDWord: start, dwordCount: 6)
    }

    mutating func encodeSetFramebuffer(
        colorSurfaceHandles: UnsafeBufferPointer<UInt32>,
        depthStencilSurfaceHandle: UInt32?
    ) -> VirGLEncodeResult {
        guard colorSurfaceHandles.count <= VirGLWire.maximumColorAttachmentCount
        else {
            return .rejected(.invalidCount)
        }
        if let depthStencilSurfaceHandle,
           depthStencilSurfaceHandle == 0 {
            return .rejected(.invalidObjectHandle)
        }
        guard let payloadCount = Self.checkedAdd(
            2,
            colorSurfaceHandles.count
        ) else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .setFramebufferState,
            objectType: .null,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(UInt32(colorSurfaceHandles.count))
        appendUnchecked(depthStencilSurfaceHandle ?? 0)
        var index = 0
        while index < colorSurfaceHandles.count {
            appendUnchecked(colorSurfaceHandles[index])
            index += 1
        }
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    mutating func encodeSetViewports(
        startSlot: UInt32,
        viewports: UnsafeBufferPointer<VirGLViewport>
    ) -> VirGLEncodeResult {
        guard viewports.count > 0 else {
            return .rejected(.invalidCount)
        }
        guard let viewportWords = Self.checkedMultiply(viewports.count, 6),
              let payloadCount = Self.checkedAdd(1, viewportWords)
        else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .setViewportState,
            objectType: .null,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(startSlot)
        var index = 0
        while index < viewports.count {
            let viewport = viewports[index]
            appendUnchecked(viewport.scaleXBits)
            appendUnchecked(viewport.scaleYBits)
            appendUnchecked(viewport.scaleZBits)
            appendUnchecked(viewport.translateXBits)
            appendUnchecked(viewport.translateYBits)
            appendUnchecked(viewport.translateZBits)
            index += 1
        }
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    mutating func encodeSetScissors(
        startSlot: UInt32,
        scissors: UnsafeBufferPointer<VirGLScissorRectangle>
    ) -> VirGLEncodeResult {
        guard scissors.count > 0 else {
            return .rejected(.invalidCount)
        }
        guard let scissorWords = Self.checkedMultiply(scissors.count, 2),
              let payloadCount = Self.checkedAdd(1, scissorWords)
        else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .setScissorState,
            objectType: .null,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(startSlot)
        var index = 0
        while index < scissors.count {
            appendUnchecked(scissors[index].packedMinimum)
            appendUnchecked(scissors[index].packedMaximum)
            index += 1
        }
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    mutating func encodeClear(_ value: VirGLClearValue) -> VirGLEncodeResult {
        let reservation = reservePacket(
            command: .clear,
            objectType: .null,
            payloadDWordCount: 8
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(value.bufferMask)
        appendUnchecked(value.color0Bits)
        appendUnchecked(value.color1Bits)
        appendUnchecked(value.color2Bits)
        appendUnchecked(value.color3Bits)
        appendUnchecked(UInt32(truncatingIfNeeded: value.depthBits))
        appendUnchecked(UInt32(truncatingIfNeeded: value.depthBits >> 32))
        appendUnchecked(value.stencil)
        return .encoded(startDWord: start, dwordCount: 9)
    }

    mutating func encodeClearTexture(
        capabilities: VirGLContextCapabilities,
        resourceHandle: UInt32,
        level: UInt32,
        box: VirGLTextureBox,
        value: VirGLClearTextureValue
    ) -> VirGLEncodeResult {
        guard capabilities.supportsClearTexture else {
            return .rejected(.unsupportedCapability)
        }
        guard resourceHandle != 0 else {
            return .rejected(.invalidResourceHandle)
        }
        let reservation = reservePacket(
            command: .clearTexture,
            objectType: .null,
            payloadDWordCount: 12
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(resourceHandle)
        appendUnchecked(level)
        appendUnchecked(box.x)
        appendUnchecked(box.y)
        appendUnchecked(box.z)
        appendUnchecked(box.width)
        appendUnchecked(box.height)
        appendUnchecked(box.depth)
        appendUnchecked(value.word0)
        appendUnchecked(value.word1)
        appendUnchecked(value.word2)
        appendUnchecked(value.word3)
        return .encoded(startDWord: start, dwordCount: 13)
    }

    /// Uploads bytes inline with the command stream. The caller supplies the
    /// resource format's block geometry so stride, layer stride, box extent,
    /// and the opaque byte count can be checked before any dword is written.
    mutating func encodeResourceInlineWrite(
        resourceHandle: UInt32,
        level: UInt32,
        usage: UInt32,
        stride: UInt32,
        layerStride: UInt32,
        box: VirGLTextureBox,
        blockLayout: VirGLTransferBlockLayout,
        bytes: UnsafeRawBufferPointer
    ) -> VirGLEncodeResult {
        guard resourceHandle != 0 else {
            return .rejected(.invalidResourceHandle)
        }
        guard bytes.count > 0, bytes.baseAddress != nil else {
            return .rejected(.invalidDataSize)
        }
        guard let expectedByteCount = Self.expectedInlineByteCount(
            box: box,
            blockLayout: blockLayout,
            stride: stride,
            layerStride: layerStride
        ), expectedByteCount == bytes.count else {
            return .rejected(.invalidDataSize)
        }
        guard let dataDWordCount = Self.paddedDWordCount(
            forByteCount: bytes.count
        ), let payloadCount = Self.checkedAdd(11, dataDWordCount) else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .resourceInlineWrite,
            objectType: .null,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(resourceHandle)
        appendUnchecked(level)
        appendUnchecked(usage)
        appendUnchecked(stride)
        appendUnchecked(layerStride)
        appendUnchecked(box.x)
        appendUnchecked(box.y)
        appendUnchecked(box.z)
        appendUnchecked(box.width)
        appendUnchecked(box.height)
        appendUnchecked(box.depth)
        appendOpaqueBytesUnchecked(bytes)
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    mutating func encodeCreateBlendState(
        handle: UInt32,
        global: VirGLBlendGlobalState,
        targets: UnsafeBufferPointer<VirGLBlendTargetState>
    ) -> VirGLEncodeResult {
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        guard targets.count == VirGLWire.maximumColorAttachmentCount else {
            return .rejected(.invalidCount)
        }
        let reservation = reservePacket(
            command: .createObject,
            objectType: .blend,
            payloadDWordCount: 11
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle)
        appendUnchecked(global.flags)
        appendUnchecked(UInt32(global.logicOperation))
        var index = 0
        while index < targets.count {
            appendUnchecked(targets[index].packedDWord)
            index += 1
        }
        return .encoded(startDWord: start, dwordCount: 12)
    }

    mutating func encodeCreateRasterizerState(
        handle: UInt32,
        state: VirGLRasterizerState
    ) -> VirGLEncodeResult {
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        let reservation = reservePacket(
            command: .createObject,
            objectType: .rasterizer,
            payloadDWordCount: 9
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle)
        appendUnchecked(state.flags)
        appendUnchecked(state.pointSizeBits)
        appendUnchecked(state.spriteCoordinateEnableMask)
        appendUnchecked(state.lineAndClipState)
        appendUnchecked(state.lineWidthBits)
        appendUnchecked(state.offsetUnitsBits)
        appendUnchecked(state.offsetScaleBits)
        appendUnchecked(state.offsetClampBits)
        return .encoded(startDWord: start, dwordCount: 10)
    }

    mutating func encodeCreateDepthStencilAlphaState(
        handle: UInt32,
        state: VirGLDepthStencilAlphaState
    ) -> VirGLEncodeResult {
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        let reservation = reservePacket(
            command: .createObject,
            objectType: .depthStencilAlpha,
            payloadDWordCount: 5
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle)
        appendUnchecked(state.depthAlphaDWord)
        appendUnchecked(state.frontStencilDWord)
        appendUnchecked(state.backStencilDWord)
        appendUnchecked(state.alphaReferenceBits)
        return .encoded(startDWord: start, dwordCount: 6)
    }

    mutating func encodeSetVertexBuffers(
        _ buffers: UnsafeBufferPointer<VirGLVertexBuffer>
    ) -> VirGLEncodeResult {
        guard buffers.count > 0 else {
            return .rejected(.invalidCount)
        }
        var index = 0
        while index < buffers.count {
            guard buffers[index].resourceHandle != 0 else {
                return .rejected(.invalidResourceHandle)
            }
            index += 1
        }
        guard let payloadCount = Self.checkedMultiply(buffers.count, 3) else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .setVertexBuffers,
            objectType: .null,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        index = 0
        while index < buffers.count {
            let buffer = buffers[index]
            appendUnchecked(buffer.stride)
            appendUnchecked(buffer.offset)
            appendUnchecked(buffer.resourceHandle)
            index += 1
        }
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    mutating func encodeCreateVertexElements(
        handle: UInt32,
        elements: UnsafeBufferPointer<VirGLVertexElement>
    ) -> VirGLEncodeResult {
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        guard elements.count > 0 else {
            return .rejected(.invalidCount)
        }
        var index = 0
        while index < elements.count {
            guard elements[index].sourceFormat != 0 else {
                return .rejected(.invalidFormat)
            }
            index += 1
        }
        guard let elementWords = Self.checkedMultiply(elements.count, 4),
              let payloadCount = Self.checkedAdd(1, elementWords)
        else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .createObject,
            objectType: .vertexElements,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle)
        index = 0
        while index < elements.count {
            let element = elements[index]
            appendUnchecked(element.sourceOffset)
            appendUnchecked(element.instanceDivisor)
            appendUnchecked(element.vertexBufferIndex)
            appendUnchecked(element.sourceFormat)
            index += 1
        }
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    mutating func encodeSetConstantBuffer(
        stage: VirGLShaderStage,
        index: UInt32,
        dwords: UnsafeBufferPointer<UInt32>
    ) -> VirGLEncodeResult {
        guard let payloadCount = Self.checkedAdd(2, dwords.count) else {
            return .rejected(.payloadTooLarge)
        }
        let reservation = reservePacket(
            command: .setConstantBuffer,
            objectType: .null,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(stage.rawValue)
        appendUnchecked(index)
        var dwordIndex = 0
        while dwordIndex < dwords.count {
            appendUnchecked(dwords[dwordIndex])
            dwordIndex += 1
        }
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    /// Encodes one shader-object fragment. VirGL carries NUL-terminated TGSI
    /// text here; this encoder treats the text as opaque bytes. `tokenCount`
    /// is the decoder's TGSI parser token-capacity field, not a byte count.
    /// Offset zero emits the total byte length; later fragments set the
    /// continuation bit and emit their dword-aligned byte offset. Non-final
    /// fragments must end on a dword boundary and the final fragment must
    /// include its NUL terminator as its final byte. No terminator is added.
    mutating func encodeCreateShaderObjectFragment(
        handle: UInt32,
        stage: VirGLShaderStage,
        tokenCount: UInt32,
        totalByteCount: UInt32,
        fragmentOffset: UInt32,
        bytes: UnsafeRawBufferPointer
    ) -> VirGLEncodeResult {
        guard handle != 0 else {
            return .rejected(.invalidObjectHandle)
        }
        guard tokenCount != 0,
              totalByteCount != 0,
              totalByteCount <= VirGLWire.maximumShaderByteCount,
              bytes.count > 0,
              bytes.baseAddress != nil,
              bytes.count <= Int(VirGLWire.maximumShaderByteCount),
              fragmentOffset < totalByteCount
        else {
            return .rejected(.invalidShaderFragment)
        }
        let fragmentByteCount = UInt32(bytes.count)
        let end = fragmentOffset.addingReportingOverflow(fragmentByteCount)
        guard !end.overflow, end.partialValue <= totalByteCount else {
            return .rejected(.invalidShaderFragment)
        }
        guard let shaderDWords = Self.paddedDWordCount(
            forByteCount: bytes.count
        ) else {
            return .rejected(.payloadTooLarge)
        }
        guard let payloadCount = Self.checkedAdd(5, shaderDWords) else {
            return .rejected(.payloadTooLarge)
        }
        let roundedTotalDWords = (totalByteCount / 4)
            + (totalByteCount % 4 == 0 ? 0 : 1)
        let roundedFragmentByteCount = UInt32(shaderDWords) * 4
        let roundedEnd = fragmentOffset.addingReportingOverflow(
            roundedFragmentByteCount
        )
        let roundedTotalByteCount = roundedTotalDWords * 4
        guard fragmentOffset & 3 == 0,
              !roundedEnd.overflow,
              roundedEnd.partialValue <= roundedTotalByteCount
        else {
            return .rejected(.invalidShaderFragment)
        }
        if roundedEnd.partialValue == roundedTotalByteCount {
            guard end.partialValue == totalByteCount,
                  bytes[bytes.count - 1] == 0
            else {
                return .rejected(.invalidShaderFragment)
            }
        } else {
            guard bytes.count & 3 == 0 else {
                return .rejected(.invalidShaderFragment)
            }
        }
        let reservation = reservePacket(
            command: .createObject,
            objectType: .shader,
            payloadDWordCount: payloadCount
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }

        let offsetWord: UInt32
        if fragmentOffset == 0 {
            offsetWord = totalByteCount
        } else {
            offsetWord = fragmentOffset | 0x8000_0000
        }
        appendUnchecked(handle)
        appendUnchecked(stage.rawValue)
        appendUnchecked(offsetWord)
        appendUnchecked(tokenCount)
        appendUnchecked(0) // No stream-output declarations in this encoder.

        appendOpaqueBytesUnchecked(bytes)
        return .encoded(startDWord: start, dwordCount: payloadCount + 1)
    }

    /// Modern VirGL binds shader stages with VIRGL_CCMD_BIND_SHADER, not the
    /// generic object-binding packet. Nil is an explicit stage unbind.
    mutating func encodeBindShader(
        capabilities: VirGLContextCapabilities,
        stage: VirGLShaderStage,
        handle: UInt32?
    ) -> VirGLEncodeResult {
        guard capabilities.supportsExplicitShaderBinding else {
            return .rejected(.unsupportedCapability)
        }
        if let handle, handle == 0 {
            return .rejected(.invalidObjectHandle)
        }
        let reservation = reservePacket(
            command: .bindShader,
            objectType: .null,
            payloadDWordCount: 2
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(handle ?? 0)
        appendUnchecked(stage.rawValue)
        return .encoded(startDWord: start, dwordCount: 3)
    }

    /// Prelinks one complete program only when the VIRGL2 capset advertises
    /// VIRGL_CAP_V2_SSO. Handles are serialized in the protocol's six-stage
    /// order; zero denotes an absent stage.
    mutating func encodeLinkShader(
        capabilities: VirGLContextCapabilities,
        program: VirGLShaderProgramHandles
    ) -> VirGLEncodeResult {
        guard capabilities.supportsShaderLink else {
            return .rejected(.unsupportedCapability)
        }
        let reservation = reservePacket(
            command: .linkShader,
            objectType: .null,
            payloadDWordCount: 6
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(program.vertex)
        appendUnchecked(program.fragment)
        appendUnchecked(program.geometry)
        appendUnchecked(program.tessellationControl)
        appendUnchecked(program.tessellationEvaluation)
        appendUnchecked(program.compute)
        return .encoded(startDWord: start, dwordCount: 7)
    }

    mutating func encodeDrawVBO(
        _ draw: VirGLDrawDescriptor
    ) -> VirGLEncodeResult {
        if let handle = draw.countFromStreamOutputHandle, handle == 0 {
            return .rejected(.invalidObjectHandle)
        }
        let reservation = reservePacket(
            command: .drawVBO,
            objectType: .null,
            payloadDWordCount: 12
        )
        guard case .ready(let start) = reservation else {
            return Self.rejectionResult(reservation)
        }
        appendUnchecked(draw.start)
        appendUnchecked(draw.count)
        appendUnchecked(draw.topology.rawValue)
        appendUnchecked(draw.indexed ? 1 : 0)
        appendUnchecked(draw.instanceCount)
        appendUnchecked(UInt32(bitPattern: draw.indexBias))
        appendUnchecked(draw.startInstance)
        appendUnchecked(draw.primitiveRestartEnabled ? 1 : 0)
        appendUnchecked(draw.restartIndex)
        appendUnchecked(draw.minimumIndex)
        appendUnchecked(draw.maximumIndex)
        appendUnchecked(draw.countFromStreamOutputHandle ?? 0)
        return .encoded(startDWord: start, dwordCount: 13)
    }

    private mutating func reservePacket(
        command: VirGLCommand,
        objectType: VirGLObjectType,
        payloadDWordCount: Int
    ) -> VirGLPacketReservation {
        guard let header = VirGLWire.packetHeader(
            command: command,
            objectType: objectType,
            payloadDWordCount: payloadDWordCount
        ) else {
            return .rejected(.payloadTooLarge)
        }
        guard let totalDWordCount = Self.checkedAdd(
            payloadDWordCount,
            1
        ) else {
            return .rejected(.payloadTooLarge)
        }
        guard totalDWordCount <= remainingCapacity else {
            return .rejected(.capacityExhausted)
        }
        let start = dwordCount
        appendUnchecked(header)
        return .ready(startDWord: start)
    }

    private mutating func appendUnchecked(_ value: UInt32) {
        storage[dwordCount] = value.littleEndian
        dwordCount += 1
    }

    private mutating func appendOpaqueBytesUnchecked(
        _ bytes: UnsafeRawBufferPointer
    ) {
        var byteIndex = 0
        while byteIndex < bytes.count {
            var word: UInt32 = 0
            var lane = 0
            while lane < 4 && byteIndex < bytes.count {
                word |= UInt32(bytes[byteIndex]) << UInt32(lane * 8)
                byteIndex += 1
                lane += 1
            }
            appendUnchecked(word)
        }
    }

    private static func rejectionResult(
        _ reservation: VirGLPacketReservation
    ) -> VirGLEncodeResult {
        switch reservation {
        case .ready:
            return .rejected(.invalidState)
        case .rejected(let rejection):
            return .rejected(rejection)
        }
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    private static func paddedDWordCount(forByteCount byteCount: Int) -> Int? {
        let padded = byteCount.addingReportingOverflow(3)
        guard !padded.overflow else { return nil }
        return padded.partialValue / 4
    }

    private static func expectedInlineByteCount(
        box: VirGLTextureBox,
        blockLayout: VirGLTransferBlockLayout,
        stride: UInt32,
        layerStride: UInt32
    ) -> Int? {
        let blocksX = ceilDivide(box.width, by: blockLayout.blockWidth)
        let blocksY = ceilDivide(box.height, by: blockLayout.blockHeight)
        let blocksZ = ceilDivide(box.depth, by: blockLayout.blockDepth)

        let minimumRow = UInt64(blocksX).multipliedReportingOverflow(
            by: UInt64(blockLayout.bytesPerBlock)
        )
        guard !minimumRow.overflow else { return nil }
        let effectiveStride = stride == 0
            ? minimumRow.partialValue
            : UInt64(stride)
        guard effectiveStride >= minimumRow.partialValue else { return nil }

        let minimumLayer = effectiveStride.multipliedReportingOverflow(
            by: UInt64(blocksY)
        )
        guard !minimumLayer.overflow else { return nil }
        let effectiveLayerStride = layerStride == 0
            ? minimumLayer.partialValue
            : UInt64(layerStride)
        guard effectiveLayerStride >= minimumLayer.partialValue else {
            return nil
        }

        let total = effectiveLayerStride.multipliedReportingOverflow(
            by: UInt64(blocksZ)
        )
        guard !total.overflow,
              total.partialValue <= UInt64(Int.max)
        else {
            return nil
        }
        return Int(total.partialValue)
    }

    private static func ceilDivide(_ value: UInt32, by divisor: UInt32) -> UInt32 {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }
}
