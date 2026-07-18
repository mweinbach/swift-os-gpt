@main
struct SoftwareRasterizerTests {
    static func main() {
        testOpaqueAndTranslucentBlending()
        testARGBStorage()
        testClippingAndMalformedGeometry()
        testRoundedCoverage()
        testHugeFarCornerCoordinates()
        print("software rasterizer host tests: 5 groups passed")
    }

    private static func testOpaqueAndTranslucentBlending() {
        withFramebuffer(width: 4, height: 3) { framebuffer, pixels in
            framebuffer.fill(PixelColor(xrgb: 0x0010_2030))
            expect(
                framebuffer.blend(
                    Rectangle(x: 1, y: 1, width: 2, height: 1),
                    color: PixelColor(xrgb: 0x00f0_8040),
                    opacity: 128
                ),
                "valid blend rejected"
            )
            expect(pixels[0] == 0x0010_2030, "blend escaped rectangle")
            expect(pixels[5] == 0x0080_5038, "source-over blend mismatch")
            expect(pixels[6] == 0x0080_5038, "blend width mismatch")

            let before = pixels[5]
            expect(
                framebuffer.blend(
                    Rectangle(x: 1, y: 1, width: 1, height: 1),
                    color: .red,
                    opacity: 0
                ),
                "zero-opacity draw rejected"
            )
            expect(pixels[5] == before, "zero opacity changed a pixel")

            expect(
                framebuffer.blend(
                    Rectangle(x: 3, y: 2, width: 1, height: 1),
                    color: PixelColor(xrgb: 0x0012_3456),
                    opacity: 255
                ),
                "opaque blend rejected"
            )
            expect(pixels[11] == 0x0012_3456, "opaque blend mismatch")
        }
    }

    private static func testARGBStorage() {
        withFramebuffer(
            width: 2,
            height: 1,
            pixelFormat: .b8g8r8a8
        ) { framebuffer, pixels in
            framebuffer.fill(PixelColor(xrgb: 0x0000_0000))
            expect(
                framebuffer.blend(
                    Rectangle(x: 0, y: 0, width: 2, height: 1),
                    color: PixelColor(xrgb: 0x00ff_0000),
                    opacity: 255
                ),
                "ARGB blend rejected"
            )
            expect(pixels[0] == 0xffff_0000, "ARGB alpha byte missing")
            expect(pixels[1] == 0xffff_0000, "ARGB fill width mismatch")
        }
    }

    private static func testClippingAndMalformedGeometry() {
        withFramebuffer(width: 4, height: 4) { framebuffer, pixels in
            framebuffer.fill(.transparentBlack)
            expect(
                framebuffer.blend(
                    Rectangle(x: -2, y: -2, width: 6, height: 6),
                    color: .green,
                    opacity: 255,
                    clippedTo: Rectangle(x: 1, y: 1, width: 2, height: 2)
                ),
                "clipped blend rejected"
            )
            expect(pixels[5] == PixelColor.green.xrgb, "clip origin missing")
            expect(pixels[10] == PixelColor.green.xrgb, "clip end missing")
            expect(pixels[0] == 0, "clip escaped to origin")
            expect(pixels[15] == 0, "clip escaped to end")

            expect(
                !framebuffer.blend(
                    Rectangle(x: 0, y: 0, width: 0, height: 1),
                    color: .white,
                    opacity: 255
                ),
                "empty rectangle accepted"
            )
            expect(
                !framebuffer.blend(
                    Rectangle(x: 0, y: 0, width: 1, height: 1),
                    color: .white,
                    opacity: 255,
                    cornerRadius: -1
                ),
                "negative corner radius accepted"
            )
            expect(
                framebuffer.blend(
                    Rectangle(
                        x: Int.max - 2,
                        y: Int.max - 2,
                        width: 10,
                        height: 10
                    ),
                    color: .white,
                    opacity: 255
                ),
                "saturated offscreen rectangle rejected"
            )
        }
    }

    private static func testRoundedCoverage() {
        withFramebuffer(width: 8, height: 8) { framebuffer, pixels in
            framebuffer.fill(.transparentBlack)
            expect(
                framebuffer.blend(
                    Rectangle(x: 1, y: 1, width: 6, height: 6),
                    color: .cyan,
                    opacity: 255,
                    cornerRadius: 3
                ),
                "rounded rectangle rejected"
            )
            expect(pixels[1 * 8 + 1] == 0, "rounded corner was square")
            expect(pixels[1 * 8 + 3] != 0, "rounded top edge missing")
            expect(pixels[3 * 8 + 3] == PixelColor.cyan.xrgb, "rounded center")
            expect(pixels[6 * 8 + 6] == 0, "opposite corner was square")
            expect(
                pixels.contains { pixel in
                    pixel != 0 && pixel != PixelColor.cyan.xrgb
                },
                "rounded edge was not antialiased"
            )
        }
    }

    /// A small framebuffer can intersect the far corner of an enormous layer.
    /// Rasterization must scale corner-relative distances, not absolute layer
    /// coordinates whose quarter-pixel representation would overflow.
    private static func testHugeFarCornerCoordinates() {
        withFramebuffer(width: 4, height: 4) { framebuffer, pixels in
            framebuffer.fill(.transparentBlack)
            let distantOrigin = -(Int.max / 2)
            let farCornerExtent = Int.max / 2 + 4
            expect(
                framebuffer.blend(
                    Rectangle(
                        x: distantOrigin,
                        y: distantOrigin,
                        width: farCornerExtent,
                        height: farCornerExtent
                    ),
                    color: .cyan,
                    opacity: 255,
                    cornerRadius: 2
                ),
                "far-corner blend rejected"
            )
            expect(pixels[0] == PixelColor.cyan.xrgb, "far-corner fill missing")
            expect(
                pixels[15] != PixelColor.cyan.xrgb,
                "far rounded corner was square"
            )
        }
    }

    private static func withFramebuffer(
        width: Int,
        height: Int,
        pixelFormat: PixelFormat = .b8g8r8x8,
        _ body: (LinearFramebuffer, UnsafeMutableBufferPointer<UInt32>) -> Void
    ) {
        let pixels = UnsafeMutableBufferPointer<UInt32>.allocate(
            capacity: width * height
        )
        pixels.initialize(repeating: 0)
        defer {
            pixels.deinitialize()
            pixels.deallocate()
        }
        let framebuffer = LinearFramebuffer(
            baseAddress: UInt(bitPattern: pixels.baseAddress!),
            width: width,
            height: height,
            strideInPixels: width,
            pixelFormat: pixelFormat
        )
        body(framebuffer, pixels)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
