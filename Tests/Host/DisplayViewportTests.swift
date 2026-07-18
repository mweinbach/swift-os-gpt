@main
struct DisplayViewportTests {
    static func main() {
        testExactMode()
        testIntegerScalingAndLetterboxing()
        testPreferredScale()
        testClippedTransforms()
        testSmallModeCropping()
        testScaledFramebufferCanvas()
        testInvalidInputsAndOverflowSafety()
        testScaledBlendAndDamageMapping()
        print("display viewport host tests: 8 groups passed")
    }

    private static func testScaledBlendAndDamageMapping() {
        let mode = requireMode(width: 1_600, height: 1_200)
        guard let viewport = DisplayViewport(mode: mode) else {
            fatalError("scaled blend viewport")
        }
        let pixelCount = Int(mode.widthInPixels * mode.heightInPixels)
        let pixels = UnsafeMutableBufferPointer<UInt32>.allocate(
            capacity: pixelCount
        )
        pixels.initialize(repeating: PixelColor.wallpaper.xrgb)
        defer {
            pixels.deinitialize()
            pixels.deallocate()
        }
        let framebuffer = LinearFramebuffer(
            baseAddress: UInt(bitPattern: pixels.baseAddress!),
            width: Int(mode.widthInPixels),
            height: Int(mode.heightInPixels),
            strideInPixels: Int(mode.widthInPixels)
        )
        guard let canvas = ScaledFramebufferCanvas(
                  framebuffer: framebuffer,
                  viewport: viewport
              )
        else {
            fatalError("scaled blend canvas")
        }
        expect(
            canvas.blend(
                Rectangle(x: 10, y: 20, width: 8, height: 6),
                color: .cyan,
                opacity: 255,
                cornerRadius: 2
            ),
            "scaled blend rejected"
        )
        expect(
            pixels[(42 * 1_600) + 24] == PixelColor.cyan.xrgb,
            "scaled blend did not map logical coordinates"
        )
        expect(
            pixels[(40 * 1_600) + 20] == PixelColor.wallpaper.xrgb,
            "scaled rounded corner was square"
        )
        expect(
            canvas.damageRectangle(
                for: Rectangle(x: 10, y: 20, width: 8, height: 6),
                mode: mode
            ) == DamageRectangle.clipped(
                x: 20,
                y: 40,
                width: 16,
                height: 12,
                to: mode
            ),
            "logical damage did not map to physical pixels"
        )
    }

    private static func testExactMode() {
        let viewport = requireViewport(width: 800, height: 600)
        expect(viewport.scale == 1, "exact mode scale")
        expect(viewport.origin.x == 0, "exact mode origin x")
        expect(viewport.origin.y == 0, "exact mode origin y")
        expect(viewport.logicalBounds.width == 800, "logical bounds width")
        expect(viewport.physicalBounds.height == 600, "physical bounds height")
        expect(viewport.contentBounds.width == 800, "content width")
    }

    private static func testIntegerScalingAndLetterboxing() {
        let doubled = requireViewport(width: 2_560, height: 1_600)
        expect(doubled.scale == 2, "largest fitting integer scale")
        expect(doubled.origin.x == 480, "horizontal letterbox")
        expect(doubled.origin.y == 200, "vertical letterbox")
        expect(doubled.contentBounds.width == 1_600, "scaled content width")
        expect(doubled.contentBounds.height == 1_200, "scaled content height")

        let tripled = requireViewport(width: 3_840, height: 2_160)
        expect(tripled.scale == 3, "4K fitting scale")
        expect(tripled.origin.x == 720, "4K horizontal letterbox")
        expect(tripled.origin.y == 180, "4K vertical letterbox")

        let widescreen = requireViewport(width: 1_920, height: 1_080)
        expect(widescreen.scale == 1, "aspect-ratio constrained scale")
        expect(widescreen.origin.x == 560, "widescreen horizontal center")
        expect(widescreen.origin.y == 240, "widescreen vertical center")
    }

    private static func testPreferredScale() {
        let mode = requireMode(width: 3_840, height: 2_160)
        guard let preferred = DisplayViewport(mode: mode, preferredScale: 2) else {
            fatalError("preferred viewport rejected")
        }
        expect(preferred.scale == 2, "preferred scale ignored")
        expect(preferred.origin.x == 1_120, "preferred scale origin x")
        expect(preferred.origin.y == 480, "preferred scale origin y")

        let constrainedMode = requireMode(width: 2_560, height: 1_600)
        guard let constrained = DisplayViewport(
            mode: constrainedMode,
            preferredScale: 3
        ) else {
            fatalError("constrained viewport rejected")
        }
        expect(constrained.scale == 2, "preferred scale did not clamp to fit")
    }

    private static func testClippedTransforms() {
        let viewport = requireViewport(width: 2_560, height: 1_600)
        let point = viewport.transformClipped(Point(x: 10, y: 20))
        expect(point?.x == 500, "transformed point x")
        expect(point?.y == 240, "transformed point y")
        expect(
            viewport.transformClipped(Point(x: 800, y: 0)) == nil,
            "out-of-bounds logical point accepted"
        )

        let rectangle = viewport.transformClipped(
            Rectangle(x: 10, y: 20, width: 30, height: 40)
        )
        expect(rectangle?.x == 500, "transformed rectangle x")
        expect(rectangle?.y == 240, "transformed rectangle y")
        expect(rectangle?.width == 60, "transformed rectangle width")
        expect(rectangle?.height == 80, "transformed rectangle height")

        let clipped = viewport.transformClipped(
            Rectangle(x: -10, y: 590, width: 30, height: 30)
        )
        expect(clipped?.x == 480, "logical clipping x")
        expect(clipped?.y == 1_380, "logical clipping y")
        expect(clipped?.width == 40, "logical clipping width")
        expect(clipped?.height == 20, "logical clipping height")
        expect(viewport.scaledLength(6) == 12, "scaled logical length")
        expect(viewport.scaledLength(-1) == nil, "negative length accepted")
    }

    private static func testSmallModeCropping() {
        let mode = requireMode(width: 640, height: 480)
        guard let viewport = DisplayViewport(mode: mode) else {
            fatalError("small viewport rejected")
        }
        expect(viewport.scale == 1, "small mode scale")
        expect(viewport.origin.x == -80, "small mode crop x")
        expect(viewport.origin.y == -60, "small mode crop y")

        let firstVisiblePoint = viewport.transformClipped(Point(x: 80, y: 60))
        expect(firstVisiblePoint?.x == 0, "first visible point x")
        expect(firstVisiblePoint?.y == 0, "first visible point y")
        expect(
            viewport.transformClipped(Point(x: 79, y: 60)) == nil,
            "cropped point remained visible"
        )

        let partial = viewport.transformClipped(
            Rectangle(x: 0, y: 0, width: 100, height: 100)
        )
        expect(partial?.x == 0, "cropped rectangle x")
        expect(partial?.y == 0, "cropped rectangle y")
        expect(partial?.width == 20, "cropped rectangle width")
        expect(partial?.height == 40, "cropped rectangle height")

        guard let canvas = ScaledFramebufferCanvas(
                  framebuffer: LinearFramebuffer(
                      baseAddress: 1,
                      width: 640,
                      height: 480,
                      strideInPixels: 640
                  ),
                  viewport: viewport
              )
        else {
            fatalError("small canvas rejected")
        }
        expect(
            canvas.damageRectangle(
                for: Rectangle(x: 774, y: 11, width: 12, height: 12),
                mode: mode
            ) == nil,
            "fully cropped animation damage became physical damage"
        )
    }

    private static func testScaledFramebufferCanvas() {
        let mode = requireMode(width: 10, height: 8)
        guard let viewport = DisplayViewport(
                  mode: mode,
                  logicalWidth: 4,
                  logicalHeight: 3
              )
        else {
            fatalError("scaled canvas viewport rejected")
        }
        expect(viewport.scale == 2, "scaled canvas fixture scale")
        expect(viewport.origin.x == 1, "scaled canvas fixture origin x")
        expect(viewport.origin.y == 1, "scaled canvas fixture origin y")

        let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: 80)
        pixels.initialize(repeating: 0, count: 80)
        defer {
            pixels.deinitialize(count: 80)
            pixels.deallocate()
        }
        let framebuffer = LinearFramebuffer(
            baseAddress: UInt(bitPattern: pixels),
            width: 10,
            height: 8,
            strideInPixels: 10
        )
        guard let canvas = ScaledFramebufferCanvas(
                  framebuffer: framebuffer,
                  viewport: viewport
              )
        else {
            fatalError("valid scaled canvas rejected")
        }
        canvas.clear(.wallpaper)
        canvas.fill(
            Rectangle(x: 1, y: 1, width: 1, height: 1),
            color: .cyan
        )
        expect(
            pixels[3 + 3 * 10] == PixelColor.cyan.xrgb,
            "logical fill did not map to scaled origin"
        )
        expect(
            pixels[4 + 4 * 10] == PixelColor.cyan.xrgb,
            "logical fill did not cover scaled extent"
        )
        expect(
            pixels[2 + 3 * 10] == PixelColor.wallpaper.xrgb,
            "scaled fill escaped its logical bounds"
        )
        if let _ = ScaledFramebufferCanvas(
            framebuffer: LinearFramebuffer(
                baseAddress: UInt(bitPattern: pixels),
                width: 9,
                height: 8,
                strideInPixels: 10
            ),
            viewport: viewport
        ) {
            fatalError("mismatched framebuffer and viewport were accepted")
        }
    }

    private static func testInvalidInputsAndOverflowSafety() {
        let mode = requireMode(width: 800, height: 600)
        expect(
            DisplayViewport(mode: mode, logicalWidth: 0) == nil,
            "zero logical width accepted"
        )
        expect(
            DisplayViewport(mode: mode, logicalHeight: -1) == nil,
            "negative logical height accepted"
        )
        expect(
            DisplayViewport(mode: mode, preferredScale: 0) == nil,
            "zero preferred scale accepted"
        )

        let viewport = requireViewport(width: 800, height: 600)
        let doubledViewport = requireViewport(width: 1_600, height: 1_200)
        expect(
            doubledViewport.transform(Point(x: Int.max, y: 0)) == nil,
            "overflowing point transform was accepted"
        )
        expect(
            viewport.transformClipped(
                Rectangle(
                    x: Int.max - 5,
                    y: 0,
                    width: 100,
                    height: 1
                )
            ) == nil,
            "overflowing offscreen rectangle accepted"
        )
        expect(
            viewport.transformClipped(
                Rectangle(x: 0, y: 0, width: 0, height: 1)
            ) == nil,
            "empty rectangle accepted"
        )
        expect(
            viewport.scaledLength(Int.max) == Int.max,
            "one-to-one maximum length"
        )
    }

    private static func requireViewport(
        width: UInt32,
        height: UInt32
    ) -> DisplayViewport {
        guard let viewport = DisplayViewport(
            mode: requireMode(width: width, height: height)
        ) else {
            fatalError("valid viewport fixture rejected")
        }
        return viewport
    }

    private static func requireMode(width: UInt32, height: UInt32) -> DisplayMode {
        guard let mode = DisplayMode(
            widthInPixels: width,
            heightInPixels: height,
            refreshRateMilliHertz: 60_000,
            pixelFormat: .b8g8r8x8
        ) else {
            fatalError("valid display mode fixture rejected")
        }
        return mode
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: StaticString) {
        if !condition() {
            fatalError("display viewport test failed: \(message)")
        }
    }
}
