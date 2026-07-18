// Allocation-free validation for the VirGL capability payload returned by
// VIRTIO_GPU_CMD_GET_CAPSET. This is a wire parser, not a C-layout overlay.
// Every multi-byte value is decoded explicitly as little-endian bytes.
//
// Pinned wire-layout and format-number source (used as a specification only):
// https://android.googlesource.com/platform/external/virglrenderer/+/b15ac6f9cbcd64c47015d745c3124fd66fb9bc72/src/virgl_hw.h
//
// The format names and primitive numbering are the Gallium definitions fixed
// into that public VirGL protocol. No virglrenderer implementation is reused.

enum VirGLCapsetKind: UInt32 {
    case virgl = 1
    case virgl2 = 2
}

struct VirGLCapsetSelection: Equatable {
    let kind: VirGLCapsetKind
    let version: UInt32
    let payloadByteCount: UInt32

    init?(kind: VirGLCapsetKind, version: UInt32, payloadByteCount: UInt32) {
        guard VirGLCapabilityWire.layoutIsKnown(
            kind: kind,
            version: version,
            payloadByteCount: payloadByteCount
        ) else {
            return nil
        }
        self.kind = kind
        self.version = version
        self.payloadByteCount = payloadByteCount
    }
}

enum VirGLCapsetSelectionRejection: Equatable {
    case tooManyObservations
    case incompleteObservations
    case duplicateCapset
    case unknownLayout
}

enum VirGLCapsetObservationResult: Equatable {
    case accepted
    case ignored
    case rejected(VirGLCapsetSelectionRejection)
}

enum VirGLCapsetSelectionResult: Equatable {
    case selected(VirGLCapsetSelection)
    case unavailable
    case rejected(VirGLCapsetSelectionRejection)
}

/// Collects a device's bounded GET_CAPSET_INFO observations. Selection is
/// independent of enumeration order and always prefers a validated VIRGL2
/// layout. Unrelated capsets are counted and ignored.
struct VirGLCapsetSelector {
    static let maximumObservationCount: UInt32 = 64

    private let expectedObservationCount: UInt32
    private var observedCount: UInt32 = 0
    private var virgl: VirGLCapsetSelection?
    private var virgl2: VirGLCapsetSelection?
    private var rejection: VirGLCapsetSelectionRejection?

    init?(advertisedCapsetCount: UInt32) {
        guard advertisedCapsetCount <= Self.maximumObservationCount else {
            return nil
        }
        expectedObservationCount = advertisedCapsetCount
    }

    mutating func observe(
        _ information: VirtIOGPU3DCapsetInfo
    ) -> VirGLCapsetObservationResult {
        if let rejection {
            return .rejected(rejection)
        }
        guard observedCount < expectedObservationCount else {
            self.rejection = .tooManyObservations
            return .rejected(.tooManyObservations)
        }
        observedCount += 1

        guard let kind = VirGLCapsetKind(rawValue: information.id) else {
            return .ignored
        }
        guard let candidate = VirGLCapsetSelection(
            kind: kind,
            version: information.maximumVersion,
            payloadByteCount: information.maximumByteCount
        ) else {
            rejection = .unknownLayout
            return .rejected(.unknownLayout)
        }

        switch kind {
        case .virgl:
            guard virgl == nil else {
                rejection = .duplicateCapset
                return .rejected(.duplicateCapset)
            }
            virgl = candidate
        case .virgl2:
            guard virgl2 == nil else {
                rejection = .duplicateCapset
                return .rejected(.duplicateCapset)
            }
            virgl2 = candidate
        }
        return .accepted
    }

    func finish() -> VirGLCapsetSelectionResult {
        if let rejection {
            return .rejected(rejection)
        }
        guard observedCount == expectedObservationCount else {
            return .rejected(.incompleteObservations)
        }
        if let virgl2 {
            return .selected(virgl2)
        }
        if let virgl {
            return .selected(virgl)
        }
        return .unavailable
    }
}

enum VirGLCapabilityParseRejection: Equatable {
    case unknownLayout
    case truncatedPayload
    case unexpectedPayloadSize
    case invalidByteOrderOrVersion
    case unsupportedShaderProfile
    case unsupportedPrimitive
    case impossibleRenderTargetLimit
    case impossibleTextureLimit
    case unsupportedRenderTargetFormat
    case unsupportedVertexFormat
}

enum VirGLCapabilityParseResult: Equatable {
    case capabilities(VirGLRendererCapabilities)
    case rejected(VirGLCapabilityParseRejection)
}

enum VirGLShaderWireLanguage: Equatable {
    case tgsiText
}

/// The validated subset needed by SwiftOS's first solid-quad renderer.
/// A missing texture limit is meaningful: the legacy VIRGL layout never put
/// `max_texture_2d_size` on the wire, while VIRGL2 does.
struct VirGLRendererCapabilities: Equatable {
    let capset: VirGLCapsetSelection
    let shaderWireLanguage: VirGLShaderWireLanguage
    let glslLevel: UInt32
    let maximumRenderTargetCount: UInt32
    let maximumTexture2DSize: UInt32?
    let capabilityBits: UInt32
    let capabilityBitsV2: UInt32
    let supportsB8G8R8X8RenderTarget: Bool
    let supportsR32G32FloatVertex: Bool
    let supportsR32G32B32A32FloatVertex: Bool

    var hasExplicitTexture2DLimit: Bool {
        maximumTexture2DSize != nil
    }

    func supportsTexture2D(width: UInt32, height: UInt32) -> Bool {
        guard width != 0,
              height != 0,
              let maximumTexture2DSize
        else {
            return false
        }
        return width <= maximumTexture2DSize
            && height <= maximumTexture2DSize
    }
}

enum VirGLCapabilityWire {
    static let virglMaximumKnownVersion: UInt32 = 1
    static let virgl2MaximumKnownVersion: UInt32 = 2

    // `virgl_caps_v1` is 77 32-bit words. `virgl_caps_v2` is 344
    // 32-bit words at the pinned protocol revision.
    static let virglPayloadByteCount: UInt32 = 77 * 4
    static let virgl2PayloadByteCount: UInt32 = 344 * 4

    // The initial vertex/fragment TGSI profile uses only operations available
    // to the renderer's GLSL 1.20 translation path.
    static let minimumCompatibleGLSLLevel: UInt32 = 120
    static let maximumGalliumRenderTargets: UInt32 = 8

    // virgl_formats wire values.
    static let formatB8G8R8X8UNorm: UInt32 = 2
    static let formatR32G32Float: UInt32 = 29
    static let formatR32G32B32A32Float: UInt32 = 31

    // PIPE_PRIM_TRIANGLES.
    static let trianglesPrimitive: UInt32 = 4

    fileprivate static let maximumVersionWord = 0
    fileprivate static let renderFormatMaskWord = 17
    fileprivate static let vertexFormatMaskWord = 49
    fileprivate static let glslLevelWord = 66
    fileprivate static let maximumRenderTargetsWord = 70
    fileprivate static let primitiveMaskWord = 72
    fileprivate static let capabilityBitsWord = 98
    fileprivate static let maximumTexture2DSizeWord = 121
    fileprivate static let capabilityBitsV2Word = 172

    static func layoutIsKnown(
        kind: VirGLCapsetKind,
        version: UInt32,
        payloadByteCount: UInt32
    ) -> Bool {
        switch kind {
        case .virgl:
            return version <= virglMaximumKnownVersion
                && payloadByteCount == virglPayloadByteCount
        case .virgl2:
            return version <= virgl2MaximumKnownVersion
                && payloadByteCount == virgl2PayloadByteCount
        }
    }
}

enum VirGLCapabilityParser {
    static func parse(
        capset: VirGLCapsetSelection,
        payload: UnsafeRawBufferPointer
    ) -> VirGLCapabilityParseResult {
        guard VirGLCapabilityWire.layoutIsKnown(
            kind: capset.kind,
            version: capset.version,
            payloadByteCount: capset.payloadByteCount
        ) else {
            return .rejected(.unknownLayout)
        }

        let expectedByteCount = Int(capset.payloadByteCount)
        guard payload.count >= expectedByteCount else {
            return .rejected(.truncatedPayload)
        }
        guard payload.count == expectedByteCount else {
            return .rejected(.unexpectedPayloadSize)
        }
        guard payload.baseAddress != nil else {
            return .rejected(.truncatedPayload)
        }

        guard readLE32(
            word: VirGLCapabilityWire.maximumVersionWord,
            payload: payload
        ) == capset.version else {
            return .rejected(.invalidByteOrderOrVersion)
        }

        let glslLevel = readLE32(
            word: VirGLCapabilityWire.glslLevelWord,
            payload: payload
        )
        guard glslLevel >= VirGLCapabilityWire.minimumCompatibleGLSLLevel,
              glslLevel <= UInt32(Int32.max)
        else {
            return .rejected(.unsupportedShaderProfile)
        }

        let primitiveMask = readLE32(
            word: VirGLCapabilityWire.primitiveMaskWord,
            payload: payload
        )
        guard bitIsSet(
            bit: VirGLCapabilityWire.trianglesPrimitive,
            in: primitiveMask
        ) else {
            return .rejected(.unsupportedPrimitive)
        }

        let maximumRenderTargetCount = readLE32(
            word: VirGLCapabilityWire.maximumRenderTargetsWord,
            payload: payload
        )
        guard maximumRenderTargetCount != 0,
              maximumRenderTargetCount
                <= VirGLCapabilityWire.maximumGalliumRenderTargets
        else {
            return .rejected(.impossibleRenderTargetLimit)
        }

        let renderFormatMask = readLE32(
            word: VirGLCapabilityWire.renderFormatMaskWord,
            payload: payload
        )
        let supportsRenderTarget = bitIsSet(
            bit: VirGLCapabilityWire.formatB8G8R8X8UNorm,
            in: renderFormatMask
        )
        guard supportsRenderTarget else {
            return .rejected(.unsupportedRenderTargetFormat)
        }

        let vertexFormatMask = readLE32(
            word: VirGLCapabilityWire.vertexFormatMaskWord,
            payload: payload
        )
        let supportsR32G32 = bitIsSet(
            bit: VirGLCapabilityWire.formatR32G32Float,
            in: vertexFormatMask
        )
        let supportsR32G32B32A32 = bitIsSet(
            bit: VirGLCapabilityWire.formatR32G32B32A32Float,
            in: vertexFormatMask
        )
        guard supportsR32G32 || supportsR32G32B32A32 else {
            return .rejected(.unsupportedVertexFormat)
        }

        let maximumTexture2DSize: UInt32?
        let capabilityBits: UInt32
        let capabilityBitsV2: UInt32
        switch capset.kind {
        case .virgl:
            maximumTexture2DSize = nil
            capabilityBits = 0
            capabilityBitsV2 = 0
        case .virgl2:
            let textureLimit = readLE32(
                word: VirGLCapabilityWire.maximumTexture2DSizeWord,
                payload: payload
            )
            // GL exposes this as a positive signed integer. Reject values that
            // cannot have come from that API without inventing a tighter
            // implementation-specific limit.
            guard textureLimit != 0,
                  textureLimit <= UInt32(Int32.max)
            else {
                return .rejected(.impossibleTextureLimit)
            }
            maximumTexture2DSize = textureLimit
            capabilityBits = readLE32(
                word: VirGLCapabilityWire.capabilityBitsWord,
                payload: payload
            )
            capabilityBitsV2 = readLE32(
                word: VirGLCapabilityWire.capabilityBitsV2Word,
                payload: payload
            )
        }

        return .capabilities(
            VirGLRendererCapabilities(
                capset: capset,
                shaderWireLanguage: .tgsiText,
                glslLevel: glslLevel,
                maximumRenderTargetCount: maximumRenderTargetCount,
                maximumTexture2DSize: maximumTexture2DSize,
                capabilityBits: capabilityBits,
                capabilityBitsV2: capabilityBitsV2,
                supportsB8G8R8X8RenderTarget: supportsRenderTarget,
                supportsR32G32FloatVertex: supportsR32G32,
                supportsR32G32B32A32FloatVertex: supportsR32G32B32A32
            )
        )
    }

    private static func readLE32(
        word: Int,
        payload: UnsafeRawBufferPointer
    ) -> UInt32 {
        let offset = word * 4
        return UInt32(payload[offset])
            | (UInt32(payload[offset + 1]) << 8)
            | (UInt32(payload[offset + 2]) << 16)
            | (UInt32(payload[offset + 3]) << 24)
    }

    private static func bitIsSet(bit: UInt32, in word: UInt32) -> Bool {
        bit < 32 && word & (UInt32(1) << bit) != 0
    }
}
