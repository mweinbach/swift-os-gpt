/// Converts the retained logical scene into device-neutral GPU render intent.
///
/// Compilation is allocation-free: the retained tree and damage region use
/// inline storage, and the resulting command buffer owns a fixed-capacity
/// inline command stream. This layer never receives a framebuffer address;
/// only a hardware backend may translate the result for a GPU queue.
enum GPURetainedSceneCompiler {
    static func compile(
        tree: RetainedLayerTree,
        damage: DamageRegion,
        viewport: DisplayViewport,
        backgroundColor: PixelColor,
        target: GPURenderTargetID,
        targetFormat: GPUColorAttachmentFormat,
        commandBufferID: GPUCommandBufferID,
        commandCapacity: Int = GPUCommandRecorder.maximumCommandCount
    ) -> GPURetainedSceneCompileResult {
        guard sameRectangle(damage.logicalBounds, viewport.logicalBounds) else {
            return .rejected(.damageBoundsDoNotMatchViewport)
        }
        guard commandCapacity > 0,
              commandCapacity <= GPUCommandRecorder.maximumCommandCount
        else {
            return .rejected(
                .invalidCommandCapacity(
                    requested: commandCapacity,
                    maximum: GPUCommandRecorder.maximumCommandCount
                )
            )
        }
        guard let targetExtent = pixelExtent(for: viewport) else {
            return .rejected(.targetExtentOutOfRange)
        }
        guard let logicalDamage = damage.boundingRectangle,
              let physicalDamageRectangle = viewport.transformClipped(
                  logicalDamage
              ),
              let physicalDamage = scissor(
                  for: physicalDamageRectangle
              )
        else {
            return .nothingToRender
        }

        // Full logical damage is also the first-frame contract. Clear the
        // complete attachment so centered/cropped viewports cannot expose
        // uninitialized pixels in letterbox regions outside logical content.
        let clearsAttachment = damage.isFullDamage
        let preflight = preflight(
            tree: tree,
            logicalDamage: logicalDamage,
            physicalDamage: physicalDamage,
            viewport: viewport,
            clearsAttachment: clearsAttachment
        )
        let requiredCommandCount: Int
        let drawnLayerCount: Int
        switch preflight {
        case .accepted(let required, let drawn):
            requiredCommandCount = required
            drawnLayerCount = drawn
        case .rejected(let rejection):
            return .rejected(rejection)
        }
        guard requiredCommandCount <= commandCapacity else {
            return .rejected(
                .commandCapacityExceeded(
                    required: requiredCommandCount,
                    available: commandCapacity
                )
            )
        }
        guard var recorder = GPUCommandRecorder(
                  id: commandBufferID,
                  capacity: commandCapacity
              )
        else {
            return .rejected(
                .invalidCommandCapacity(
                    requested: commandCapacity,
                    maximum: GPUCommandRecorder.maximumCommandCount
                )
            )
        }

        guard let background = premultipliedColor(
                  backgroundColor,
                  opacity: .max
              )
        else {
            return .rejected(.colorEncodingFailed)
        }
        let loadAction: GPURenderPassLoadAction = clearsAttachment
            ? .clear(background)
            : .load
        let pass = GPURenderPassDescriptor(
            target: target,
            extent: targetExtent,
            format: targetFormat,
            loadAction: loadAction
        )
        if let rejection = record(.beginRenderPass(pass), into: &recorder) {
            return .rejected(.commandRecordingFailed(rejection))
        }
        if let rejection = record(
            .setScissor(.rectangle(physicalDamage)),
            into: &recorder
        ) {
            return .rejected(.commandRecordingFailed(rejection))
        }

        if !clearsAttachment {
            guard let targetBounds = fixedRectangle(
                      Rectangle(
                          x: 0,
                          y: 0,
                          width: viewport.physicalWidth,
                          height: viewport.physicalHeight
                      )
                  ),
                  let backgroundQuad = GPUQuadInstance(
                      bounds: targetBounds,
                      color: background,
                      blendMode: .copy
                  )
            else {
                return .rejected(.targetGeometryOutOfRange)
            }
            if let rejection = record(
                .drawQuad(backgroundQuad),
                into: &recorder
            ) {
                return .rejected(.commandRecordingFailed(rejection))
            }
        }

        var currentScissor = physicalDamage
        var painterIndex = 0
        while painterIndex < tree.count {
            guard let layer = tree.layer(atPainterIndex: painterIndex) else {
                return .rejected(.retainedTreeTraversalFailed)
            }
            painterIndex += 1
            switch preparedLayer(
                layer,
                logicalDamage: logicalDamage,
                physicalDamage: physicalDamage,
                viewport: viewport
            ) {
            case .notVisible:
                continue
            case .rejected(let rejection):
                return .rejected(rejection)
            case .prepared(let prepared):
                if prepared.scissor != currentScissor {
                    if let rejection = record(
                        .setScissor(.rectangle(prepared.scissor)),
                        into: &recorder
                    ) {
                        return .rejected(.commandRecordingFailed(rejection))
                    }
                    currentScissor = prepared.scissor
                }
                if let rejection = record(
                    .drawQuad(prepared.quad),
                    into: &recorder
                ) {
                    return .rejected(.commandRecordingFailed(rejection))
                }
            }
        }

        if let rejection = record(.endRenderPass, into: &recorder) {
            return .rejected(.commandRecordingFailed(rejection))
        }
        switch recorder.seal() {
        case .sealed(let commandBuffer):
            return .compiled(
                GPURetainedSceneCompilation(
                    commandBuffer: commandBuffer,
                    physicalDamage: physicalDamage,
                    drawnLayerCount: drawnLayerCount,
                    usedAttachmentClear: clearsAttachment
                )
            )
        case .rejected(let rejection):
            return .rejected(.commandSealFailed(rejection))
        }
    }

    private static func preflight(
        tree: RetainedLayerTree,
        logicalDamage: Rectangle,
        physicalDamage: GPUScissorRectangle,
        viewport: DisplayViewport,
        clearsAttachment: Bool
    ) -> GPURetainedScenePreflightResult {
        // begin-pass + base scissor + end-pass, plus a background draw when a
        // partial repaint must preserve the rest of the attachment.
        var required = clearsAttachment ? 3 : 4
        var drawn = 0
        var currentScissor = physicalDamage
        var painterIndex = 0
        while painterIndex < tree.count {
            guard let layer = tree.layer(atPainterIndex: painterIndex) else {
                return .rejected(.retainedTreeTraversalFailed)
            }
            painterIndex += 1
            switch preparedLayer(
                layer,
                logicalDamage: logicalDamage,
                physicalDamage: physicalDamage,
                viewport: viewport
            ) {
            case .notVisible:
                continue
            case .rejected(let rejection):
                return .rejected(rejection)
            case .prepared(let prepared):
                if prepared.scissor != currentScissor {
                    required += 1
                    currentScissor = prepared.scissor
                }
                required += 1
                drawn += 1
            }
        }
        return .accepted(requiredCommandCount: required, drawnLayerCount: drawn)
    }

    private static func preparedLayer(
        _ layer: RetainedLayer,
        logicalDamage: Rectangle,
        physicalDamage: GPUScissorRectangle,
        viewport: DisplayViewport
    ) -> GPURetainedLayerPreparationResult {
        guard layer.isVisible, layer.opacity != 0,
              let visibleBounds = layer.visibleBounds,
              intersection(visibleBounds, logicalDamage) != nil
        else {
            return .notVisible
        }

        let logicalScissor: Rectangle
        if let clip = layer.clip {
            guard let clipped = intersection(clip, logicalDamage) else {
                return .notVisible
            }
            logicalScissor = clipped
        } else {
            logicalScissor = logicalDamage
        }
        guard let mappedScissor = viewport.transformClipped(logicalScissor),
              let layerScissor = scissor(for: mappedScissor),
              let effectiveScissor = intersection(
                  layerScissor,
                  physicalDamage
              )
        else {
            return .notVisible
        }

        guard let mappedOrigin = viewport.transform(
                  Point(x: layer.frame.x, y: layer.frame.y)
              ),
              let mappedWidth = viewport.scaledLength(layer.frame.width),
              let mappedHeight = viewport.scaledLength(layer.frame.height),
              let mappedRadius = viewport.scaledLength(layer.cornerRadius),
              let bounds = fixedRectangle(
                  Rectangle(
                      x: mappedOrigin.x,
                      y: mappedOrigin.y,
                      width: mappedWidth,
                      height: mappedHeight
                  )
              ),
              let radius = GPUFixed16(whole: mappedRadius),
              let cornerRadii = GPUCornerRadii.uniform(radius)
        else {
            return .rejected(.layerGeometryOutOfRange(layer: layer.id))
        }

        let color: GPUPremultipliedColor
        switch layer.content {
        case .solidColor(let pixelColor):
            guard let encoded = premultipliedColor(
                      pixelColor,
                      opacity: layer.opacity
                  )
            else {
                return .rejected(.colorEncodingFailed)
            }
            color = encoded
        }
        guard let quad = GPUQuadInstance(
                  bounds: bounds,
                  color: color,
                  cornerRadii: cornerRadii,
                  blendMode: .sourceOver
              )
        else {
            return .rejected(.layerGeometryOutOfRange(layer: layer.id))
        }
        return .prepared(
            GPURetainedPreparedLayer(scissor: effectiveScissor, quad: quad)
        )
    }

    private static func pixelExtent(
        for viewport: DisplayViewport
    ) -> GPUPixelExtent? {
        guard viewport.physicalWidth > 0,
              viewport.physicalHeight > 0,
              let width = UInt32(exactly: viewport.physicalWidth),
              let height = UInt32(exactly: viewport.physicalHeight)
        else {
            return nil
        }
        return GPUPixelExtent(width: width, height: height)
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
        return GPUScissorRectangle(x: x, y: y, width: width, height: height)
    }

    private static func intersection(
        _ first: GPUScissorRectangle,
        _ second: GPUScissorRectangle
    ) -> GPUScissorRectangle? {
        let startX = maximum(first.x, second.x)
        let startY = maximum(first.y, second.y)
        let endX = minimum(first.endX, second.endX)
        let endY = minimum(first.endY, second.endY)
        guard startX < endX, startY < endY else { return nil }
        return GPUScissorRectangle(
            x: startX,
            y: startY,
            width: endX - startX,
            height: endY - startY
        )
    }

    private static func intersection(
        _ first: Rectangle,
        _ second: Rectangle
    ) -> Rectangle? {
        let firstEndX = first.x + first.width
        let firstEndY = first.y + first.height
        let secondEndX = second.x + second.width
        let secondEndY = second.y + second.height
        let startX = maximum(first.x, second.x)
        let startY = maximum(first.y, second.y)
        let endX = minimum(firstEndX, secondEndX)
        let endY = minimum(firstEndY, secondEndY)
        guard startX < endX, startY < endY else { return nil }
        return Rectangle(
            x: startX,
            y: startY,
            width: endX - startX,
            height: endY - startY
        )
    }

    private static func premultipliedColor(
        _ color: PixelColor,
        opacity: UInt8
    ) -> GPUPremultipliedColor? {
        let red = linearized(
            UInt8(truncatingIfNeeded: color.xrgb >> 16)
        )
        let green = linearized(
            UInt8(truncatingIfNeeded: color.xrgb >> 8)
        )
        let blue = linearized(UInt8(truncatingIfNeeded: color.xrgb))
        let alpha = UInt16(opacity) * 257
        return GPUPremultipliedColor(
            red: multiplyNormalized(red, alpha),
            green: multiplyNormalized(green, alpha),
            blue: multiplyNormalized(blue, alpha),
            alpha: alpha
        )
    }

    /// Allocation-free sRGB decode using the standard cubic approximation:
    /// c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878).
    /// Coefficients sum to one in Q16, preserving both exact endpoints.
    private static func linearized(_ channel: UInt8) -> UInt16 {
        let encoded = UInt16(channel) * 257
        let cubic = multiplyNormalized(encoded, 20_008)
        let quadratic = multiplyNormalized(
            encoded,
            cubic + 44_706
        )
        return multiplyNormalized(encoded, quadratic + 821)
    }

    private static func multiplyNormalized(
        _ first: UInt16,
        _ second: UInt16
    ) -> UInt16 {
        let product = UInt32(first) * UInt32(second)
        return UInt16((product + 32_767) / 65_535)
    }

    private static func sameRectangle(
        _ first: Rectangle,
        _ second: Rectangle
    ) -> Bool {
        first.x == second.x && first.y == second.y
            && first.width == second.width && first.height == second.height
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

    private static func minimum<T: Comparable>(_ left: T, _ right: T) -> T {
        left < right ? left : right
    }

    private static func maximum<T: Comparable>(_ left: T, _ right: T) -> T {
        left > right ? left : right
    }
}

struct GPURetainedSceneCompilation {
    let commandBuffer: GPURenderCommandBuffer
    let physicalDamage: GPUScissorRectangle
    let drawnLayerCount: Int
    let usedAttachmentClear: Bool
}

enum GPURetainedSceneCompileRejection: Equatable {
    case damageBoundsDoNotMatchViewport
    case invalidCommandCapacity(requested: Int, maximum: Int)
    case commandCapacityExceeded(required: Int, available: Int)
    case targetExtentOutOfRange
    case targetGeometryOutOfRange
    case layerGeometryOutOfRange(layer: LayerID)
    case colorEncodingFailed
    case retainedTreeTraversalFailed
    case commandRecordingFailed(GPUCommandRecordRejection)
    case commandSealFailed(GPUCommandBufferSealRejection)
}

enum GPURetainedSceneCompileResult {
    case nothingToRender
    case compiled(GPURetainedSceneCompilation)
    case rejected(GPURetainedSceneCompileRejection)
}

private struct GPURetainedPreparedLayer {
    let scissor: GPUScissorRectangle
    let quad: GPUQuadInstance
}

private enum GPURetainedLayerPreparationResult {
    case notVisible
    case prepared(GPURetainedPreparedLayer)
    case rejected(GPURetainedSceneCompileRejection)
}

private enum GPURetainedScenePreflightResult {
    case accepted(requiredCommandCount: Int, drawnLayerCount: Int)
    case rejected(GPURetainedSceneCompileRejection)
}
