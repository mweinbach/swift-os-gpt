@main
struct GPUFileManagerSceneTests {
    static func main() {
        compilesRetainedChromeAndGlyphPasses()
        scalesTheSceneWithoutRewritingLogicalGeometry()
        rendersDeterministicEmptyStateAndRejectsMismatchedBounds()
        print("GPU file-manager scene host tests: 3 groups passed")
    }

    private static func compilesRetainedChromeAndGlyphPasses() {
        withBrowserModel { model in
            append(&model, name: "Beta", id: 1, kind: .regularFile)
            append(&model, name: "Alpha", id: 2, kind: .directory)
            append(&model, name: "Résumé", id: 3, kind: .regularFile)

            let layout = makeLayout()
            let cursor = makeCursor(position: Point(x: 500, y: 200))
            let result = GPUFileManagerSceneCompiler.compile(
                model: model,
                layout: layout,
                cursor: cursor,
                animation: FileManagerAnimationSample(
                    windowOpacity: 255,
                    focusOpacity: 255,
                    selectionOpacity: 112,
                    hoverOpacity: 64,
                    cursorIsVisible: true
                ),
                hoveredVisibleRow: 0,
                viewport: makeViewport(width: 1_920, height: 1_080),
                target: target(1),
                fontAtlas: texture(7),
                chromeCommandBufferID: commandID(11),
                textCommandBufferID: commandID(12)
            )
            guard case .frame(let frame) = result else {
                fail("file-manager scene rejected")
            }
            expect(frame.chromeLayerCount == 8, "chrome layer count")
            expect(frame.visibleFileRowCount == 3, "visible file rows")
            expect(frame.glyphCount == 25, "bounded glyph count")
            expect(
                frame.presentationDamage
                    == GPUScissorRectangle(
                        x: 0,
                        y: 0,
                        width: 1_920,
                        height: 1_080
                    ),
                "full presentation damage"
            )
            expect(
                frame.commandBuffer(at: 0)?.id == commandID(11)
                    && frame.commandBuffer(at: 1)?.id == commandID(12)
                    && frame.commandBuffer(at: 2) == nil,
                "command submission order"
            )

            let chrome = frame.chromeCommandBuffer
            expect(chrome.commandCount == 11, "chrome command count")
            guard case .beginRenderPass(let chromePass) = chrome.command(at: 0),
                  case .clear = chromePass.loadAction,
                  case .setScissor(.rectangle(let chromeScissor)) =
                    chrome.command(at: 1),
                  case .drawQuad(let shadow) = chrome.command(at: 2),
                  case .drawQuad(let window) = chrome.command(at: 3),
                  case .drawQuad(let title) = chrome.command(at: 4),
                  case .drawQuad(let selection) = chrome.command(at: 7),
                  case .drawQuad(let hover) = chrome.command(at: 8),
                  case .drawQuad(let cursorQuad) = chrome.command(at: 9),
                  case .endRenderPass = chrome.command(at: 10)
            else {
                fail("chrome command ordering")
            }
            expect(
                chromeScissor == GPUScissorRectangle(
                    x: 560,
                    y: 240,
                    width: 800,
                    height: 600
                ),
                "chrome logical viewport scissor"
            )
            expect(shadow.bounds.x == fixed(648), "shadow physical x")
            expect(window.bounds.x == fixed(640), "window physical x")
            expect(title.bounds.height == fixed(44), "title bar height")
            expect(selection.color.alpha > hover.color.alpha, "selection emphasis")
            expect(cursorQuad.bounds.x == fixed(1_060), "cursor mapped x")
            expect(cursorQuad.bounds.y == fixed(440), "cursor mapped y")

            let text = frame.textCommandBuffer
            expect(text.commandCount == 29, "text command count")
            guard case .beginRenderPass(let textPass) = text.command(at: 0),
                  case .load = textPass.loadAction,
                  case .setScissor(.rectangle(let textScissor)) =
                    text.command(at: 1),
                  case .setTransform(let transform) = text.command(at: 2),
                  case .drawGlyph(let firstGlyph) = text.command(at: 3),
                  case .drawGlyph(let replacementGlyph) = text.command(at: 24),
                  case .endRenderPass = text.command(at: 28)
            else {
                fail("text command ordering")
            }
            expect(
                textScissor == GPUScissorRectangle(
                    x: 640,
                    y: 310,
                    width: 640,
                    height: 460
                ),
                "window text scissor"
            )
            expect(transform.m11 == .one && transform.m22 == .one, "text scale")
            expect(transform.translationX == fixed(560), "text translation x")
            expect(transform.translationY == fixed(240), "text translation y")
            expect(firstGlyph.atlas == texture(7), "font atlas identity")
            expect(firstGlyph.bounds.x == fixed(128), "title logical x")
            expect(
                replacementGlyph.textureRegion
                    == GPUMaskFontAtlasLayout.glyph(for: 0xfffd).maskTextureRegion,
                "non-ASCII name did not use replacement glyph"
            )
        }
    }

    private static func scalesTheSceneWithoutRewritingLogicalGeometry() {
        withBrowserModel { model in
            append(&model, name: "Alpha", id: 1, kind: .directory)
            let result = GPUFileManagerSceneCompiler.compile(
                model: model,
                layout: makeLayout(),
                cursor: makeCursor(
                    position: Point(x: 400, y: 300),
                    shape: .pointingHand
                ),
                animation: FileManagerAnimationSample(
                    windowOpacity: 255,
                    focusOpacity: 255,
                    selectionOpacity: 112,
                    hoverOpacity: 0,
                    cursorIsVisible: true
                ),
                hoveredVisibleRow: nil,
                viewport: makeViewport(width: 3_840, height: 2_160),
                target: target(2),
                fontAtlas: texture(8),
                chromeCommandBufferID: commandID(21),
                textCommandBufferID: commandID(22)
            )
            guard case .frame(let frame) = result,
                  case .drawQuad(let window) =
                    frame.chromeCommandBuffer.command(at: 3),
                  case .drawQuad(let cursor) =
                    frame.chromeCommandBuffer.command(at: 8),
                  case .setTransform(let transform) =
                    frame.textCommandBuffer.command(at: 2),
                  case .drawGlyph(let title) =
                    frame.textCommandBuffer.command(at: 3)
            else {
                fail("4K file-manager scene rejected")
            }
            expect(window.bounds.x == fixed(960), "4K window x")
            expect(window.bounds.width == fixed(1_920), "4K window width")
            expect(cursor.bounds.width == fixed(36), "4K hand cursor width")
            expect(cursor.bounds.height == fixed(36), "4K hand cursor height")
            expect(transform.m11 == fixed(3), "4K text scale")
            expect(transform.m22 == fixed(3), "4K text y scale")
            expect(transform.translationX == fixed(720), "4K origin x")
            expect(transform.translationY == fixed(180), "4K origin y")
            expect(title.bounds.x == fixed(128), "logical glyph geometry changed")
        }
    }

    private static func rendersDeterministicEmptyStateAndRejectsMismatchedBounds() {
        withBrowserModel { model in
            let layout = makeLayout()
            let animation = FileManagerAnimationSample(
                windowOpacity: 255,
                focusOpacity: 0,
                selectionOpacity: 0,
                hoverOpacity: 0,
                cursorIsVisible: false
            )
            let result = GPUFileManagerSceneCompiler.compile(
                model: model,
                layout: layout,
                cursor: makeCursor(position: Point(x: 1, y: 1)),
                animation: animation,
                hoveredVisibleRow: nil,
                viewport: makeViewport(width: 1_280, height: 720),
                target: target(3),
                fontAtlas: texture(9),
                chromeCommandBufferID: commandID(31),
                textCommandBufferID: commandID(32)
            )
            guard case .frame(let frame) = result else {
                fail("empty file-manager scene rejected")
            }
            expect(frame.visibleFileRowCount == 0, "empty visible rows")
            expect(frame.glyphCount == 16, "empty label glyph count")
            expect(frame.chromeLayerCount == 5, "hidden transient layers rendered")

            let mismatchedLayout = FileManagerLayout(
                desktopBounds: Rectangle(x: 0, y: 0, width: 1_024, height: 768),
                windowFrame: Rectangle(x: 100, y: 100, width: 640, height: 460)
            )!
            let rejected = GPUFileManagerSceneCompiler.compile(
                model: model,
                layout: mismatchedLayout,
                cursor: makeCursor(position: Point(x: 1, y: 1)),
                animation: animation,
                hoveredVisibleRow: nil,
                viewport: makeViewport(width: 1_280, height: 720),
                target: target(3),
                fontAtlas: texture(9),
                chromeCommandBufferID: commandID(33),
                textCommandBufferID: commandID(34)
            )
            guard case .rejected(.layoutBoundsDoNotMatchViewport) = rejected
            else {
                fail("mismatched layout accepted")
            }
        }
    }

    private static func makeCursor(
        position: Point,
        shape: UICursorShape = .arrow
    ) -> DesktopCursorState {
        var storage = [UIWindowRecord](repeating: .vacant, count: 1)
        return storage.withUnsafeMutableBufferPointer {
            var router = WindowInputRouter(
                windowStorage: $0,
                desktopBounds: Rectangle(x: 0, y: 0, width: 800, height: 600),
                initialCursorPosition: position
            )!
            router.setCursorShape(shape)
            return router.cursor
        }
    }

    private static func makeLayout() -> FileManagerLayout {
        FileManagerLayout(
            desktopBounds: Rectangle(x: 0, y: 0, width: 800, height: 600),
            windowFrame: Rectangle(x: 80, y: 70, width: 640, height: 460)
        )!
    }

    private static func makeViewport(width: UInt32, height: UInt32) -> DisplayViewport {
        let mode = DisplayMode(
            widthInPixels: width,
            heightInPixels: height,
            refreshRateMilliHertz: nil,
            pixelFormat: .b8g8r8a8
        )!
        return DisplayViewport(mode: mode)!
    }

    private static func withBrowserModel(
        _ body: (inout FileBrowserModel) -> Void
    ) {
        var records = [FileBrowserEntryRecord](repeating: .vacant, count: 8)
        var names = [UInt8](repeating: 0, count: 128)
        records.withUnsafeMutableBufferPointer { entries in
            names.withUnsafeMutableBytes { nameStorage in
                var model = FileBrowserModel(
                    entryStorage: entries,
                    nameStorage: nameStorage,
                    visibleRowCapacity: 4
                )!
                body(&model)
            }
        }
    }

    private static func append(
        _ model: inout FileBrowserModel,
        name: String,
        id: UInt64,
        kind: VFSNodeKind
    ) {
        let bytes = Array(name.utf8)
        let result = bytes.withUnsafeBytes { raw -> FileBrowserAppendResult in
            guard case .name(let nameView) = VFSNameValidator.validate(raw)
            else { fail("invalid test name") }
            return model.append(
                VFSDirectoryEntry(
                    identifier: VFSNodeIdentifier(
                        volume: VFSVolumeIdentifier(rawValue: 1)!,
                        localValue: id
                    )!,
                    kind: kind,
                    name: nameView
                )
            )
        }
        guard case .inserted = result else { fail("append rejected") }
    }

    private static func target(_ rawValue: UInt32) -> GPURenderTargetID {
        GPURenderTargetID(rawValue: rawValue)!
    }

    private static func texture(_ rawValue: UInt32) -> GPUTextureID {
        GPUTextureID(rawValue: rawValue)!
    }

    private static func commandID(_ rawValue: UInt64) -> GPUCommandBufferID {
        GPUCommandBufferID(rawValue: rawValue)!
    }

    private static func fixed(_ whole: Int) -> GPUFixed16 {
        GPUFixed16(whole: whole)!
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError(message)
    }
}
