enum GPUColorAttachmentFormat: UInt8, Equatable {
    case bgra8UNormSRGB
    case rgba8UNormSRGB
    case rgba16Float
}

enum GPURenderPassLoadAction: Equatable {
    case load
    case clear(GPUPremultipliedColor)
}

enum GPURenderPassStoreAction: UInt8, Equatable {
    case store
    case discard
}

/// One color attachment for a render pass. Multisampling and depth/stencil can
/// be added without changing the device-neutral command ordering contract.
struct GPURenderPassDescriptor: Equatable {
    let target: GPURenderTargetID
    let extent: GPUPixelExtent
    let format: GPUColorAttachmentFormat
    let loadAction: GPURenderPassLoadAction
    let storeAction: GPURenderPassStoreAction

    init(
        target: GPURenderTargetID,
        extent: GPUPixelExtent,
        format: GPUColorAttachmentFormat,
        loadAction: GPURenderPassLoadAction,
        storeAction: GPURenderPassStoreAction = .store
    ) {
        self.target = target
        self.extent = extent
        self.format = format
        self.loadAction = loadAction
        self.storeAction = storeAction
    }
}

enum GPUBlendMode: UInt8, Equatable {
    case copy
    case sourceOver
}

struct GPUCornerRadii: Equatable {
    let topLeft: GPUFixed16
    let topRight: GPUFixed16
    let bottomRight: GPUFixed16
    let bottomLeft: GPUFixed16

    init?(
        topLeft: GPUFixed16,
        topRight: GPUFixed16,
        bottomRight: GPUFixed16,
        bottomLeft: GPUFixed16
    ) {
        guard topLeft.rawValue >= 0,
              topRight.rawValue >= 0,
              bottomRight.rawValue >= 0,
              bottomLeft.rawValue >= 0
        else {
            return nil
        }
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    static let zero = GPUCornerRadii(
        uncheckedTopLeft: .zero,
        topRight: .zero,
        bottomRight: .zero,
        bottomLeft: .zero
    )

    static func uniform(_ radius: GPUFixed16) -> GPUCornerRadii? {
        GPUCornerRadii(
            topLeft: radius,
            topRight: radius,
            bottomRight: radius,
            bottomLeft: radius
        )
    }

    var isZero: Bool {
        topLeft == .zero && topRight == .zero
            && bottomRight == .zero && bottomLeft == .zero
    }

    fileprivate func fits(_ rectangle: GPUFixedRectangle) -> Bool {
        let halfWidth = rectangle.width.rawValue / 2
        let halfHeight = rectangle.height.rawValue / 2
        let limit = halfWidth < halfHeight ? halfWidth : halfHeight
        return topLeft.rawValue <= limit
            && topRight.rawValue <= limit
            && bottomRight.rawValue <= limit
            && bottomLeft.rawValue <= limit
    }

    private init(
        uncheckedTopLeft topLeft: GPUFixed16,
        topRight: GPUFixed16,
        bottomRight: GPUFixed16,
        bottomLeft: GPUFixed16
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }
}

/// One solid-color quad. Zero radii select the simplest rectangular shader
/// path; nonzero radii request analytic antialiasing in the backend's shader.
struct GPUQuadInstance: Equatable {
    let bounds: GPUFixedRectangle
    let color: GPUPremultipliedColor
    let cornerRadii: GPUCornerRadii
    let blendMode: GPUBlendMode

    init?(
        bounds: GPUFixedRectangle,
        color: GPUPremultipliedColor,
        cornerRadii: GPUCornerRadii = .zero,
        blendMode: GPUBlendMode = .sourceOver
    ) {
        guard cornerRadii.fits(bounds) else { return nil }
        self.bounds = bounds
        self.color = color
        self.cornerRadii = cornerRadii
        self.blendMode = blendMode
    }

    var isRounded: Bool { !cornerRadii.isZero }
}

enum GPUGlyphCoverage: UInt8, Equatable {
    /// One-channel coverage atlas suitable for grayscale antialiasing.
    case mask
    /// Signed-distance atlas interpreted by a backend shader.
    case signedDistance
}

enum GPUTextureFilter: UInt8, Equatable {
    case nearest
    case linear
}

/// A glyph atlas draw keeps layout, atlas identity, UVs, and tint in the IR.
/// Font parsing and atlas upload remain separate resource-management concerns.
struct GPUGlyphAtlasInstance: Equatable {
    let atlas: GPUTextureID
    let bounds: GPUFixedRectangle
    let textureRegion: GPUTextureRegion
    let color: GPUPremultipliedColor
    let coverage: GPUGlyphCoverage
    let filter: GPUTextureFilter
    let blendMode: GPUBlendMode

    init(
        atlas: GPUTextureID,
        bounds: GPUFixedRectangle,
        textureRegion: GPUTextureRegion,
        color: GPUPremultipliedColor,
        coverage: GPUGlyphCoverage = .mask,
        filter: GPUTextureFilter = .linear,
        blendMode: GPUBlendMode = .sourceOver
    ) {
        self.atlas = atlas
        self.bounds = bounds
        self.textureRegion = textureRegion
        self.color = color
        self.coverage = coverage
        self.filter = filter
        self.blendMode = blendMode
    }
}

/// Ordered render intent. State commands affect subsequent draw commands in
/// the current pass and reset to identity/full-target at every begin-pass.
enum GPURenderCommand: Equatable {
    case beginRenderPass(GPURenderPassDescriptor)
    case setScissor(GPUScissorState)
    case setTransform(GPUTransform2D)
    case drawQuad(GPUQuadInstance)
    case drawGlyph(GPUGlyphAtlasInstance)
    case endRenderPass
}
