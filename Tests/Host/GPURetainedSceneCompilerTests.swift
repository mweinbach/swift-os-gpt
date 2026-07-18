@main
struct GPURetainedSceneCompilerTests {
    static func main() {
        compilesFullDamageAsClearInPainterOrder()
        clearsLetterboxForFullSceneDamage()
        mapsViewportDamageClipOpacityAndCornerRadius()
        handlesEmptyCroppedAndInvalidDamage()
        reportsExactCommandCapacityRequirements()
        print("GPU retained scene compiler host tests: 5 groups passed")
    }

    private static func compilesFullDamageAsClearInPainterOrder() {
        let viewport = requireViewport(
            physicalWidth: 64,
            physicalHeight: 48,
            logicalWidth: 64,
            logicalHeight: 48
        )
        var tree = requireTree(capacity: 4)
        _ = tree.insert(
            requireLayer(
                id: 20,
                color: .red,
                frame: Rectangle(x: 4, y: 4, width: 20, height: 12),
                zOrder: 10
            )
        )
        _ = tree.insert(
            requireLayer(
                id: 10,
                color: .green,
                frame: Rectangle(x: 1, y: 2, width: 30, height: 20),
                zOrder: -2
            )
        )
        _ = tree.insert(
            requireLayer(
                id: 30,
                color: .blue,
                frame: Rectangle(x: 0, y: 0, width: 8, height: 8),
                isVisible: false
            )
        )
        _ = tree.insert(
            requireLayer(
                id: 40,
                color: .yellow,
                frame: Rectangle(x: 0, y: 0, width: 8, height: 8),
                opacity: 0
            )
        )
        var damage = requireDamage(width: 64, height: 48)
        damage.addFullDamage()

        let compilation = requireCompilation(
            tree: tree,
            damage: damage,
            viewport: viewport
        )
        expect(compilation.usedAttachmentClear, "full damage did not clear")
        expect(compilation.drawnLayerCount == 2, "hidden layers were emitted")
        expect(
            compilation.physicalDamage
                == requireScissor(x: 0, y: 0, width: 64, height: 48),
            "full physical damage mismatch"
        )
        expect(compilation.commandBuffer.commandCount == 5, "command count")

        guard case .beginRenderPass(let pass)? = command(
                  compilation,
                  at: 0
              ),
              case .clear(let clearColor) = pass.loadAction
        else {
            fatalError("full-damage pass did not encode an attachment clear")
        }
        expect(
            clearColor
                == requireColor(
                    red: 120,
                    green: 232,
                    blue: 847,
                    alpha: .max
                ),
            "background clear color mismatch"
        )
        expectScissor(
            command(compilation, at: 1),
            equals: requireScissor(x: 0, y: 0, width: 64, height: 48),
            "full-damage scissor"
        )
        let back = requireQuad(command(compilation, at: 2))
        let front = requireQuad(command(compilation, at: 3))
        expect(
            back.color.red == 952 && back.color.green == 36_542,
            "lower-z layer was not emitted first"
        )
        expect(
            front.color.red == 56_515 && front.color.green == 3_777,
            "higher-z layer was not emitted second"
        )
        expect(back.bounds.x == fixed(1), "back layer x")
        expect(front.bounds.x == fixed(4), "front layer x")
        expect(
            command(compilation, at: 4) == .endRenderPass,
            "render pass was not ended"
        )
    }

    private static func clearsLetterboxForFullSceneDamage() {
        let viewport = requireViewport(
            physicalWidth: 100,
            physicalHeight: 60,
            logicalWidth: 40,
            logicalHeight: 20,
            preferredScale: 2
        )
        expect(viewport.origin.x == 10, "letterbox x origin")
        expect(viewport.origin.y == 10, "letterbox y origin")
        let tree = requireTree(capacity: 1)
        var damage = requireDamage(width: 40, height: 20)
        damage.addFullDamage()

        let compilation = requireCompilation(
            tree: tree,
            damage: damage,
            viewport: viewport
        )
        expect(
            compilation.usedAttachmentClear,
            "first frame left letterbox pixels uninitialized"
        )
        expect(
            compilation.physicalDamage
                == requireScissor(x: 10, y: 10, width: 80, height: 40),
            "logical content scissor did not preserve letterbox"
        )
        guard case .beginRenderPass(let pass)? = command(compilation, at: 0),
              case .clear = pass.loadAction
        else {
            fatalError("letterboxed first frame did not clear attachment")
        }
    }

    private static func mapsViewportDamageClipOpacityAndCornerRadius() {
        let viewport = requireViewport(
            physicalWidth: 1_920,
            physicalHeight: 1_080,
            logicalWidth: 800,
            logicalHeight: 500,
            preferredScale: 2
        )
        expect(viewport.origin.x == 160, "viewport x origin")
        expect(viewport.origin.y == 40, "viewport y origin")

        var tree = requireTree(capacity: 2)
        _ = tree.insert(
            requireLayer(
                id: 1,
                color: PixelColor(xrgb: 0x0080_4020),
                frame: Rectangle(x: 10, y: 10, width: 100, height: 40),
                clip: Rectangle(x: 20, y: 15, width: 30, height: 20),
                opacity: 128,
                cornerRadius: 10
            )
        )
        _ = tree.insert(
            requireLayer(
                id: 2,
                color: .white,
                frame: Rectangle(x: 0, y: 0, width: 10, height: 10),
                zOrder: 1
            )
        )
        var damage = requireDamage(width: 800, height: 500)
        damage.add(Rectangle(x: 0, y: 0, width: 20, height: 20))
        damage.add(Rectangle(x: 40, y: 30, width: 20, height: 20))

        let compilation = requireCompilation(
            tree: tree,
            damage: damage,
            viewport: viewport
        )
        expect(!compilation.usedAttachmentClear, "partial damage cleared target")
        expect(compilation.drawnLayerCount == 2, "visible layer was omitted")
        expect(compilation.commandBuffer.commandCount == 8, "partial commands")
        expect(
            compilation.physicalDamage
                == requireScissor(x: 160, y: 40, width: 120, height: 100),
            "damage rectangles were not conservatively coalesced"
        )

        guard case .beginRenderPass(let pass)? = command(
                  compilation,
                  at: 0
              )
        else {
            fatalError("partial render pass missing")
        }
        expect(pass.loadAction == .load, "partial pass did not preserve target")
        expectScissor(
            command(compilation, at: 1),
            equals: compilation.physicalDamage,
            "coalesced damage scissor"
        )

        let background = requireQuad(command(compilation, at: 2))
        expect(background.blendMode == .copy, "background did not replace")
        expect(background.bounds.x == .zero, "background x")
        expect(background.bounds.y == .zero, "background y")
        expect(background.bounds.width == fixed(1_920), "background width")
        expect(background.bounds.height == fixed(1_080), "background height")

        expectScissor(
            command(compilation, at: 3),
            equals: requireScissor(x: 200, y: 70, width: 60, height: 40),
            "layer clip did not map through the viewport"
        )
        let layer = requireQuad(command(compilation, at: 4))
        expect(layer.bounds.x == fixed(180), "scaled layer x")
        expect(layer.bounds.y == fixed(60), "scaled layer y")
        expect(layer.bounds.width == fixed(200), "scaled layer width")
        expect(layer.bounds.height == fixed(80), "scaled layer height")
        expect(layer.cornerRadii.topLeft == fixed(20), "scaled corner radius")
        expect(
            layer.color
                == requireColor(
                    red: 7_131,
                    green: 1_676,
                    blue: 425,
                    alpha: 32_896
                ),
            "layer opacity was not premultiplied"
        )
        expect(layer.blendMode == .sourceOver, "layer blend mode")
        expectScissor(
            command(compilation, at: 5),
            equals: compilation.physicalDamage,
            "layer clip leaked into the next painter item"
        )
        let upperLayer = requireQuad(command(compilation, at: 6))
        expect(
            upperLayer.color
                == requireColor(
                    red: 61_489,
                    green: 62_629,
                    blue: 63_782,
                    alpha: .max
                ),
            "upper layer painter order"
        )
        expect(
            command(compilation, at: 7) == .endRenderPass,
            "partial render pass was not ended"
        )
    }

    private static func handlesEmptyCroppedAndInvalidDamage() {
        let viewport = requireViewport(
            physicalWidth: 8,
            physicalHeight: 8,
            logicalWidth: 8,
            logicalHeight: 8
        )
        let tree = requireTree(capacity: 1)
        let empty = requireDamage(width: 8, height: 8)
        expectNothing(
            compile(tree: tree, damage: empty, viewport: viewport),
            "empty damage emitted commands"
        )

        var wrongBounds = requireDamage(width: 7, height: 8)
        wrongBounds.addFullDamage()
        expectRejected(
            compile(tree: tree, damage: wrongBounds, viewport: viewport),
            .damageBoundsDoNotMatchViewport,
            "mismatched damage bounds"
        )

        let croppedViewport = requireViewport(
            physicalWidth: 320,
            physicalHeight: 200,
            logicalWidth: 800,
            logicalHeight: 600
        )
        var croppedDamage = requireDamage(width: 800, height: 600)
        croppedDamage.add(Rectangle(x: 0, y: 0, width: 10, height: 10))
        expectNothing(
            compile(
                tree: tree,
                damage: croppedDamage,
                viewport: croppedViewport
            ),
            "fully cropped damage emitted commands"
        )
    }

    private static func reportsExactCommandCapacityRequirements() {
        let viewport = requireViewport(
            physicalWidth: 20,
            physicalHeight: 20,
            logicalWidth: 20,
            logicalHeight: 20
        )
        var tree = requireTree(capacity: 1)
        _ = tree.insert(
            requireLayer(
                id: 1,
                color: .cyan,
                frame: Rectangle(x: 0, y: 0, width: 20, height: 20)
            )
        )
        var damage = requireDamage(width: 20, height: 20)
        damage.add(Rectangle(x: 2, y: 3, width: 4, height: 5))

        expectRejected(
            compile(
                tree: tree,
                damage: damage,
                viewport: viewport,
                commandCapacity: 4
            ),
            .commandCapacityExceeded(required: 5, available: 4),
            "capacity rejection did not report exact requirement"
        )
        expectRejected(
            compile(
                tree: tree,
                damage: damage,
                viewport: viewport,
                commandCapacity: GPUCommandRecorder.maximumCommandCount + 1
            ),
            .invalidCommandCapacity(
                requested: GPUCommandRecorder.maximumCommandCount + 1,
                maximum: GPUCommandRecorder.maximumCommandCount
            ),
            "invalid recorder capacity was accepted"
        )
    }

    private static func compile(
        tree: RetainedLayerTree,
        damage: DamageRegion,
        viewport: DisplayViewport,
        commandCapacity: Int = GPUCommandRecorder.maximumCommandCount
    ) -> GPURetainedSceneCompileResult {
        GPURetainedSceneCompiler.compile(
            tree: tree,
            damage: damage,
            viewport: viewport,
            backgroundColor: .wallpaper,
            target: requireTarget(1),
            targetFormat: .bgra8UNormSRGB,
            commandBufferID: requireCommandBufferID(1),
            commandCapacity: commandCapacity
        )
    }

    private static func requireCompilation(
        tree: RetainedLayerTree,
        damage: DamageRegion,
        viewport: DisplayViewport
    ) -> GPURetainedSceneCompilation {
        switch compile(tree: tree, damage: damage, viewport: viewport) {
        case .compiled(let compilation):
            return compilation
        case .nothingToRender:
            fatalError("valid scene produced no GPU commands")
        case .rejected(let rejection):
            fatalError("valid scene rejected: \(rejection)")
        }
    }

    private static func command(
        _ compilation: GPURetainedSceneCompilation,
        at index: Int
    ) -> GPURenderCommand? {
        compilation.commandBuffer.command(at: index)
    }

    private static func requireQuad(
        _ command: GPURenderCommand?
    ) -> GPUQuadInstance {
        guard case .drawQuad(let quad)? = command else {
            fatalError("expected quad command")
        }
        return quad
    }

    private static func expectScissor(
        _ command: GPURenderCommand?,
        equals expected: GPUScissorRectangle,
        _ message: String
    ) {
        guard case .setScissor(.rectangle(let actual))? = command else {
            fatalError("\(message): missing scissor command")
        }
        expect(actual == expected, message)
    }

    private static func expectNothing(
        _ result: GPURetainedSceneCompileResult,
        _ message: String
    ) {
        guard case .nothingToRender = result else { fatalError(message) }
    }

    private static func expectRejected(
        _ result: GPURetainedSceneCompileResult,
        _ expected: GPURetainedSceneCompileRejection,
        _ message: String
    ) {
        guard case .rejected(let actual) = result, actual == expected else {
            fatalError(message)
        }
    }

    private static func requireViewport(
        physicalWidth: UInt32,
        physicalHeight: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        preferredScale: Int? = nil
    ) -> DisplayViewport {
        guard let mode = DisplayMode(
                  widthInPixels: physicalWidth,
                  heightInPixels: physicalHeight,
                  refreshRateMilliHertz: 60_000,
                  pixelFormat: .b8g8r8x8
              ),
              let viewport = DisplayViewport(
                  mode: mode,
                  logicalWidth: logicalWidth,
                  logicalHeight: logicalHeight,
                  preferredScale: preferredScale
              )
        else {
            fatalError("valid viewport rejected")
        }
        return viewport
    }

    private static func requireTree(capacity: Int) -> RetainedLayerTree {
        guard let tree = RetainedLayerTree(capacity: capacity) else {
            fatalError("valid retained tree rejected")
        }
        return tree
    }

    private static func requireDamage(
        width: Int,
        height: Int
    ) -> DamageRegion {
        guard let damage = DamageRegion(
                  logicalBounds: Rectangle(
                      x: 0,
                      y: 0,
                      width: width,
                      height: height
                  )
              )
        else {
            fatalError("valid damage region rejected")
        }
        return damage
    }

    private static func requireLayer(
        id: UInt64,
        color: PixelColor,
        frame: Rectangle,
        clip: Rectangle? = nil,
        opacity: UInt8 = .max,
        cornerRadius: Int = 0,
        zOrder: Int32 = 0,
        isVisible: Bool = true
    ) -> RetainedLayer {
        guard let layerID = LayerID(rawValue: id),
              let layer = RetainedLayer(
                  id: layerID,
                  content: .solidColor(color),
                  frame: frame,
                  clip: clip,
                  opacity: opacity,
                  cornerRadius: cornerRadius,
                  zOrder: zOrder,
                  isVisible: isVisible
              )
        else {
            fatalError("valid retained layer rejected")
        }
        return layer
    }

    private static func requireScissor(
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32
    ) -> GPUScissorRectangle {
        guard let rectangle = GPUScissorRectangle(
                  x: x,
                  y: y,
                  width: width,
                  height: height
              )
        else {
            fatalError("valid scissor rejected")
        }
        return rectangle
    }

    private static func requireColor(
        red: UInt16,
        green: UInt16,
        blue: UInt16,
        alpha: UInt16
    ) -> GPUPremultipliedColor {
        guard let color = GPUPremultipliedColor(
                  red: red,
                  green: green,
                  blue: blue,
                  alpha: alpha
              )
        else {
            fatalError("valid premultiplied color rejected")
        }
        return color
    }

    private static func requireTarget(_ rawValue: UInt32) -> GPURenderTargetID {
        guard let target = GPURenderTargetID(rawValue: rawValue) else {
            fatalError("valid target rejected")
        }
        return target
    }

    private static func requireCommandBufferID(
        _ rawValue: UInt64
    ) -> GPUCommandBufferID {
        guard let id = GPUCommandBufferID(rawValue: rawValue) else {
            fatalError("valid command buffer ID rejected")
        }
        return id
    }

    private static func fixed(_ whole: Int) -> GPUFixed16 {
        guard let value = GPUFixed16(whole: whole) else {
            fatalError("valid fixed value rejected")
        }
        return value
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
