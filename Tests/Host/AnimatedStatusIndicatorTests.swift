@main
struct AnimatedStatusIndicatorTests {
    static func main() {
        testInitializationAndInitialRender()
        testPacedAnimationAndDamage()
        testLateFrameAccountingAndAutoreverse()
        print("animated status indicator host tests: 3 groups passed")
    }

    private static func testInitializationAndInitialRender() {
        expect(
            AnimatedStatusIndicator(
                logicalBounds: Rectangle(x: 0, y: 0, width: 700, height: 600),
                counterFrequency: 3_000,
                startingAt: 0
            ) == nil,
            "undersized logical desktop accepted"
        )
        expect(
            AnimatedStatusIndicator(
                logicalBounds: logicalBounds(),
                counterFrequency: 29,
                startingAt: 0
            ) == nil,
            "counter too slow for target cadence accepted"
        )

        withCanvas { canvas, pixels in
            var indicator = requireIndicator(startingAt: 100)
            expect(indicator.renderInitial(on: canvas), "initial render failed")
            let corner = pixel(
                x: AnimatedStatusIndicator.frame.x,
                y: AnimatedStatusIndicator.frame.y,
                in: pixels
            )
            let center = pixel(
                x: AnimatedStatusIndicator.frame.x + 6,
                y: AnimatedStatusIndicator.frame.y + 6,
                in: pixels
            )
            expect(
                corner == AnimatedStatusIndicator.backgroundColor.xrgb,
                "initial rounded corner was square"
            )
            expect(
                center != AnimatedStatusIndicator.backgroundColor.xrgb
                    && center != AnimatedStatusIndicator.indicatorColor.xrgb,
                "initial opacity was not composited"
            )
            expect(indicator.renderedFrameCount == 0, "initial counted as tick")
        }
    }

    private static func testPacedAnimationAndDamage() {
        withCanvas { canvas, _ in
            var indicator = requireIndicator(startingAt: 100)
            expect(indicator.renderInitial(on: canvas), "initial render")
            guard case .idle = indicator.renderIfDue(
                      counterTick: 199,
                      on: canvas
                  )
            else {
                fatalError("animation rendered before cadence boundary")
            }
            let initialOpacity = indicator.currentOpacity
            guard case let .rendered(damage, dropped) = indicator.renderIfDue(
                      counterTick: 200,
                      on: canvas
                  )
            else {
                fatalError("animation did not render at cadence boundary")
            }
            expect(dropped == 0, "on-time animation dropped a frame")
            expect(indicator.renderedFrameCount == 1, "rendered frame count")
            expect(indicator.currentOpacity > initialOpacity, "opacity did not animate")
            expect(
                damage.boundingRectangle?.x
                    == AnimatedStatusIndicator.frame.x,
                "animation damage x"
            )
            expect(
                damage.boundingRectangle?.width
                    == AnimatedStatusIndicator.frame.width,
                "animation damage width"
            )
        }
    }

    private static func testLateFrameAccountingAndAutoreverse() {
        withCanvas { canvas, _ in
            var indicator = requireIndicator(startingAt: UInt64.max - 49)
            expect(indicator.renderInitial(on: canvas), "wrapping initial render")

            // Counter wraps and crosses seven 100-tick frame boundaries.
            guard case let .rendered(_, dropped) = indicator.renderIfDue(
                      counterTick: 650,
                      on: canvas
                  )
            else {
                fatalError("wrapped late animation did not render")
            }
            expect(dropped == 6, "late animation dropped-frame count")
            expect(indicator.droppedFrameCount == 6, "dropped total")
            let risingOpacity = indicator.currentOpacity

            // Elapsed 2,250 ticks is halfway through the reverse leg of the
            // 1,500-tick autoreversing timeline.
            guard case .rendered = indicator.renderIfDue(
                      counterTick: 2_200,
                      on: canvas
                  )
            else {
                fatalError("autoreverse animation did not render")
            }
            expect(
                indicator.currentOpacity > risingOpacity,
                "autoreverse phase did not reach the brighter half"
            )
        }
    }

    private static func logicalBounds() -> Rectangle {
        Rectangle(x: 0, y: 0, width: 800, height: 600)
    }

    private static func requireIndicator(
        startingAt: UInt64
    ) -> AnimatedStatusIndicator {
        guard let indicator = AnimatedStatusIndicator(
                  logicalBounds: logicalBounds(),
                  counterFrequency: 3_000,
                  startingAt: startingAt
              )
        else {
            fatalError("valid animated indicator rejected")
        }
        return indicator
    }

    private static func withCanvas(
        _ body: (
            ScaledFramebufferCanvas,
            UnsafeMutableBufferPointer<UInt32>
        ) -> Void
    ) {
        let width = 800
        let height = 600
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
              let viewport = DisplayViewport(mode: mode),
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
            fatalError("valid animation canvas rejected")
        }
        canvas.clear(.wallpaper)
        canvas.fill(
            Rectangle(x: 0, y: 0, width: 800, height: 34),
            color: .chrome
        )
        body(canvas, pixels)
    }

    private static func pixel(
        x: Int,
        y: Int,
        in pixels: UnsafeMutableBufferPointer<UInt32>
    ) -> UInt32 {
        pixels[y * 800 + x]
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
