// Allocation-free lowering from SwiftOS's device-neutral render IR to the
// VirGL context command stream. The compiler owns no GPU memory: callers own
// the command arena, render-target surface, and immutable unit-quad vertex
// resource. Every command buffer is validated and sized before encoding so a
// rejection never advances the caller's publishable arena cursor.

enum VirGLIRUnitQuadVertexLayout: Equatable {
    /// Six (x, y) float vertices forming two triangles in this order:
    /// (0,0), (1,0), (0,1), (0,1), (1,0), (1,1).
    case r32g32Float

    /// The same six positions stored as (x, y, 0, 1) float vectors.
    case r32g32b32a32Float

    var format: UInt32 {
        switch self {
        case .r32g32Float:
            return 29 // VIRGL_FORMAT_R32G32_FLOAT
        case .r32g32b32a32Float:
            return 31 // VIRGL_FORMAT_R32G32B32A32_FLOAT
        }
    }

    var stride: UInt32 {
        switch self {
        case .r32g32Float: return 8
        case .r32g32b32a32Float: return 16
        }
    }
}

/// Context-local object handles used by the solid-quad pipeline. Resource
/// handles live in a separate VirtIO-GPU namespace, but all object handles are
/// kept distinct so teardown and protocol traces remain unambiguous.
struct VirGLIRPipelineHandles: Equatable {
    let vertexShader: UInt32
    let fragmentShader: UInt32
    let vertexElements: UInt32
    let rasterizer: UInt32
    let depthStencilAlpha: UInt32
    let copyBlend: UInt32
    let sourceOverBlend: UInt32
    let unitQuadVertexResource: UInt32

    init?(
        vertexShader: UInt32,
        fragmentShader: UInt32,
        vertexElements: UInt32,
        rasterizer: UInt32,
        depthStencilAlpha: UInt32,
        copyBlend: UInt32,
        sourceOverBlend: UInt32,
        unitQuadVertexResource: UInt32
    ) {
        guard vertexShader != 0,
              fragmentShader != 0,
              vertexElements != 0,
              rasterizer != 0,
              depthStencilAlpha != 0,
              copyBlend != 0,
              sourceOverBlend != 0,
              unitQuadVertexResource != 0,
              Self.areDistinct(
                  vertexShader,
                  fragmentShader,
                  vertexElements,
                  rasterizer,
                  depthStencilAlpha,
                  copyBlend,
                  sourceOverBlend
              )
        else {
            return nil
        }
        self.vertexShader = vertexShader
        self.fragmentShader = fragmentShader
        self.vertexElements = vertexElements
        self.rasterizer = rasterizer
        self.depthStencilAlpha = depthStencilAlpha
        self.copyBlend = copyBlend
        self.sourceOverBlend = sourceOverBlend
        self.unitQuadVertexResource = unitQuadVertexResource
    }

    private static func areDistinct(
        _ value0: UInt32,
        _ value1: UInt32,
        _ value2: UInt32,
        _ value3: UInt32,
        _ value4: UInt32,
        _ value5: UInt32,
        _ value6: UInt32
    ) -> Bool {
        let values = (
            value0, value1, value2, value3, value4, value5, value6
        )
        return withUnsafeBytes(of: values) { bytes in
            let words = bytes.bindMemory(to: UInt32.self)
            var left = 0
            while left < words.count {
                var right = left + 1
                while right < words.count {
                    if words[left] == words[right] { return false }
                    right += 1
                }
                left += 1
            }
            return true
        }
    }

    /// VirGL keeps every context object (including surfaces) in one handle
    /// table. Resource handles use a different namespace, so only the seven
    /// context-local pipeline objects participate in this collision check.
    func containsContextObjectHandle(_ handle: UInt32) -> Bool {
        handle == vertexShader
            || handle == fragmentShader
            || handle == vertexElements
            || handle == rasterizer
            || handle == depthStencilAlpha
            || handle == copyBlend
            || handle == sourceOverBlend
    }
}

struct VirGLIRPipelineConfiguration: Equatable {
    let capabilities: VirGLContextCapabilities
    let handles: VirGLIRPipelineHandles
    let unitQuadVertexLayout: VirGLIRUnitQuadVertexLayout
}

/// One already-created VirGL surface. The resource manager must create the
/// surface with the same extent and color format before lowering begins.
struct VirGLIRRenderTarget: Equatable {
    /// VIRGL_FORMAT_B8G8R8A8_SRGB. Unlike format 101 (BGRX), this preserves
    /// the attachment alpha promised by `.bgra8UNormSRGB` across load/store
    /// passes and translucent compositing.
    static let b8g8r8a8SRGBFormat: UInt32 = 100

    let id: GPURenderTargetID
    let surfaceHandle: UInt32
    let extent: GPUPixelExtent
    let format: GPUColorAttachmentFormat
    /// Format used when the VirGL surface object was created. This is kept
    /// explicit because rendering linear IR colors into format 2 UNORM would
    /// silently skip the sRGB transfer function required by the IR.
    let virglSurfaceFormat: UInt32

    init?(
        id: GPURenderTargetID,
        surfaceHandle: UInt32,
        extent: GPUPixelExtent,
        format: GPUColorAttachmentFormat,
        virglSurfaceFormat: UInt32
    ) {
        guard surfaceHandle != 0, virglSurfaceFormat != 0 else { return nil }
        self.id = id
        self.surfaceHandle = surfaceHandle
        self.extent = extent
        self.format = format
        self.virglSurfaceFormat = virglSurfaceFormat
    }
}

enum VirGLIRPipelineInitializationRejection: Equatable {
    case alreadyInitialized
    case unsupportedShaderBinding
    case capacityExhausted(requiredDWords: Int, availableDWords: Int)
    case encoderRejected(VirGLEncodeRejection)
}

enum VirGLIRPipelineInitializationResult: Equatable {
    case initialized(startDWord: Int, dwordCount: Int)
    case rejected(VirGLIRPipelineInitializationRejection)
}

enum VirGLIRLoweringRejection: Equatable {
    case malformedCommandStream(commandIndex: Int)
    case renderTargetMismatch(commandIndex: Int)
    case renderTargetExtentMismatch(commandIndex: Int)
    case renderTargetFormatMismatch(commandIndex: Int)
    case unsupportedRenderTargetFormat(commandIndex: Int)
    case virglSurfaceFormatMismatch(
        commandIndex: Int,
        expected: UInt32,
        actual: UInt32
    )
    case surfaceHandleCollision(commandIndex: Int)
    case renderTargetTooLarge(commandIndex: Int)
    case discardStoreUnsupported(commandIndex: Int)
    case pipelineNotInitialized(commandIndex: Int)
    case roundedQuadUnsupported(commandIndex: Int)
    case glyphAtlasUnsupported(commandIndex: Int)
    case capacityExhausted(requiredDWords: Int, availableDWords: Int)
    case encoderRejected(commandIndex: Int, rejection: VirGLEncodeRejection)
}

enum VirGLIRLoweringResult: Equatable {
    case lowered(
        startDWord: Int,
        dwordCount: Int,
        renderPassCount: Int,
        drawCount: Int
    )
    case rejected(VirGLIRLoweringRejection)
}

private enum VirGLIRPreflightResult {
    case accepted(requiredDWords: Int, renderPassCount: Int, drawCount: Int)
    case rejected(VirGLIRLoweringRejection)
}

/// Stateful because context-local pipeline objects must be created once. A
/// clear-only command buffer does not require pipeline initialization; solid
/// quads do. Rounded quads and glyphs deliberately fail closed until their
/// shader/resource paths are implemented.
struct VirGLIRCompiler {
    private static let color0ClearMask: UInt32 = 1 << 2
    private static let shaderTokenCapacity: UInt32 = 256
    private static let maximumScissorCoordinate = UInt32(UInt16.max)
    private static let supportedRenderTargetFormat =
        GPUColorAttachmentFormat.bgra8UNormSRGB

    // TGSI text is carried verbatim by VirGL. Each StaticString includes its
    // terminal NUL in utf8CodeUnitCount; the encoder verifies that byte before
    // accepting the final shader fragment.
    private static let vertexShaderText: StaticString = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\nDCL OUT[1], COLOR\nDCL CONST[0..3]\nDCL TEMP[0]\n  0: MUL TEMP[0], IN[0].xxxx, CONST[0]\n  1: MAD TEMP[0], IN[0].yyyy, CONST[1], TEMP[0]\n  2: ADD OUT[0], TEMP[0], CONST[2]\n  3: MOV OUT[1], CONST[3]\n  4: END\n\0"
    private static let fragmentShaderText: StaticString = "FRAG\nDCL IN[0], COLOR, LINEAR\nDCL OUT[0], COLOR\n  0: MOV OUT[0], IN[0]\n  1: END\n\0"

    let configuration: VirGLIRPipelineConfiguration
    private(set) var isPipelineInitialized = false

    init(configuration: VirGLIRPipelineConfiguration) {
        self.configuration = configuration
    }

    mutating func initializePipeline(
        into arena: inout VirGLDWordArena
    ) -> VirGLIRPipelineInitializationResult {
        guard !isPipelineInitialized else {
            return .rejected(.alreadyInitialized)
        }
        guard configuration.capabilities.supportsExplicitShaderBinding else {
            return .rejected(.unsupportedShaderBinding)
        }

        let required = pipelineInitializationDWordCount
        guard required <= arena.remainingCapacity else {
            return .rejected(
                .capacityExhausted(
                    requiredDWords: required,
                    availableDWords: arena.remainingCapacity
                )
            )
        }

        let start = arena.dwordCount
        var working = arena
        if let rejection = encodePipelineInitialization(into: &working) {
            return .rejected(.encoderRejected(rejection))
        }
        let encodedCount = working.dwordCount - start
        guard encodedCount == required else {
            return .rejected(.encoderRejected(.invalidState))
        }

        arena = working
        isPipelineInitialized = true
        return .initialized(startDWord: start, dwordCount: encodedCount)
    }

    mutating func lower(
        _ commandBuffer: GPURenderCommandBuffer,
        renderTarget: VirGLIRRenderTarget,
        into arena: inout VirGLDWordArena
    ) -> VirGLIRLoweringResult {
        let checked = preflight(commandBuffer, renderTarget: renderTarget)
        let required: Int
        let renderPassCount: Int
        let drawCount: Int
        switch checked {
        case .accepted(
            let acceptedRequired,
            let acceptedPassCount,
            let acceptedDrawCount
        ):
            required = acceptedRequired
            renderPassCount = acceptedPassCount
            drawCount = acceptedDrawCount
        case .rejected(let rejection):
            return .rejected(rejection)
        }

        guard required <= arena.remainingCapacity else {
            return .rejected(
                .capacityExhausted(
                    requiredDWords: required,
                    availableDWords: arena.remainingCapacity
                )
            )
        }

        let start = arena.dwordCount
        var working = arena
        if let failure = encode(
            commandBuffer,
            renderTarget: renderTarget,
            into: &working
        ) {
            return .rejected(failure)
        }
        let encodedCount = working.dwordCount - start
        guard encodedCount == required else {
            return .rejected(
                .encoderRejected(
                    commandIndex: commandBuffer.commandCount,
                    rejection: .invalidState
                )
            )
        }

        arena = working
        return .lowered(
            startDWord: start,
            dwordCount: encodedCount,
            renderPassCount: renderPassCount,
            drawCount: drawCount
        )
    }

    private var pipelineInitializationDWordCount: Int {
        // Vertex elements, rasterizer, DSA, two blend objects, and two shader
        // objects. LINK_SHADER is present only when the capset advertises SSO.
        var count = 6 + 10 + 6 + 12 + 12
        count += Self.shaderPacketDWordCount(Self.vertexShaderText)
        count += Self.shaderPacketDWordCount(Self.fragmentShaderText)
        if configuration.capabilities.supportsShaderLink { count += 7 }
        return count
    }

    private func preflight(
        _ commandBuffer: GPURenderCommandBuffer,
        renderTarget: VirGLIRRenderTarget
    ) -> VirGLIRPreflightResult {
        var required = 0
        var passCount = 0
        var drawCount = 0
        var insidePass = false
        var pipelineBound = false
        var boundBlend: GPUBlendMode?

        var index = 0
        while index < commandBuffer.commandCount {
            guard let command = commandBuffer.command(at: index) else {
                return .rejected(.malformedCommandStream(commandIndex: index))
            }
            switch command {
            case .beginRenderPass(let descriptor):
                guard !insidePass else {
                    return .rejected(
                        .malformedCommandStream(commandIndex: index)
                    )
                }
                guard descriptor.target == renderTarget.id else {
                    return .rejected(.renderTargetMismatch(commandIndex: index))
                }
                guard !configuration.handles.containsContextObjectHandle(
                    renderTarget.surfaceHandle
                ) else {
                    return .rejected(
                        .surfaceHandleCollision(commandIndex: index)
                    )
                }
                guard descriptor.extent == renderTarget.extent else {
                    return .rejected(
                        .renderTargetExtentMismatch(commandIndex: index)
                    )
                }
                guard descriptor.format == renderTarget.format else {
                    return .rejected(
                        .renderTargetFormatMismatch(commandIndex: index)
                    )
                }
                guard descriptor.format == Self.supportedRenderTargetFormat else {
                    return .rejected(
                        .unsupportedRenderTargetFormat(commandIndex: index)
                    )
                }
                guard renderTarget.virglSurfaceFormat
                        == VirGLIRRenderTarget.b8g8r8a8SRGBFormat
                else {
                    return .rejected(
                        .virglSurfaceFormatMismatch(
                            commandIndex: index,
                            expected: VirGLIRRenderTarget.b8g8r8a8SRGBFormat,
                            actual: renderTarget.virglSurfaceFormat
                        )
                    )
                }
                guard descriptor.extent.width
                        <= Self.maximumScissorCoordinate,
                      descriptor.extent.height
                        <= Self.maximumScissorCoordinate
                else {
                    return .rejected(.renderTargetTooLarge(commandIndex: index))
                }
                guard descriptor.storeAction == .store else {
                    return .rejected(
                        .discardStoreUnsupported(commandIndex: index)
                    )
                }
                // SET_FRAMEBUFFER (4), one viewport (8), full scissor (4).
                required += 16
                if case .clear = descriptor.loadAction { required += 9 }
                insidePass = true
                pipelineBound = false
                boundBlend = nil
                passCount += 1

            case .setScissor:
                guard insidePass else {
                    return .rejected(
                        .malformedCommandStream(commandIndex: index)
                    )
                }
                required += 4

            case .setTransform:
                guard insidePass else {
                    return .rejected(
                        .malformedCommandStream(commandIndex: index)
                    )
                }

            case .drawQuad(let quad):
                guard insidePass else {
                    return .rejected(
                        .malformedCommandStream(commandIndex: index)
                    )
                }
                guard !quad.isRounded else {
                    return .rejected(
                        .roundedQuadUnsupported(commandIndex: index)
                    )
                }
                guard isPipelineInitialized else {
                    return .rejected(
                        .pipelineNotInitialized(commandIndex: index)
                    )
                }
                if !pipelineBound {
                    // Three generic object binds, two shader binds, and one
                    // vertex-buffer packet.
                    required += 16
                    pipelineBound = true
                }
                if boundBlend != quad.blendMode {
                    required += 2
                    boundBlend = quad.blendMode
                }
                // Four vec4 vertex constants (19) plus DRAW_VBO (13).
                required += 32
                drawCount += 1

            case .drawGlyph:
                guard insidePass else {
                    return .rejected(
                        .malformedCommandStream(commandIndex: index)
                    )
                }
                return .rejected(.glyphAtlasUnsupported(commandIndex: index))

            case .endRenderPass:
                guard insidePass else {
                    return .rejected(
                        .malformedCommandStream(commandIndex: index)
                    )
                }
                insidePass = false
            }
            index += 1
        }

        guard !insidePass, passCount == commandBuffer.renderPassCount else {
            return .rejected(
                .malformedCommandStream(commandIndex: commandBuffer.commandCount)
            )
        }
        return .accepted(
            requiredDWords: required,
            renderPassCount: passCount,
            drawCount: drawCount
        )
    }

    private func encodePipelineInitialization(
        into arena: inout VirGLDWordArena
    ) -> VirGLEncodeRejection? {
        let handles = configuration.handles

        var vertexElement = VirGLVertexElement(
            sourceOffset: 0,
            instanceDivisor: 0,
            vertexBufferIndex: 0,
            sourceFormat: configuration.unitQuadVertexLayout.format
        )
        let vertexElementResult = withUnsafePointer(to: &vertexElement) {
            pointer in
            arena.encodeCreateVertexElements(
                handle: handles.vertexElements,
                elements: UnsafeBufferPointer(start: pointer, count: 1)
            )
        }
        if let rejection = Self.rejection(vertexElementResult) {
            return rejection
        }

        // Gallium rasterizer bits: depth_clip, scissor, half_pixel_center.
        let rasterizerFlags: UInt32 = (1 << 1) | (1 << 14) | (1 << 29)
        let rasterizer = VirGLRasterizerState(
            flags: rasterizerFlags,
            pointSizeBits: Float(1).bitPattern,
            spriteCoordinateEnableMask: 0,
            lineAndClipState: 0,
            lineWidthBits: Float(1).bitPattern,
            offsetUnitsBits: 0,
            offsetScaleBits: 0,
            offsetClampBits: 0
        )
        if let rejection = Self.rejection(
            arena.encodeCreateRasterizerState(
                handle: handles.rasterizer,
                state: rasterizer
            )
        ) {
            return rejection
        }

        guard let dsa = VirGLDepthStencilAlphaState(
            depthAlphaDWord: 0,
            frontStencilDWord: 0,
            backStencilDWord: 0,
            alphaReferenceBits: 0
        ) else {
            return .invalidState
        }
        if let rejection = Self.rejection(
            arena.encodeCreateDepthStencilAlphaState(
                handle: handles.depthStencilAlpha,
                state: dsa
            )
        ) {
            return rejection
        }

        guard let globalBlend = VirGLBlendGlobalState(
            flags: 0,
            logicOperation: 0
        ), let copyTarget = VirGLBlendTargetState(
            blendEnabled: false,
            rgbFunction: 0,
            rgbSourceFactor: 1,
            rgbDestinationFactor: 0x11,
            alphaFunction: 0,
            alphaSourceFactor: 1,
            alphaDestinationFactor: 0x11,
            colorMask: 0xf
        ), let sourceOverTarget = VirGLBlendTargetState(
            blendEnabled: true,
            rgbFunction: 0,
            rgbSourceFactor: 1,
            rgbDestinationFactor: 0x13,
            alphaFunction: 0,
            alphaSourceFactor: 1,
            alphaDestinationFactor: 0x13,
            colorMask: 0xf
        ) else {
            return .invalidState
        }
        var copyTargets = (
            copyTarget, copyTarget, copyTarget, copyTarget,
            copyTarget, copyTarget, copyTarget, copyTarget
        )
        let copyResult = withUnsafeBytes(of: &copyTargets) { bytes in
            arena.encodeCreateBlendState(
                handle: handles.copyBlend,
                global: globalBlend,
                targets: bytes.bindMemory(to: VirGLBlendTargetState.self)
            )
        }
        if let rejection = Self.rejection(copyResult) { return rejection }

        var sourceOverTargets = (
            sourceOverTarget, sourceOverTarget,
            sourceOverTarget, sourceOverTarget,
            sourceOverTarget, sourceOverTarget,
            sourceOverTarget, sourceOverTarget
        )
        let sourceOverResult = withUnsafeBytes(of: &sourceOverTargets) {
            bytes in
            arena.encodeCreateBlendState(
                handle: handles.sourceOverBlend,
                global: globalBlend,
                targets: bytes.bindMemory(to: VirGLBlendTargetState.self)
            )
        }
        if let rejection = Self.rejection(sourceOverResult) { return rejection }

        let vertexBytes = UnsafeRawBufferPointer(
            start: Self.vertexShaderText.utf8Start,
            count: Self.vertexShaderText.utf8CodeUnitCount
        )
        if let rejection = Self.rejection(
            arena.encodeCreateShaderObjectFragment(
                handle: handles.vertexShader,
                stage: .vertex,
                tokenCount: Self.shaderTokenCapacity,
                totalByteCount: UInt32(vertexBytes.count),
                fragmentOffset: 0,
                bytes: vertexBytes
            )
        ) {
            return rejection
        }

        let fragmentBytes = UnsafeRawBufferPointer(
            start: Self.fragmentShaderText.utf8Start,
            count: Self.fragmentShaderText.utf8CodeUnitCount
        )
        if let rejection = Self.rejection(
            arena.encodeCreateShaderObjectFragment(
                handle: handles.fragmentShader,
                stage: .fragment,
                tokenCount: Self.shaderTokenCapacity,
                totalByteCount: UInt32(fragmentBytes.count),
                fragmentOffset: 0,
                bytes: fragmentBytes
            )
        ) {
            return rejection
        }

        if configuration.capabilities.supportsShaderLink {
            guard let program = VirGLShaderProgramHandles(
                vertex: handles.vertexShader,
                fragment: handles.fragmentShader
            ) else {
                return .invalidState
            }
            if let rejection = Self.rejection(
                arena.encodeLinkShader(
                    capabilities: configuration.capabilities,
                    program: program
                )
            ) {
                return rejection
            }
        }
        return nil
    }

    private func encode(
        _ commandBuffer: GPURenderCommandBuffer,
        renderTarget: VirGLIRRenderTarget,
        into arena: inout VirGLDWordArena
    ) -> VirGLIRLoweringRejection? {
        var activeDescriptor: GPURenderPassDescriptor?
        var transform = GPUTransform2D.identity
        var pipelineBound = false
        var boundBlend: GPUBlendMode?

        var index = 0
        while index < commandBuffer.commandCount {
            guard let command = commandBuffer.command(at: index) else {
                return .malformedCommandStream(commandIndex: index)
            }
            switch command {
            case .beginRenderPass(let descriptor):
                activeDescriptor = descriptor
                transform = .identity
                pipelineBound = false
                boundBlend = nil

                var colorSurface = renderTarget.surfaceHandle
                let framebufferResult = withUnsafePointer(to: &colorSurface) {
                    pointer in
                    arena.encodeSetFramebuffer(
                        colorSurfaceHandles: UnsafeBufferPointer(
                            start: pointer,
                            count: 1
                        ),
                        depthStencilSurfaceHandle: nil
                    )
                }
                if let rejection = Self.rejection(framebufferResult) {
                    return .encoderRejected(
                        commandIndex: index,
                        rejection: rejection
                    )
                }

                if let rejection = encodeViewport(
                    extent: descriptor.extent,
                    into: &arena
                ) {
                    return .encoderRejected(
                        commandIndex: index,
                        rejection: rejection
                    )
                }
                if let rejection = encodeScissor(
                    .disabled,
                    extent: descriptor.extent,
                    into: &arena
                ) {
                    return .encoderRejected(
                        commandIndex: index,
                        rejection: rejection
                    )
                }

                if case .clear(let color) = descriptor.loadAction {
                    if let rejection = Self.rejection(
                        arena.encodeClear(Self.clearValue(color))
                    ) {
                        return .encoderRejected(
                            commandIndex: index,
                            rejection: rejection
                        )
                    }
                }

            case .setScissor(let state):
                guard let descriptor = activeDescriptor else {
                    return .malformedCommandStream(commandIndex: index)
                }
                if let rejection = encodeScissor(
                    state,
                    extent: descriptor.extent,
                    into: &arena
                ) {
                    return .encoderRejected(
                        commandIndex: index,
                        rejection: rejection
                    )
                }

            case .setTransform(let newTransform):
                transform = newTransform

            case .drawQuad(let quad):
                guard let descriptor = activeDescriptor else {
                    return .malformedCommandStream(commandIndex: index)
                }
                if !pipelineBound {
                    if let rejection = encodePipelineBindings(into: &arena) {
                        return .encoderRejected(
                            commandIndex: index,
                            rejection: rejection
                        )
                    }
                    pipelineBound = true
                }
                if boundBlend != quad.blendMode {
                    let blendHandle = quad.blendMode == .copy
                        ? configuration.handles.copyBlend
                        : configuration.handles.sourceOverBlend
                    if let rejection = Self.rejection(
                        arena.encodeBindObject(
                            type: .blend,
                            handle: blendHandle
                        )
                    ) {
                        return .encoderRejected(
                            commandIndex: index,
                            rejection: rejection
                        )
                    }
                    boundBlend = quad.blendMode
                }
                if let rejection = encodeQuadConstants(
                    quad,
                    transform: transform,
                    extent: descriptor.extent,
                    into: &arena
                ) {
                    return .encoderRejected(
                        commandIndex: index,
                        rejection: rejection
                    )
                }
                let draw = VirGLDrawDescriptor(
                    start: 0,
                    count: 6,
                    topology: .triangles,
                    indexed: false,
                    instanceCount: 1,
                    indexBias: 0,
                    startInstance: 0,
                    primitiveRestartEnabled: false,
                    restartIndex: 0,
                    minimumIndex: 0,
                    maximumIndex: 5,
                    countFromStreamOutputHandle: nil
                )
                if let rejection = Self.rejection(arena.encodeDrawVBO(draw)) {
                    return .encoderRejected(
                        commandIndex: index,
                        rejection: rejection
                    )
                }

            case .drawGlyph:
                return .glyphAtlasUnsupported(commandIndex: index)

            case .endRenderPass:
                activeDescriptor = nil
            }
            index += 1
        }
        return nil
    }

    private func encodePipelineBindings(
        into arena: inout VirGLDWordArena
    ) -> VirGLEncodeRejection? {
        let handles = configuration.handles
        if let rejection = Self.rejection(
            arena.encodeBindObject(type: .rasterizer, handle: handles.rasterizer)
        ) { return rejection }
        if let rejection = Self.rejection(
            arena.encodeBindObject(
                type: .depthStencilAlpha,
                handle: handles.depthStencilAlpha
            )
        ) { return rejection }
        if let rejection = Self.rejection(
            arena.encodeBindObject(
                type: .vertexElements,
                handle: handles.vertexElements
            )
        ) { return rejection }
        if let rejection = Self.rejection(
            arena.encodeBindShader(
                capabilities: configuration.capabilities,
                stage: .vertex,
                handle: handles.vertexShader
            )
        ) { return rejection }
        if let rejection = Self.rejection(
            arena.encodeBindShader(
                capabilities: configuration.capabilities,
                stage: .fragment,
                handle: handles.fragmentShader
            )
        ) { return rejection }

        var vertexBuffer = VirGLVertexBuffer(
            stride: configuration.unitQuadVertexLayout.stride,
            offset: 0,
            resourceHandle: handles.unitQuadVertexResource
        )
        return withUnsafePointer(to: &vertexBuffer) { pointer in
            Self.rejection(
                arena.encodeSetVertexBuffers(
                    UnsafeBufferPointer(start: pointer, count: 1)
                )
            )
        }
    }

    private func encodeViewport(
        extent: GPUPixelExtent,
        into arena: inout VirGLDWordArena
    ) -> VirGLEncodeRejection? {
        let halfWidth = Float(extent.width) * 0.5
        let halfHeight = Float(extent.height) * 0.5
        var viewport = VirGLViewport(
            scaleXBits: halfWidth.bitPattern,
            scaleYBits: halfHeight.bitPattern,
            scaleZBits: Float(0.5).bitPattern,
            translateXBits: halfWidth.bitPattern,
            translateYBits: halfHeight.bitPattern,
            translateZBits: Float(0.5).bitPattern
        )
        return withUnsafePointer(to: &viewport) { pointer in
            Self.rejection(
                arena.encodeSetViewports(
                    startSlot: 0,
                    viewports: UnsafeBufferPointer(start: pointer, count: 1)
                )
            )
        }
    }

    private func encodeScissor(
        _ state: GPUScissorState,
        extent: GPUPixelExtent,
        into arena: inout VirGLDWordArena
    ) -> VirGLEncodeRejection? {
        let minimumX: UInt32
        let minimumY: UInt32
        let maximumX: UInt32
        let maximumY: UInt32
        switch state {
        case .disabled:
            minimumX = 0
            minimumY = 0
            maximumX = extent.width
            maximumY = extent.height
        case .rectangle(let rectangle):
            minimumX = rectangle.x
            maximumX = rectangle.endX
            // SwiftOS uses a top-left origin. Gallium scissors use the
            // framebuffer's bottom-left window coordinate system.
            minimumY = extent.height - rectangle.endY
            maximumY = extent.height - rectangle.y
        }
        guard var scissor = VirGLScissorRectangle(
            minimumX: minimumX,
            minimumY: minimumY,
            maximumX: maximumX,
            maximumY: maximumY
        ) else {
            return .invalidState
        }
        return withUnsafePointer(to: &scissor) { pointer in
            Self.rejection(
                arena.encodeSetScissors(
                    startSlot: 0,
                    scissors: UnsafeBufferPointer(start: pointer, count: 1)
                )
            )
        }
    }

    private func encodeQuadConstants(
        _ quad: GPUQuadInstance,
        transform: GPUTransform2D,
        extent: GPUPixelExtent,
        into arena: inout VirGLDWordArena
    ) -> VirGLEncodeRejection? {
        let x = Self.float(quad.bounds.x)
        let y = Self.float(quad.bounds.y)
        let width = Self.float(quad.bounds.width)
        let height = Self.float(quad.bounds.height)
        let m11 = Self.float(transform.m11)
        let m12 = Self.float(transform.m12)
        let m21 = Self.float(transform.m21)
        let m22 = Self.float(transform.m22)
        let translationX = Self.float(transform.translationX)
        let translationY = Self.float(transform.translationY)

        let targetWidth = Float(extent.width)
        let targetHeight = Float(extent.height)
        let scaleX = Float(2) / targetWidth
        let scaleY = Float(2) / targetHeight

        // CONST[0] and CONST[1] are the transformed unit-quad basis vectors.
        // CONST[2] is the transformed top-left origin in clip coordinates.
        let basisXX = m11 * width * scaleX
        let basisXY = -(m12 * width * scaleY)
        let basisYX = m21 * height * scaleX
        let basisYY = -(m22 * height * scaleY)
        let originX = ((m11 * x + m21 * y + translationX) * scaleX) - 1
        let originY = 1 - ((m12 * x + m22 * y + translationY) * scaleY)

        let colorScale = Float(1) / Float(UInt16.max)
        let color = quad.color
        var constants = (
            basisXX.bitPattern, basisXY.bitPattern, UInt32(0), UInt32(0),
            basisYX.bitPattern, basisYY.bitPattern, UInt32(0), UInt32(0),
            originX.bitPattern, originY.bitPattern, UInt32(0), Float(1).bitPattern,
            (Float(color.red) * colorScale).bitPattern,
            (Float(color.green) * colorScale).bitPattern,
            (Float(color.blue) * colorScale).bitPattern,
            (Float(color.alpha) * colorScale).bitPattern
        )
        return withUnsafeBytes(of: &constants) { bytes in
            Self.rejection(
                arena.encodeSetConstantBuffer(
                    stage: .vertex,
                    index: 0,
                    dwords: bytes.bindMemory(to: UInt32.self)
                )
            )
        }
    }

    private static func clearValue(
        _ color: GPUPremultipliedColor
    ) -> VirGLClearValue {
        let scale = Float(1) / Float(UInt16.max)
        // The IR and VirGL clear packet both order channels RGBA. Surface
        // format swizzling is the render-target object's responsibility.
        return VirGLClearValue(
            bufferMask: color0ClearMask,
            color0Bits: (Float(color.red) * scale).bitPattern,
            color1Bits: (Float(color.green) * scale).bitPattern,
            color2Bits: (Float(color.blue) * scale).bitPattern,
            color3Bits: (Float(color.alpha) * scale).bitPattern,
            depthBits: 0,
            stencil: 0
        )!
    }

    private static func float(_ value: GPUFixed16) -> Float {
        Float(value.rawValue) / Float(GPUFixed16.unitRawValue)
    }

    private static func shaderPacketDWordCount(_ text: StaticString) -> Int {
        6 + ((text.utf8CodeUnitCount + 3) / 4)
    }

    private static func rejection(
        _ result: VirGLEncodeResult
    ) -> VirGLEncodeRejection? {
        if case .rejected(let rejection) = result { return rejection }
        return nil
    }
}
