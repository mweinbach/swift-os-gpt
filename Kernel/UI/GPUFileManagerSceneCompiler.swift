struct GPUFileManagerSceneFrame {
    let chromeCommandBuffer: GPURenderCommandBuffer
    let textCommandBuffer: GPURenderCommandBuffer
    let presentationDamage: GPUScissorRectangle
    let chromeLayerCount: Int
    let glyphCount: Int
    let visibleFileRowCount: Int

    static let commandBufferCount = 2

    /// Submission order is part of the contract: chrome clears and establishes
    /// the retained scene, then text loads that attachment and blends glyphs.
    func commandBuffer(at index: Int) -> GPURenderCommandBuffer? {
        switch index {
        case 0: return chromeCommandBuffer
        case 1: return textCommandBuffer
        default: return nil
        }
    }
}

enum GPUFileManagerSceneRejection: Equatable {
    case layoutBoundsDoNotMatchViewport
    case invalidCursorFrame
    case retainedTreeRejected
    case retainedLayerRejected(identifier: UInt64)
    case retainedLayerInsertionRejected(
        identifier: UInt64,
        reason: RetainedLayerMutationRejection
    )
    case damageRegionRejected
    case chromeCompilationRejected(GPURetainedSceneCompileRejection)
    case chromeCompilationEmpty
    case physicalGeometryOutOfRange
    case textRecorderRejected
    case textCommandRejected(GPUCommandRecordRejection)
    case textSealRejected(GPUCommandBufferSealRejection)
}

enum GPUFileManagerSceneResult {
    case frame(GPUFileManagerSceneFrame)
    case rejected(GPUFileManagerSceneRejection)
}

/// Compiles one file-manager presentation into existing backend-neutral GPU
/// primitives. No framebuffer pointer or device packet crosses this boundary.
///
/// Two immutable command buffers are intentional: the retained chrome stream
/// clears/draws the window and cursor, while the glyph stream loads the same
/// attachment. A backend submits them in index order; the current VirtIO 3D
/// session can do so with two ordinary `render` calls.
enum GPUFileManagerSceneCompiler {
    private static let maximumRenderedFileRows = 4
    private static let maximumGlyphCount = 28

    private enum FixedLabel {
        case title
        case system
        case user
        case empty

        var count: Int {
            switch self {
            case .title, .empty: return 5
            case .system: return 2
            case .user: return 4
            }
        }

        func byte(at index: Int) -> UInt8? {
            switch self {
            case .title:
                switch index {
                case 0: return 0x46
                case 1: return 0x69
                case 2: return 0x6c
                case 3: return 0x65
                case 4: return 0x73
                default: return nil
                }
            case .system:
                switch index {
                case 0: return 0x4f
                case 1: return 0x53
                default: return nil
                }
            case .user:
                switch index {
                case 0: return 0x48
                case 1: return 0x6f
                case 2: return 0x6d
                case 3: return 0x65
                default: return nil
                }
            case .empty:
                switch index {
                case 0: return 0x45
                case 1: return 0x6d
                case 2: return 0x70
                case 3: return 0x74
                case 4: return 0x79
                default: return nil
                }
            }
        }
    }

    static func compile(
        model: FileBrowserModel,
        layout: FileManagerLayout,
        cursor: DesktopCursorState,
        animation: FileManagerAnimationSample,
        hoveredVisibleRow: Int?,
        viewport: DisplayViewport,
        target: GPURenderTargetID,
        targetFormat: GPUColorAttachmentFormat = .bgra8UNormSRGB,
        fontAtlas: GPUTextureID,
        chromeCommandBufferID: GPUCommandBufferID,
        textCommandBufferID: GPUCommandBufferID
    ) -> GPUFileManagerSceneResult {
        guard sameRectangle(layout.desktopBounds, viewport.logicalBounds) else {
            return .rejected(.layoutBoundsDoNotMatchViewport)
        }
        guard var tree = RetainedLayerTree(capacity: 8) else {
            return .rejected(.retainedTreeRejected)
        }

        let windowOpacity = animation.windowOpacity
        if let rejection = insertLayer(
            identifier: 1,
            color: PixelColor(xrgb: 0x0002_0610),
            frame: layout.shadowFrame,
            opacity: scaledOpacity(104, by: windowOpacity),
            cornerRadius: 18,
            zOrder: 1,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        if let rejection = insertLayer(
            identifier: 2,
            color: PixelColor(xrgb: 0x0012_1a2a),
            frame: layout.windowFrame,
            opacity: windowOpacity,
            cornerRadius: 16,
            zOrder: 2,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        let focusedChrome = UInt8(
            210 + UInt16(animation.focusOpacity) * 45 / 255
        )
        if let rejection = insertLayer(
            identifier: 3,
            color: PixelColor(xrgb: 0x001c_2638),
            frame: layout.titleBarFrame,
            opacity: scaledOpacity(focusedChrome, by: windowOpacity),
            cornerRadius: 16,
            zOrder: 3,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        if let rejection = insertLayer(
            identifier: 4,
            color: PixelColor(xrgb: 0x0010_1726),
            frame: layout.sidebarFrame,
            opacity: scaledOpacity(242, by: windowOpacity),
            zOrder: 4,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        if let rejection = insertLayer(
            identifier: 5,
            color: PixelColor(xrgb: 0x0017_2234),
            frame: layout.listFrame,
            opacity: scaledOpacity(248, by: windowOpacity),
            zOrder: 4,
            into: &tree
        ) {
            return .rejected(rejection)
        }

        let selectedVisibleRow: Int?
        if let selectedIndex = model.selectedIndex {
            let row = selectedIndex - model.firstVisibleIndex
            selectedVisibleRow = row >= 0 && row < model.visibleItemCount
                ? row
                : nil
        } else {
            selectedVisibleRow = nil
        }
        guard let fallbackRow = layout.listRowFrame(at: 0) else {
            return .rejected(.retainedTreeRejected)
        }
        let selectedFrame = selectedVisibleRow.flatMap {
            layout.listRowFrame(at: $0)
        } ?? fallbackRow
        if let rejection = insertLayer(
            identifier: 6,
            color: PixelColor(xrgb: 0x0025_67d8),
            frame: selectedFrame,
            opacity: scaledOpacity(
                animation.selectionOpacity,
                by: windowOpacity
            ),
            cornerRadius: 8,
            zOrder: 5,
            isVisible: selectedVisibleRow != nil
                && animation.selectionOpacity != 0,
            into: &tree
        ) {
            return .rejected(rejection)
        }

        let validHoverRow = hoveredVisibleRow.flatMap { row in
            row >= 0 && row < model.visibleItemCount
                && row != selectedVisibleRow ? row : nil
        }
        let hoverFrame = validHoverRow.flatMap {
            layout.listRowFrame(at: $0)
        } ?? fallbackRow
        if let rejection = insertLayer(
            identifier: 7,
            color: PixelColor(xrgb: 0x0047_5b78),
            frame: hoverFrame,
            opacity: scaledOpacity(animation.hoverOpacity, by: windowOpacity),
            cornerRadius: 8,
            zOrder: 5,
            isVisible: validHoverRow != nil && animation.hoverOpacity != 0,
            into: &tree
        ) {
            return .rejected(rejection)
        }

        guard let cursorFrame = cursorFrame(for: cursor) else {
            return .rejected(.invalidCursorFrame)
        }
        if let rejection = insertLayer(
            identifier: 8,
            color: .white,
            frame: cursorFrame,
            clip: layout.desktopBounds,
            opacity: 255,
            cornerRadius: 2,
            zOrder: 100,
            isVisible: cursor.isVisible && animation.cursorIsVisible,
            into: &tree
        ) {
            return .rejected(rejection)
        }

        guard var damage = DamageRegion(logicalBounds: viewport.logicalBounds)
        else {
            return .rejected(.damageRegionRejected)
        }
        damage.addFullDamage()
        let chrome: GPURetainedSceneCompilation
        switch GPURetainedSceneCompiler.compile(
            tree: tree,
            damage: damage,
            viewport: viewport,
            backgroundColor: .wallpaper,
            target: target,
            targetFormat: targetFormat,
            commandBufferID: chromeCommandBufferID
        ) {
        case .compiled(let compilation):
            chrome = compilation
        case .nothingToRender:
            return .rejected(.chromeCompilationEmpty)
        case .rejected(let rejection):
            return .rejected(.chromeCompilationRejected(rejection))
        }

        let text: TextCompilation
        switch compileText(
            model: model,
            layout: layout,
            viewport: viewport,
            target: target,
            targetFormat: targetFormat,
            fontAtlas: fontAtlas,
            windowOpacity: windowOpacity,
            commandBufferID: textCommandBufferID
        ) {
        case .compiled(let compilation):
            text = compilation
        case .rejected(let rejection):
            return .rejected(rejection)
        }

        guard let fullDamage = GPUScissorRectangle(
                  x: 0,
                  y: 0,
                  width: UInt32(exactly: viewport.physicalWidth) ?? 0,
                  height: UInt32(exactly: viewport.physicalHeight) ?? 0
              )
        else {
            return .rejected(.physicalGeometryOutOfRange)
        }
        return .frame(
            GPUFileManagerSceneFrame(
                chromeCommandBuffer: chrome.commandBuffer,
                textCommandBuffer: text.commandBuffer,
                presentationDamage: chrome.usedAttachmentClear
                    ? fullDamage
                    : chrome.physicalDamage,
                chromeLayerCount: chrome.drawnLayerCount,
                glyphCount: text.glyphCount,
                visibleFileRowCount: text.visibleFileRowCount
            )
        )
    }

    private struct TextCompilation {
        let commandBuffer: GPURenderCommandBuffer
        let glyphCount: Int
        let visibleFileRowCount: Int
    }

    private enum TextCompilationResult {
        case compiled(TextCompilation)
        case rejected(GPUFileManagerSceneRejection)
    }

    private static func compileText(
        model: FileBrowserModel,
        layout: FileManagerLayout,
        viewport: DisplayViewport,
        target: GPURenderTargetID,
        targetFormat: GPUColorAttachmentFormat,
        fontAtlas: GPUTextureID,
        windowOpacity: UInt8,
        commandBufferID: GPUCommandBufferID
    ) -> TextCompilationResult {
        guard viewport.physicalWidth > 0,
              viewport.physicalHeight > 0,
              let width = UInt32(exactly: viewport.physicalWidth),
              let height = UInt32(exactly: viewport.physicalHeight),
              let windowPhysical = viewport.transformClipped(layout.windowFrame),
              let scissor = GPUScissorRectangle(
                  x: UInt32(exactly: windowPhysical.x) ?? UInt32.max,
                  y: UInt32(exactly: windowPhysical.y) ?? UInt32.max,
                  width: UInt32(exactly: windowPhysical.width) ?? 0,
                  height: UInt32(exactly: windowPhysical.height) ?? 0
              ),
              let scale = GPUFixed16(whole: viewport.scale),
              let translationX = GPUFixed16(whole: viewport.origin.x),
              let translationY = GPUFixed16(whole: viewport.origin.y),
              var recorder = GPUCommandRecorder(
                  id: commandBufferID,
                  capacity: GPUCommandRecorder.maximumCommandCount
              )
        else {
            return .rejected(.physicalGeometryOutOfRange)
        }
        let pass = GPURenderPassDescriptor(
            target: target,
            extent: GPUPixelExtent(width: width, height: height)!,
            format: targetFormat,
            loadAction: .load
        )
        if let rejection = record(.beginRenderPass(pass), into: &recorder) {
            return .rejected(.textCommandRejected(rejection))
        }
        if let rejection = record(
            .setScissor(.rectangle(scissor)),
            into: &recorder
        ) {
            return .rejected(.textCommandRejected(rejection))
        }
        let transform = GPUTransform2D(
            m11: scale,
            m12: .zero,
            m21: .zero,
            m22: scale,
            translationX: translationX,
            translationY: translationY
        )
        if let rejection = record(.setTransform(transform), into: &recorder) {
            return .rejected(.textCommandRejected(rejection))
        }

        let titleColor = textColor(gray: 65_535, opacity: windowOpacity)
        let mutedColor = textColor(gray: 42_000, opacity: windowOpacity)
        let fileColor = textColor(gray: 57_000, opacity: windowOpacity)
        var glyphCount = 0
        guard record(
                  label: .title,
                  x: layout.titleBarFrame.x + 48,
                  y: layout.titleBarFrame.y + 18,
                  color: titleColor,
                  fontAtlas: fontAtlas,
                  recorder: &recorder,
                  glyphCount: &glyphCount
              ), let systemFrame = layout.sidebarItemFrame(at: 0),
              record(
                  label: .system,
                  x: systemFrame.x + 10,
                  y: systemFrame.y + 13,
                  color: mutedColor,
                  fontAtlas: fontAtlas,
                  recorder: &recorder,
                  glyphCount: &glyphCount
              ), let userFrame = layout.sidebarItemFrame(at: 1),
              record(
                  label: .user,
                  x: userFrame.x + 10,
                  y: userFrame.y + 13,
                  color: mutedColor,
                  fontAtlas: fontAtlas,
                  recorder: &recorder,
                  glyphCount: &glyphCount
              )
        else {
            return .rejected(.textRecorderRejected)
        }

        let renderableRows = minimum(
            minimum(model.visibleItemCount, layout.rowCapacity),
            maximumRenderedFileRows
        )
        var renderedRows = 0
        if renderableRows == 0 {
            guard record(
                      label: .empty,
                      x: layout.listFrame.x + 18,
                      y: layout.listFrame.y + 13,
                      color: mutedColor,
                      fontAtlas: fontAtlas,
                      recorder: &recorder,
                      glyphCount: &glyphCount
                  )
            else {
                return .rejected(.textRecorderRejected)
            }
        } else {
            let remainingGlyphs = maximumGlyphCount - glyphCount
            let perRowBudget = maximum(
                1,
                minimum(8, remainingGlyphs / renderableRows)
            )
            var row = 0
            while row < renderableRows {
                guard let item = model.visibleItem(atRow: row),
                      let rowFrame = layout.listRowFrame(at: row),
                      record(
                          name: item.name,
                          maximumScalars: perRowBudget,
                          x: rowFrame.x + 14,
                          y: rowFrame.y + 13,
                          color: fileColor,
                          fontAtlas: fontAtlas,
                          recorder: &recorder,
                          glyphCount: &glyphCount
                      )
                else {
                    return .rejected(.textRecorderRejected)
                }
                renderedRows += 1
                row += 1
            }
        }

        if let rejection = record(.endRenderPass, into: &recorder) {
            return .rejected(.textCommandRejected(rejection))
        }
        switch recorder.seal() {
        case .sealed(let commandBuffer):
            return .compiled(
                TextCompilation(
                    commandBuffer: commandBuffer,
                    glyphCount: glyphCount,
                    visibleFileRowCount: renderedRows
                )
            )
        case .rejected(let rejection):
            return .rejected(.textSealRejected(rejection))
        }
    }

    private static func record(
        label: FixedLabel,
        x: Int,
        y: Int,
        color: GPUPremultipliedColor,
        fontAtlas: GPUTextureID,
        recorder: inout GPUCommandRecorder,
        glyphCount: inout Int
    ) -> Bool {
        var index = 0
        while index < label.count {
            guard let byte = label.byte(at: index),
                  recordGlyph(
                      scalar: UInt32(byte),
                      x: x + index * 7,
                      y: y,
                      color: color,
                      fontAtlas: fontAtlas,
                      recorder: &recorder,
                      glyphCount: &glyphCount
                  )
            else {
                return false
            }
            index += 1
        }
        return true
    }

    private static func record(
        name: FileBrowserNameView,
        maximumScalars: Int,
        x: Int,
        y: Int,
        color: GPUPremultipliedColor,
        fontAtlas: GPUTextureID,
        recorder: inout GPUCommandRecorder,
        glyphCount: inout Int
    ) -> Bool {
        var byteOffset = 0
        var scalarIndex = 0
        while byteOffset < name.byteCount, scalarIndex < maximumScalars {
            guard let scalar = nextScalar(in: name, byteOffset: &byteOffset),
                  recordGlyph(
                      scalar: scalar,
                      x: x + scalarIndex * 7,
                      y: y,
                      color: color,
                      fontAtlas: fontAtlas,
                      recorder: &recorder,
                      glyphCount: &glyphCount
                  )
            else {
                return false
            }
            scalarIndex += 1
        }
        return true
    }

    private static func recordGlyph(
        scalar: UInt32,
        x: Int,
        y: Int,
        color: GPUPremultipliedColor,
        fontAtlas: GPUTextureID,
        recorder: inout GPUCommandRecorder,
        glyphCount: inout Int
    ) -> Bool {
        guard glyphCount < maximumGlyphCount,
              let fixedX = GPUFixed16(whole: x),
              let fixedY = GPUFixed16(whole: y),
              let width = GPUFixed16(whole: 5),
              let height = GPUFixed16(whole: 7),
              let bounds = GPUFixedRectangle(
                  x: fixedX,
                  y: fixedY,
                  width: width,
                  height: height
              )
        else {
            return false
        }
        let glyph = GPUMaskFontAtlasLayout.glyph(for: scalar)
        let instance = GPUGlyphAtlasInstance(
            atlas: fontAtlas,
            bounds: bounds,
            textureRegion: glyph.maskTextureRegion,
            color: color,
            coverage: .mask,
            filter: .nearest,
            blendMode: .sourceOver
        )
        switch recorder.record(.drawGlyph(instance)) {
        case .recorded:
            glyphCount += 1
            return true
        case .rejected:
            return false
        }
    }

    private static func nextScalar(
        in name: FileBrowserNameView,
        byteOffset: inout Int
    ) -> UInt32? {
        guard let first = name.byte(at: byteOffset) else { return nil }
        if first < 0x80 {
            byteOffset += 1
            return UInt32(first)
        }
        let length: Int
        var scalar: UInt32
        if first & 0xe0 == 0xc0 {
            length = 2
            scalar = UInt32(first & 0x1f)
        } else if first & 0xf0 == 0xe0 {
            length = 3
            scalar = UInt32(first & 0x0f)
        } else if first & 0xf8 == 0xf0 {
            length = 4
            scalar = UInt32(first & 0x07)
        } else {
            byteOffset += 1
            return 0xfffd
        }
        guard byteOffset <= name.byteCount - length else {
            byteOffset = name.byteCount
            return 0xfffd
        }
        var index = 1
        while index < length {
            guard let byte = name.byte(at: byteOffset + index),
                  byte & 0xc0 == 0x80
            else {
                byteOffset += 1
                return 0xfffd
            }
            scalar = scalar << 6 | UInt32(byte & 0x3f)
            index += 1
        }
        byteOffset += length
        return scalar
    }

    private static func insertLayer(
        identifier rawIdentifier: UInt64,
        color: PixelColor,
        frame: Rectangle,
        clip: Rectangle? = nil,
        opacity: UInt8,
        cornerRadius: Int = 0,
        zOrder: Int32,
        isVisible: Bool = true,
        into tree: inout RetainedLayerTree
    ) -> GPUFileManagerSceneRejection? {
        guard let identifier = LayerID(rawValue: rawIdentifier),
              let layer = RetainedLayer(
                  id: identifier,
                  content: .solidColor(color),
                  frame: frame,
                  clip: clip,
                  opacity: opacity,
                  cornerRadius: cornerRadius,
                  zOrder: zOrder,
                  isVisible: isVisible
              )
        else {
            return .retainedLayerRejected(identifier: rawIdentifier)
        }
        switch tree.insert(layer) {
        case .applied:
            return nil
        case .rejected(let rejection):
            return .retainedLayerInsertionRejected(
                identifier: rawIdentifier,
                reason: rejection
            )
        }
    }

    private static func textColor(
        gray: UInt16,
        opacity: UInt8
    ) -> GPUPremultipliedColor {
        let alpha = UInt16(opacity) * 257
        let component = UInt16(
            (UInt32(gray) * UInt32(alpha) + 32_767) / 65_535
        )
        return GPUPremultipliedColor(
            red: component,
            green: component,
            blue: component,
            alpha: alpha
        )!
    }

    private static func scaledOpacity(_ opacity: UInt8, by factor: UInt8) -> UInt8 {
        UInt8((UInt16(opacity) * UInt16(factor) + 127) / 255)
    }

    private static func cursorFrame(
        for cursor: DesktopCursorState
    ) -> Rectangle? {
        let width: Int
        let height: Int
        switch cursor.shape {
        case .arrow:
            width = 10
            height = 16
        case .text:
            width = 2
            height = 16
        case .pointingHand:
            width = 12
            height = 12
        case .resizeHorizontal:
            width = 16
            height = 4
        case .resizeVertical:
            width = 4
            height = 16
        case .resizeDiagonalDown, .resizeDiagonalUp:
            width = 12
            height = 6
        }
        let frame = Rectangle(
            x: cursor.position.x,
            y: cursor.position.y,
            width: width,
            height: height
        )
        return isValid(frame) ? frame : nil
    }

    private static func isValid(_ rectangle: Rectangle) -> Bool {
        guard rectangle.width > 0, rectangle.height > 0 else { return false }
        return !rectangle.x.addingReportingOverflow(rectangle.width).overflow
            && !rectangle.y.addingReportingOverflow(rectangle.height).overflow
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
        case .recorded: return nil
        case .rejected(let rejection): return rejection
        }
    }

    private static func minimum(_ left: Int, _ right: Int) -> Int {
        left < right ? left : right
    }

    private static func maximum(_ left: Int, _ right: Int) -> Int {
        left > right ? left : right
    }
}
