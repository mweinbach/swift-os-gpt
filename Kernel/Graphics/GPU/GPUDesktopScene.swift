/// Builds the first production desktop entirely as retained, device-neutral
/// GPU work. This layer owns UI policy only: it never sees a framebuffer,
/// transport, VirGL object, or native Pi resource.

struct GPUDesktopSceneFrame {
    let commandBuffer: GPURenderCommandBuffer
    let presentationDamage: GPUScissorRectangle
    let layerCount: Int
    let viewportScale: Int
}

enum GPUDesktopSceneRejection: Equatable {
    case invalidPhysicalExtent
    case displayModeRejected
    case viewportRejected
    case retainedTreeRejected
    case layerRejected(identifier: UInt64)
    case layerInsertionRejected(
        identifier: UInt64,
        reason: RetainedLayerMutationRejection
    )
    case damageRegionRejected
    case sceneCompilationRejected(GPURetainedSceneCompileRejection)
    case emptySceneCompilation
}

enum GPUDesktopSceneResult {
    case frame(GPUDesktopSceneFrame)
    case rejected(GPUDesktopSceneRejection)
}

enum GPUDesktopScene {
    static let logicalWidth = 800
    static let logicalHeight = 600
    static let maximumPhysicalCoordinate: UInt32 = 32_767

    static func makeInitialFrame(
        physicalWidth: UInt32,
        physicalHeight: UInt32,
        target: GPURenderTargetID,
        commandBufferID: GPUCommandBufferID,
        preferredScale: Int? = nil
    ) -> GPUDesktopSceneResult {
        guard physicalWidth >= 320,
              physicalHeight >= 200,
              physicalWidth <= maximumPhysicalCoordinate,
              physicalHeight <= maximumPhysicalCoordinate
        else {
            return .rejected(.invalidPhysicalExtent)
        }
        guard let mode = DisplayMode(
                  widthInPixels: physicalWidth,
                  heightInPixels: physicalHeight,
                  refreshRateMilliHertz: nil,
                  pixelFormat: .b8g8r8a8
              )
        else {
            return .rejected(.displayModeRejected)
        }
        guard let viewport = DisplayViewport(
                  mode: mode,
                  logicalWidth: logicalWidth,
                  logicalHeight: logicalHeight,
                  preferredScale: preferredScale
              )
        else {
            return .rejected(.viewportRejected)
        }
        guard var tree = RetainedLayerTree(capacity: 5) else {
            return .rejected(.retainedTreeRejected)
        }

        if let rejection = insertLayer(
            identifier: 1,
            color: .chrome,
            frame: Rectangle(x: 0, y: 0, width: 800, height: 44),
            opacity: 224,
            zOrder: 1,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        if let rejection = insertLayer(
            identifier: 2,
            color: .panel,
            frame: Rectangle(x: 72, y: 90, width: 656, height: 420),
            opacity: 240,
            zOrder: 2,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        if let rejection = insertLayer(
            identifier: 3,
            color: .terminal,
            frame: Rectangle(x: 72, y: 90, width: 164, height: 420),
            opacity: 216,
            zOrder: 3,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        if let rejection = insertLayer(
            identifier: 4,
            color: .cyan,
            frame: Rectangle(x: 260, y: 116, width: 438, height: 92),
            opacity: 240,
            zOrder: 4,
            into: &tree
        ) {
            return .rejected(rejection)
        }
        if let rejection = insertLayer(
            identifier: 5,
            color: .panel,
            frame: Rectangle(x: 270, y: 540, width: 260, height: 44),
            opacity: 208,
            zOrder: 5,
            into: &tree
        ) {
            return .rejected(rejection)
        }

        guard var damage = DamageRegion(logicalBounds: viewport.logicalBounds)
        else {
            return .rejected(.damageRegionRejected)
        }
        damage.addFullDamage()
        switch GPURetainedSceneCompiler.compile(
            tree: tree,
            damage: damage,
            viewport: viewport,
            backgroundColor: .wallpaper,
            target: target,
            targetFormat: .bgra8UNormSRGB,
            commandBufferID: commandBufferID
        ) {
        case .nothingToRender:
            return .rejected(.emptySceneCompilation)
        case .rejected(let rejection):
            return .rejected(.sceneCompilationRejected(rejection))
        case .compiled(let compilation):
            guard let fullDamage = GPUScissorRectangle(
                      x: 0,
                      y: 0,
                      width: physicalWidth,
                      height: physicalHeight
                  )
            else {
                return .rejected(.invalidPhysicalExtent)
            }
            // A full-damage compile clears the entire attachment, including
            // letterbox pixels outside the logical viewport. Present all of
            // those GPU writes, not only the logical content rectangle.
            return .frame(
                GPUDesktopSceneFrame(
                    commandBuffer: compilation.commandBuffer,
                    presentationDamage: compilation.usedAttachmentClear
                        ? fullDamage
                        : compilation.physicalDamage,
                    layerCount: compilation.drawnLayerCount,
                    viewportScale: viewport.scale
                )
            )
        }
    }

    private static func insertLayer(
        identifier rawIdentifier: UInt64,
        color: PixelColor,
        frame: Rectangle,
        opacity: UInt8,
        zOrder: Int32,
        into tree: inout RetainedLayerTree
    ) -> GPUDesktopSceneRejection? {
        guard let identifier = LayerID(rawValue: rawIdentifier),
              let layer = RetainedLayer(
                  id: identifier,
                  content: .solidColor(color),
                  frame: frame,
                  opacity: opacity,
                  cornerRadius: 0,
                  zOrder: zOrder
              )
        else {
            return .layerRejected(identifier: rawIdentifier)
        }
        switch tree.insert(layer) {
        case .applied:
            return nil
        case .rejected(let rejection):
            return .layerInsertionRejected(
                identifier: rawIdentifier,
                reason: rejection
            )
        }
    }
}
