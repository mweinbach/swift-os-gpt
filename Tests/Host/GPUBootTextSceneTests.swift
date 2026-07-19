@main
struct GPUBootTextSceneTests {
    static func main() {
        buildsExact1080pLoadPass()
        preservesLiteralOrderingAndAtlasRegions()
        mapsGlyphsAt4KIntegerScale()
        honorsPreferredViewportScale()
        returnsNothingForHiddenCenteredCrops()
        preservesPartiallyVisibleGeometryUnderScissor()
        rejectsInvalidExtentsAndViewportPreferences()
        validatesLiteralScalarAccess()
        print("GPU boot text scene host tests: 8 groups passed")
    }

    private static func buildsExact1080pLoadPass() {
        let frame = requireFrame(width: 1_920, height: 1_080)
        expect(frame.viewportScale == 1, "1080p viewport scale")
        expect(frame.drawnGlyphCount == 7, "1080p glyph count")
        expect(
            frame.renderScissor
                == scissor(x: 560, y: 240, width: 800, height: 44),
            "1080p top-bar scissor"
        )
        expect(
            frame.presentationDamage
                == scissor(x: 578, y: 255, width: 82, height: 14),
            "1080p text damage"
        )

        let commands = frame.commandBuffer
        expect(commands.id == commandID(11), "command-buffer ID changed")
        expect(commands.commandCount == 10, "1080p command count")
        expect(commands.renderPassCount == 1, "1080p render-pass count")
        guard case .beginRenderPass(let pass) = commands.command(at: 0),
              case .load = pass.loadAction,
              case .setScissor(.rectangle(let encodedScissor)) =
                  commands.command(at: 1),
              case .endRenderPass = commands.command(at: 9)
        else {
            fatalError("1080p command envelope")
        }
        expect(pass.target == target(9), "render target changed")
        expect(
            pass.extent == GPUPixelExtent(width: 1_920, height: 1_080),
            "render-pass extent"
        )
        expect(pass.format == .bgra8UNormSRGB, "render-pass format")
        expect(pass.storeAction == .store, "render-pass store action")
        expect(encodedScissor == frame.renderScissor, "encoded scissor")
        expect(commands.command(at: 10) == nil, "past-end command access")
    }

    private static func preservesLiteralOrderingAndAtlasRegions() {
        let frame = requireFrame(width: 1_920, height: 1_080)
        var index = 0
        while index < GPUBootTextScene.glyphCount {
            guard let scalar = GPUBootTextScene.literalScalar(at: index),
                  case .drawGlyph(let glyph) =
                      frame.commandBuffer.command(at: index + 2)
            else {
                fatalError("literal glyph command ordering")
            }
            let atlasGlyph = GPUMaskFontAtlasLayout.glyph(for: scalar)
            expect(
                glyph.textureRegion == atlasGlyph.maskTextureRegion,
                "literal glyph UV ordering"
            )
            expect(glyph.atlas == atlas(7), "atlas identity changed")
            expect(glyph.color == .opaqueWhite, "glyph color")
            expect(glyph.coverage == .mask, "glyph coverage")
            expect(glyph.filter == .nearest, "glyph filtering")
            expect(glyph.blendMode == .sourceOver, "glyph blending")
            expect(
                glyph.bounds.x == fixed(578 + index * 12),
                "glyph physical x ordering"
            )
            expect(glyph.bounds.y == fixed(255), "glyph physical y")
            expect(glyph.bounds.width == fixed(10), "glyph physical width")
            expect(glyph.bounds.height == fixed(14), "glyph physical height")
            index += 1
        }

        guard case .drawGlyph(let first) = frame.commandBuffer.command(at: 2),
              case .drawGlyph(let last) = frame.commandBuffer.command(at: 8)
        else {
            fatalError("repeated S glyphs missing")
        }
        expect(
            first.textureRegion == last.textureRegion,
            "repeated literal has inconsistent UVs"
        )
    }

    private static func mapsGlyphsAt4KIntegerScale() {
        let frame = requireFrame(width: 3_840, height: 2_160)
        expect(frame.viewportScale == 3, "4K viewport scale")
        expect(
            frame.renderScissor
                == scissor(x: 720, y: 180, width: 2_400, height: 132),
            "4K top-bar scissor"
        )
        expect(
            frame.presentationDamage
                == scissor(x: 774, y: 225, width: 246, height: 42),
            "4K text damage"
        )
        guard case .drawGlyph(let first) = frame.commandBuffer.command(at: 2),
              case .drawGlyph(let second) = frame.commandBuffer.command(at: 3),
              case .drawGlyph(let last) = frame.commandBuffer.command(at: 8)
        else {
            fatalError("4K glyph command order")
        }
        expect(first.bounds.x == fixed(774), "4K first x")
        expect(first.bounds.y == fixed(225), "4K first y")
        expect(first.bounds.width == fixed(30), "4K glyph width")
        expect(first.bounds.height == fixed(42), "4K glyph height")
        expect(second.bounds.x == fixed(810), "4K glyph advance")
        expect(last.bounds.x == fixed(990), "4K last x")
    }

    private static func honorsPreferredViewportScale() {
        let frame = requireFrame(
            width: 3_840,
            height: 2_160,
            preferredScale: 2
        )
        expect(frame.viewportScale == 2, "preferred scale ignored")
        expect(
            frame.renderScissor
                == scissor(x: 1_120, y: 480, width: 1_600, height: 88),
            "preferred-scale scissor"
        )
        guard case .drawGlyph(let first) = frame.commandBuffer.command(at: 2)
        else {
            fatalError("preferred-scale first glyph")
        }
        expect(first.bounds.x == fixed(1_156), "preferred-scale glyph x")
        expect(first.bounds.y == fixed(510), "preferred-scale glyph y")
        expect(first.bounds.width == fixed(20), "preferred-scale glyph width")
        expect(first.bounds.height == fixed(28), "preferred-scale glyph height")
    }

    private static func returnsNothingForHiddenCenteredCrops() {
        expectNothingVisible(width: 640, height: 480)
        expectNothingVisible(width: 320, height: 200)
        expectNothingVisible(width: 1, height: 1)

        // This crop exposes part of the top bar vertically, but its centered
        // horizontal range does not reach the left-aligned label.
        expectNothingVisible(width: 100, height: 580)
    }

    private static func preservesPartiallyVisibleGeometryUnderScissor() {
        let frame = requireFrame(width: 750, height: 580)
        expect(frame.viewportScale == 1, "cropped viewport scale")
        expect(
            frame.renderScissor
                == scissor(x: 0, y: 0, width: 750, height: 34),
            "cropped top-bar scissor"
        )
        expect(
            frame.presentationDamage
                == scissor(x: 0, y: 5, width: 75, height: 14),
            "cropped text damage"
        )
        guard case .drawGlyph(let first) = frame.commandBuffer.command(at: 2)
        else {
            fatalError("cropped first glyph")
        }
        // Preserve the original geometry and let the valid target-space
        // scissor clip it; narrowing the quad would distort atlas sampling.
        expect(first.bounds.x == fixed(-7), "cropped glyph origin changed")
        expect(first.bounds.y == fixed(5), "cropped glyph y")
        expect(first.bounds.width == fixed(10), "cropped glyph width")
    }

    private static func rejectsInvalidExtentsAndViewportPreferences() {
        expectRejected(width: 0, height: 600, .invalidPhysicalExtent)
        expectRejected(width: 800, height: 0, .invalidPhysicalExtent)
        expectRejected(width: 32_768, height: 600, .invalidPhysicalExtent)
        expectRejected(width: 800, height: 32_768, .invalidPhysicalExtent)
        expectRejected(
            width: 1_920,
            height: 1_080,
            preferredScale: 0,
            .viewportRejected
        )
    }

    private static func validatesLiteralScalarAccess() {
        expect(GPUBootTextScene.literalScalar(at: -1) == nil, "negative literal index")
        expect(GPUBootTextScene.literalScalar(at: 7) == nil, "past-end literal index")
        expect(GPUBootTextScene.literalScalar(at: 0) == 83, "literal S")
        expect(GPUBootTextScene.literalScalar(at: 1) == 87, "literal W")
        expect(GPUBootTextScene.literalScalar(at: 2) == 73, "literal I")
        expect(GPUBootTextScene.literalScalar(at: 3) == 70, "literal F")
        expect(GPUBootTextScene.literalScalar(at: 4) == 84, "literal T")
        expect(GPUBootTextScene.literalScalar(at: 5) == 79, "literal O")
        expect(GPUBootTextScene.literalScalar(at: 6) == 83, "literal final S")

        var index = 0
        while index < GPUBootTextScene.glyphCount {
            guard let scalar = GPUBootTextScene.literalScalar(at: index) else {
                fatalError("missing literal scalar")
            }
            expect(
                !GPUMaskFontAtlasLayout.glyph(for: scalar)
                    .usedReplacementFallback,
                "literal unexpectedly used replacement fallback"
            )
            index += 1
        }
    }

    private static func requireFrame(
        width: UInt32,
        height: UInt32,
        preferredScale: Int? = nil
    ) -> GPUBootTextSceneFrame {
        let result = GPUBootTextScene.makeFrame(
            physicalWidth: width,
            physicalHeight: height,
            atlas: atlas(7),
            target: target(9),
            commandBufferID: commandID(11),
            preferredScale: preferredScale
        )
        guard case .frame(let frame) = result else {
            fatalError("valid boot text frame rejected")
        }
        return frame
    }

    private static func expectNothingVisible(width: UInt32, height: UInt32) {
        let result = GPUBootTextScene.makeFrame(
            physicalWidth: width,
            physicalHeight: height,
            atlas: atlas(7),
            target: target(9),
            commandBufferID: commandID(11)
        )
        guard case .nothingVisible = result else {
            fatalError("hidden centered crop did not use nothingVisible")
        }
    }

    private static func expectRejected(
        width: UInt32,
        height: UInt32,
        preferredScale: Int? = nil,
        _ expected: GPUBootTextSceneRejection
    ) {
        let result = GPUBootTextScene.makeFrame(
            physicalWidth: width,
            physicalHeight: height,
            atlas: atlas(7),
            target: target(9),
            commandBufferID: commandID(11),
            preferredScale: preferredScale
        )
        guard case .rejected(let rejection) = result,
              rejection == expected
        else {
            fatalError("unexpected boot text rejection")
        }
    }

    private static func atlas(_ raw: UInt32) -> GPUTextureID {
        guard let value = GPUTextureID(rawValue: raw) else {
            fatalError("atlas")
        }
        return value
    }

    private static func target(_ raw: UInt32) -> GPURenderTargetID {
        guard let value = GPURenderTargetID(rawValue: raw) else {
            fatalError("target")
        }
        return value
    }

    private static func commandID(_ raw: UInt64) -> GPUCommandBufferID {
        guard let value = GPUCommandBufferID(rawValue: raw) else {
            fatalError("command ID")
        }
        return value
    }

    private static func fixed(_ whole: Int) -> GPUFixed16 {
        guard let value = GPUFixed16(whole: whole) else {
            fatalError("fixed value")
        }
        return value
    }

    private static func scissor(
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32
    ) -> GPUScissorRectangle {
        guard let value = GPUScissorRectangle(
                  x: x,
                  y: y,
                  width: width,
                  height: height
              )
        else {
            fatalError("scissor")
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
