@main
struct GPUDesktopSceneTests {
    static func main() {
        buildsDeterministicRetainedDesktop()
        selectsIntegerScale()
        rejectsInvalidPhysicalExtents()
        print("GPU desktop scene host tests: 3 groups passed")
    }

    private static func buildsDeterministicRetainedDesktop() {
        let result = GPUDesktopScene.makeInitialFrame(
            physicalWidth: 1_920,
            physicalHeight: 1_080,
            target: target(1),
            commandBufferID: commandID(1)
        )
        guard case .frame(let frame) = result else {
            fatalError("retained desktop rejected")
        }
        expect(frame.layerCount == 5, "desktop layer count")
        expect(frame.viewportScale == 1, "1080p integer scale")
        expect(
            frame.presentationDamage
                == GPUScissorRectangle(x: 0, y: 0, width: 1_920, height: 1_080),
            "full attachment clear did not publish full damage"
        )
        let commands = frame.commandBuffer
        expect(commands.commandCount == 8, "desktop command count")
        expect(commands.renderPassCount == 1, "desktop pass count")
        guard case .beginRenderPass(let pass) = commands.command(at: 0),
              case .clear = pass.loadAction,
              pass.target == target(1),
              pass.extent == GPUPixelExtent(width: 1_920, height: 1_080),
              pass.format == .bgra8UNormSRGB,
              case .setScissor(.rectangle(let scissor)) = commands.command(at: 1),
              case .drawQuad(let topBar) = commands.command(at: 2),
              case .drawQuad(let dock) = commands.command(at: 6),
              case .endRenderPass = commands.command(at: 7)
        else {
            fatalError("desktop command ordering")
        }
        expect(
            scissor == GPUScissorRectangle(
                x: 560,
                y: 240,
                width: 800,
                height: 600
            ),
            "logical viewport scissor"
        )
        expect(topBar.bounds.width == fixed(800), "top bar geometry")
        expect(dock.bounds.width == fixed(260), "dock geometry")
        expect(!topBar.isRounded && !dock.isRounded, "unsupported rounding")
    }

    private static func selectsIntegerScale() {
        guard case .frame(let frame) = GPUDesktopScene.makeInitialFrame(
            physicalWidth: 3_840,
            physicalHeight: 2_160,
            target: target(7),
            commandBufferID: commandID(9)
        ) else {
            fatalError("4K retained desktop rejected")
        }
        expect(frame.viewportScale == 3, "4K largest integer scale")
        guard case .beginRenderPass(let pass) = frame.commandBuffer.command(at: 0)
        else {
            fatalError("4K render pass")
        }
        expect(pass.target == target(7), "target identity changed")
        guard case .setScissor(.rectangle(let scissor)) =
                frame.commandBuffer.command(at: 1),
              case .drawQuad(let topBar) =
                frame.commandBuffer.command(at: 2)
        else {
            fatalError("4K retained command order")
        }
        expect(
            scissor == GPUScissorRectangle(
                x: 720,
                y: 180,
                width: 2_400,
                height: 1_800
            ),
            "4K physical viewport"
        )
        expect(topBar.bounds.width == fixed(2_400), "4K scaled geometry")
    }

    private static func rejectsInvalidPhysicalExtents() {
        expectRejected(width: 0, height: 1_080)
        expectRejected(width: 319, height: 200)
        expectRejected(width: 1_920, height: 199)
        expectRejected(width: 32_768, height: 1_080)
        guard case .rejected(.viewportRejected) =
                GPUDesktopScene.makeInitialFrame(
                    physicalWidth: 1_920,
                    physicalHeight: 1_080,
                    target: target(1),
                    commandBufferID: commandID(1),
                    preferredScale: 0
                )
        else {
            fatalError("invalid preferred scale accepted")
        }
    }

    private static func expectRejected(width: UInt32, height: UInt32) {
        guard case .rejected(.invalidPhysicalExtent) =
                GPUDesktopScene.makeInitialFrame(
                    physicalWidth: width,
                    physicalHeight: height,
                    target: target(1),
                    commandBufferID: commandID(1)
                )
        else {
            fatalError("invalid extent accepted: \(width)x\(height)")
        }
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
            fatalError("fixed")
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
