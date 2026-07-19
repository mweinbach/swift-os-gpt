/// One optional boot-label pass over an existing GPU desktop target.
struct GPUBootTextSceneFrame {
    let commandBuffer: GPURenderCommandBuffer
    /// The visible logical top bar mapped into the physical target.
    let renderScissor: GPUScissorRectangle
    /// Conservative scanout damage for the pixels the glyph pass can change.
    let presentationDamage: GPUScissorRectangle
    let drawnGlyphCount: Int
    let viewportScale: Int
}

enum GPUBootTextSceneRejection: Equatable {
    case invalidPhysicalExtent
    case displayModeRejected
    case viewportRejected
    case physicalGeometryOutOfRange
    case commandRecorderRejected
    case commandRecordingFailed(GPUCommandRecordRejection)
    case commandSealFailed(GPUCommandBufferSealRejection)
}

enum GPUBootTextSceneResult {
    case frame(GPUBootTextSceneFrame)
    /// A valid target whose centered logical crop does not expose the label.
    case nothingVisible
    case rejected(GPUBootTextSceneRejection)
}

/// Builds the allocation-free `SWIFTOS` mask-font overlay for the boot desktop.
///
/// The command stream loads and preserves the existing color attachment. It is
/// device-neutral: atlas upload, shader selection, and queue submission remain
/// responsibilities of the eventual GPU backend.
enum GPUBootTextScene {
    static let logicalWidth = 800
    static let logicalHeight = 600
    static let topBarHeight = 44
    static let labelOriginX = 18
    static let labelOriginY = 15
    static let logicalGlyphWidth = 10
    static let logicalGlyphHeight = 14
    static let logicalGlyphAdvance = 12
    static let glyphCount = 7
    static let maximumPhysicalCoordinate: UInt32 = 32_767

    static func makeFrame(
        physicalWidth: UInt32,
        physicalHeight: UInt32,
        atlas: GPUTextureID,
        target: GPURenderTargetID,
        commandBufferID: GPUCommandBufferID,
        preferredScale: Int? = nil
    ) -> GPUBootTextSceneResult {
        guard physicalWidth > 0,
              physicalHeight > 0,
              physicalWidth <= maximumPhysicalCoordinate,
              physicalHeight <= maximumPhysicalCoordinate
        else {
            return .rejected(.invalidPhysicalExtent)
        }
        guard let mode = DisplayMode(
                  widthInPixels: physicalWidth,
                  heightInPixels: physicalHeight,
                  refreshRateMilliHertz: nil,
                  pixelFormat: .b8g8r8a8
              )
        else {
            return .rejected(.displayModeRejected)
        }
        guard let viewport = DisplayViewport(
                  mode: mode,
                  logicalWidth: logicalWidth,
                  logicalHeight: logicalHeight,
                  preferredScale: preferredScale
              )
        else {
            return .rejected(.viewportRejected)
        }

        let logicalTextBounds = Rectangle(
            x: labelOriginX,
            y: labelOriginY,
            width: (glyphCount - 1) * logicalGlyphAdvance
                + logicalGlyphWidth,
            height: logicalGlyphHeight
        )
        guard let visibleText = viewport.transformClipped(logicalTextBounds)
        else {
            return .nothingVisible
        }
        let logicalTopBar = Rectangle(
            x: 0,
            y: 0,
            width: logicalWidth,
            height: topBarHeight
        )
        guard let visibleTopBar = viewport.transformClipped(logicalTopBar) else {
            return .nothingVisible
        }
        guard let targetExtent = GPUPixelExtent(
                  width: physicalWidth,
                  height: physicalHeight
              ),
              let renderScissor = scissor(for: visibleTopBar),
              let presentationDamage = scissor(for: visibleText)
        else {
            return .rejected(.physicalGeometryOutOfRange)
        }

        let requiredCommandCount = glyphCount + 3
        guard var recorder = GPUCommandRecorder(
                  id: commandBufferID,
                  capacity: requiredCommandCount
              )
        else {
            return .rejected(.commandRecorderRejected)
        }
        let pass = GPURenderPassDescriptor(
            target: target,
            extent: targetExtent,
            format: .bgra8UNormSRGB,
            loadAction: .load
        )
        if let rejection = record(.beginRenderPass(pass), into: &recorder) {
            return .rejected(.commandRecordingFailed(rejection))
        }
        if let rejection = record(
            .setScissor(.rectangle(renderScissor)),
            into: &recorder
        ) {
            return .rejected(.commandRecordingFailed(rejection))
        }

        var glyphIndex = 0
        while glyphIndex < glyphCount {
            guard let scalar = literalScalar(at: glyphIndex),
                  let physicalBounds = physicalGlyphBounds(
                      at: glyphIndex,
                      viewport: viewport
                  ),
                  let fixedBounds = fixedRectangle(physicalBounds)
            else {
                return .rejected(.physicalGeometryOutOfRange)
            }
            let atlasGlyph = GPUMaskFontAtlasLayout.glyph(for: scalar)
            let instance = GPUGlyphAtlasInstance(
                atlas: atlas,
                bounds: fixedBounds,
                textureRegion: atlasGlyph.maskTextureRegion,
                color: .opaqueWhite,
                coverage: .mask,
                filter: .nearest,
                blendMode: .sourceOver
            )
            if let rejection = record(
                .drawGlyph(instance),
                into: &recorder
            ) {
                return .rejected(.commandRecordingFailed(rejection))
            }
            glyphIndex += 1
        }

        if let rejection = record(.endRenderPass, into: &recorder) {
            return .rejected(.commandRecordingFailed(rejection))
        }
        switch recorder.seal() {
        case .sealed(let commandBuffer):
            return .frame(
                GPUBootTextSceneFrame(
                    commandBuffer: commandBuffer,
                    renderScissor: renderScissor,
                    presentationDamage: presentationDamage,
                    drawnGlyphCount: glyphCount,
                    viewportScale: viewport.scale
                )
            )
        case .rejected(let rejection):
            return .rejected(.commandSealFailed(rejection))
        }
    }

    /// Literal scalar access avoids materializing a String or byte collection.
    static func literalScalar(at index: Int) -> UInt32? {
        switch index {
        case 0: return 83  // S
        case 1: return 87  // W
        case 2: return 73  // I
        case 3: return 70  // F
        case 4: return 84  // T
        case 5: return 79  // O
        case 6: return 83  // S
        default: return nil
        }
    }

    private static func physicalGlyphBounds(
        at index: Int,
        viewport: DisplayViewport
    ) -> Rectangle? {
        let logicalOrigin = Point(
            x: labelOriginX + index * logicalGlyphAdvance,
            y: labelOriginY
        )
        guard let physicalOrigin = viewport.transform(logicalOrigin),
              let width = viewport.scaledLength(logicalGlyphWidth),
              let height = viewport.scaledLength(logicalGlyphHeight)
        else {
            return nil
        }
        return Rectangle(
            x: physicalOrigin.x,
            y: physicalOrigin.y,
            width: width,
            height: height
        )
    }

    private static func fixedRectangle(
        _ rectangle: Rectangle
    ) -> GPUFixedRectangle? {
        guard let x = GPUFixed16(whole: rectangle.x),
              let y = GPUFixed16(whole: rectangle.y),
              let width = GPUFixed16(whole: rectangle.width),
              let height = GPUFixed16(whole: rectangle.height)
        else {
            return nil
        }
        return GPUFixedRectangle(x: x, y: y, width: width, height: height)
    }

    private static func scissor(
        for rectangle: Rectangle
    ) -> GPUScissorRectangle? {
        guard rectangle.x >= 0,
              rectangle.y >= 0,
              rectangle.width > 0,
              rectangle.height > 0,
              let x = UInt32(exactly: rectangle.x),
              let y = UInt32(exactly: rectangle.y),
              let width = UInt32(exactly: rectangle.width),
              let height = UInt32(exactly: rectangle.height)
        else {
            return nil
        }
        return GPUScissorRectangle(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private static func record(
        _ command: GPURenderCommand,
        into recorder: inout GPUCommandRecorder
    ) -> GPUCommandRecordRejection? {
        switch recorder.record(command) {
        case .recorded:
            return nil
        case .rejected(let rejection):
            return rejection
        }
    }
}
