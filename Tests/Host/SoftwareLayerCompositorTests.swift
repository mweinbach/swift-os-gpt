@main
struct SoftwareLayerCompositorTests {
    static func main() {
        testPainterOrderAlphaAndDamageClipping()
        testRoundedLayerAndMutationDamage()
        testInvalidBoundsAndRejectedMutation()
        print("software layer compositor host tests: 3 groups passed")
    }

    private static func testPainterOrderAlphaAndDamageClipping() {
        withCanvas(width: 12, height: 10) { canvas, pixels in
            var tree = requireTree(capacity: 3)
            _ = tree.insert(
                requireLayer(
                    id: 1,
                    color: PixelColor(xrgb: 0x00ff_0000),
                    frame: Rectangle(x: 1, y: 1, width: 8, height: 7),
                    zOrder: 0
                )
            )
            _ = tree.insert(
                requireLayer(
                    id: 2,
                    color: PixelColor(xrgb: 0x0000_00ff),
                    frame: Rectangle(x: 3, y: 2, width: 7, height: 6),
                    clip: Rectangle(x: 4, y: 3, width: 4, height: 3),
                    opacity: 128,
                    zOrder: 1
                )
            )
            var damage = requireDamage(width: 12, height: 10)
            damage.add(Rectangle(x: 2, y: 2, width: 5, height: 4))
            expect(
                SoftwareLayerCompositor.render(
                    tree: tree,
                    damage: damage,
                    backgroundColor: .wallpaper,
                    on: canvas
                ),
                "valid scene render rejected"
            )
            expect(
                pixels[0] == PixelColor.transparentBlack.xrgb,
                "compositor repainted outside damage"
            )
            expect(
                pixels[2 + 2 * 12] == 0x00ff_0000,
                "back layer missing inside damage"
            )
            expect(
                pixels[4 + 3 * 12] == 0x007f_0080,
                "front alpha layer or painter order mismatch"
            )
            expect(
                pixels[6 + 5 * 12] == 0x007f_0080,
                "clipped front layer missing"
            )
            expect(
                pixels[4 + 2 * 12] == 0x00ff_0000,
                "front layer escaped its clip"
            )
        }
    }

    private static func testRoundedLayerAndMutationDamage() {
        withCanvas(width: 16, height: 12) { canvas, pixels in
            var tree = requireTree(capacity: 2)
            var damage = requireDamage(width: 16, height: 12)
            let insertion = tree.insert(
                requireLayer(
                    id: 8,
                    color: .cyan,
                    frame: Rectangle(x: 2, y: 2, width: 8, height: 8),
                    cornerRadius: 4
                )
            )
            expect(
                SoftwareLayerCompositor.recordDamage(
                    from: insertion,
                    in: &damage
                ),
                "insertion damage rejected"
            )
            expect(
                SoftwareLayerCompositor.render(
                    tree: tree,
                    damage: damage,
                    backgroundColor: .chrome,
                    on: canvas
                ),
                "rounded scene render rejected"
            )
            expect(pixels[2 + 2 * 16] == PixelColor.chrome.xrgb, "round corner")
            expect(pixels[5 + 5 * 16] == PixelColor.cyan.xrgb, "round center")

            damage.clear()
            let move = tree.update(
                requireLayer(
                    id: 8,
                    color: .green,
                    frame: Rectangle(x: 8, y: 3, width: 6, height: 6),
                    cornerRadius: 3
                )
            )
            expect(
                SoftwareLayerCompositor.recordDamage(from: move, in: &damage),
                "move damage rejected"
            )
            expect(
                damage.boundingRectangle?.x == 2
                    && damage.boundingRectangle?.width == 12,
                "old and new frames were not both damaged"
            )
            expect(
                SoftwareLayerCompositor.render(
                    tree: tree,
                    damage: damage,
                    backgroundColor: .chrome,
                    on: canvas
                ),
                "moved scene render rejected"
            )
            expect(
                pixels[5 + 5 * 16] == PixelColor.chrome.xrgb,
                "old layer pixels were not restored"
            )
            expect(
                pixels[10 + 6 * 16] == PixelColor.green.xrgb,
                "moved layer was not rendered"
            )
        }
    }

    private static func testInvalidBoundsAndRejectedMutation() {
        withCanvas(width: 8, height: 8) { canvas, _ in
            let tree = requireTree(capacity: 1)
            var wrongDamage = requireDamage(width: 7, height: 8)
            wrongDamage.addFullDamage()
            expect(
                !SoftwareLayerCompositor.render(
                    tree: tree,
                    damage: wrongDamage,
                    backgroundColor: .wallpaper,
                    on: canvas
                ),
                "mismatched logical bounds accepted"
            )

            var fullTree = requireTree(capacity: 1)
            _ = fullTree.insert(requireLayer(id: 1, color: .blue))
            var damage = requireDamage(width: 8, height: 8)
            expect(
                !SoftwareLayerCompositor.recordDamage(
                    from: fullTree.insert(requireLayer(id: 2, color: .red)),
                    in: &damage
                ),
                "rejected mutation reported damage"
            )
            expect(damage.isEmpty, "rejected mutation changed damage")
        }
    }

    private static func withCanvas(
        width: Int,
        height: Int,
        _ body: (ScaledFramebufferCanvas, UnsafeMutableBufferPointer<UInt32>)
            -> Void
    ) {
        let pixels = UnsafeMutableBufferPointer<UInt32>.allocate(
            capacity: width * height
        )
        pixels.initialize(repeating: 0)
        defer {
            pixels.deinitialize()
            pixels.deallocate()
        }
        guard let mode = DisplayMode(
                  widthInPixels: UInt32(width),
                  heightInPixels: UInt32(height),
                  refreshRateMilliHertz: 60_000,
                  pixelFormat: .b8g8r8x8
              ),
              let viewport = DisplayViewport(
                  mode: mode,
                  logicalWidth: width,
                  logicalHeight: height
              ),
              let canvas = ScaledFramebufferCanvas(
                  framebuffer: LinearFramebuffer(
                      baseAddress: UInt(bitPattern: pixels.baseAddress!),
                      width: width,
                      height: height,
                      strideInPixels: width
                  ),
                  viewport: viewport
              )
        else {
            fatalError("valid compositor canvas rejected")
        }
        body(canvas, pixels)
    }

    private static func requireTree(capacity: Int) -> RetainedLayerTree {
        guard let tree = RetainedLayerTree(capacity: capacity) else {
            fatalError("valid compositor tree rejected")
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
            fatalError("valid compositor damage rejected")
        }
        return damage
    }

    private static func requireLayer(
        id: UInt64,
        color: PixelColor,
        frame: Rectangle = Rectangle(x: 0, y: 0, width: 8, height: 8),
        clip: Rectangle? = nil,
        opacity: UInt8 = 255,
        cornerRadius: Int = 0,
        zOrder: Int32 = 0
    ) -> RetainedLayer {
        guard let layerID = LayerID(rawValue: id),
              let layer = RetainedLayer(
                  id: layerID,
                  content: .solidColor(color),
                  frame: frame,
                  clip: clip,
                  opacity: opacity,
                  cornerRadius: cornerRadius,
                  zOrder: zOrder
              )
        else {
            fatalError("valid compositor layer rejected")
        }
        return layer
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
