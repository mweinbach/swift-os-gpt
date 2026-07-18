/// A stable visual-layer identity. Zero is reserved for unused backing-store
/// entries, so every identifier exposed by the tree names a real layer.
struct LayerID: Equatable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }

    fileprivate init(uncheckedRawValue: UInt64) {
        rawValue = uncheckedRawValue
    }
}

/// Retained content understood by the first software compositor. The enum is
/// intentionally extensible without coupling tree policy to a framebuffer.
enum RetainedLayerContent: Equatable {
    case solidColor(PixelColor)
}

/// A complete immutable layer description. Updating a layer means submitting
/// a newly validated value with the same stable identifier.
struct RetainedLayer {
    let id: LayerID
    let content: RetainedLayerContent
    let frame: Rectangle

    /// Optional clip in the same logical coordinate space as `frame`.
    let clip: Rectangle?
    let opacity: UInt8
    let cornerRadius: Int
    let zOrder: Int32
    let isVisible: Bool

    init?(
        id: LayerID,
        content: RetainedLayerContent,
        frame: Rectangle,
        clip: Rectangle? = nil,
        opacity: UInt8 = .max,
        cornerRadius: Int = 0,
        zOrder: Int32 = 0,
        isVisible: Bool = true
    ) {
        guard RetainedLayerGeometry.isValid(frame),
              cornerRadius >= 0,
              cornerRadius <= RetainedLayerGeometry.maximumCornerRadius(
                  for: frame
              )
        else {
            return nil
        }
        if let clip, !RetainedLayerGeometry.isValid(clip) {
            return nil
        }
        self.id = id
        self.content = content
        self.frame = frame
        self.clip = clip
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.zOrder = zOrder
        self.isVisible = isVisible
    }

    /// Bounding box that can currently affect composition. Rounded corners do
    /// not shrink the conservative damage rectangle.
    var visibleBounds: Rectangle? {
        guard isVisible, opacity != 0 else { return nil }
        guard let clip else { return frame }
        return RetainedLayerGeometry.intersection(frame, clip)
    }

    fileprivate var isValid: Bool {
        guard id.rawValue != 0,
              RetainedLayerGeometry.isValid(frame),
              cornerRadius >= 0,
              cornerRadius
                  <= RetainedLayerGeometry.maximumCornerRadius(for: frame)
        else {
            return false
        }
        if let clip, !RetainedLayerGeometry.isValid(clip) { return false }
        return true
    }

    private init(vacant: ()) {
        id = LayerID(uncheckedRawValue: 0)
        content = .solidColor(.transparentBlack)
        frame = Rectangle(x: 0, y: 0, width: 1, height: 1)
        clip = nil
        opacity = 0
        cornerRadius = 0
        zOrder = 0
        isVisible = false
    }

    fileprivate static let vacant = RetainedLayer(vacant: ())
}

/// Conservative repaint bounds before and after one retained-tree mutation.
/// Keeping both rectangles lets a compositor invalidate a moved layer's old
/// pixels as well as its new pixels without allocating a region list.
struct RetainedLayerDamage {
    let oldBounds: Rectangle?
    let newBounds: Rectangle?
}

enum RetainedLayerMutationKind: UInt8, Equatable {
    case inserted
    case updated
    case removed
}

struct RetainedLayerMutation {
    let kind: RetainedLayerMutationKind
    let id: LayerID
    let oldPainterIndex: Int?
    let newPainterIndex: Int?
    let damage: RetainedLayerDamage
}

enum RetainedLayerMutationRejection: Equatable {
    case duplicateIdentifier(existingPainterIndex: Int)
    case identifierNotFound
    case capacityExhausted
    case invalidLayer
}

enum RetainedLayerMutationResult {
    case applied(RetainedLayerMutation)
    case rejected(RetainedLayerMutationRejection)
}

/// Fixed-capacity retained visual state with storage held directly in the
/// value. Layers are sorted at mutation time: lower z first, then lower stable
/// identifier. Composition therefore performs one deterministic linear walk
/// with no heap, temporary array, self-referential pointer, or per-frame sort.
struct RetainedLayerTree {
    static let maximumLayerCount = 8

    let capacity: Int
    private(set) var count: Int = 0

    private var layer0 = RetainedLayer.vacant
    private var layer1 = RetainedLayer.vacant
    private var layer2 = RetainedLayer.vacant
    private var layer3 = RetainedLayer.vacant
    private var layer4 = RetainedLayer.vacant
    private var layer5 = RetainedLayer.vacant
    private var layer6 = RetainedLayer.vacant
    private var layer7 = RetainedLayer.vacant

    init?(capacity: Int = maximumLayerCount) {
        guard capacity > 0,
              capacity <= Self.maximumLayerCount
        else {
            return nil
        }
        self.capacity = capacity
    }

    /// Returns layers in back-to-front painter order.
    func layer(atPainterIndex index: Int) -> RetainedLayer? {
        guard index >= 0, index < count else { return nil }
        return storedLayer(at: index)
    }

    func layer(withID id: LayerID) -> RetainedLayer? {
        guard let index = painterIndex(for: id) else { return nil }
        return storedLayer(at: index)
    }

    func painterIndex(for id: LayerID) -> Int? {
        var index = 0
        while index < count {
            if storedLayer(at: index).id == id { return index }
            index += 1
        }
        return nil
    }

    mutating func insert(
        _ layer: RetainedLayer
    ) -> RetainedLayerMutationResult {
        guard layer.isValid else { return .rejected(.invalidLayer) }
        if let existingIndex = painterIndex(for: layer.id) {
            return .rejected(
                .duplicateIdentifier(existingPainterIndex: existingIndex)
            )
        }
        guard count < capacity else {
            return .rejected(.capacityExhausted)
        }

        let insertionIndex = painterInsertionIndex(for: layer)
        makeGap(at: insertionIndex)
        setStoredLayer(layer, at: insertionIndex)
        count += 1
        return .applied(
            RetainedLayerMutation(
                kind: .inserted,
                id: layer.id,
                oldPainterIndex: nil,
                newPainterIndex: insertionIndex,
                damage: RetainedLayerDamage(
                    oldBounds: nil,
                    newBounds: layer.visibleBounds
                )
            )
        )
    }

    /// Inserts a missing identifier or replaces an existing identifier. An
    /// update remains possible at full capacity because it reuses its slot.
    mutating func upsert(
        _ layer: RetainedLayer
    ) -> RetainedLayerMutationResult {
        guard layer.isValid else { return .rejected(.invalidLayer) }
        if painterIndex(for: layer.id) != nil {
            return replaceExisting(with: layer)
        }
        return insert(layer)
    }

    /// Replaces an existing identifier and restores deterministic painter
    /// order if its z-order changed.
    mutating func update(
        _ layer: RetainedLayer
    ) -> RetainedLayerMutationResult {
        guard layer.isValid else { return .rejected(.invalidLayer) }
        guard painterIndex(for: layer.id) != nil else {
            return .rejected(.identifierNotFound)
        }
        return replaceExisting(with: layer)
    }

    mutating func remove(
        id: LayerID
    ) -> RetainedLayerMutationResult {
        guard let index = painterIndex(for: id) else {
            return .rejected(.identifierNotFound)
        }
        let oldLayer = storedLayer(at: index)
        closeGap(at: index)
        count -= 1
        setStoredLayer(.vacant, at: count)
        return .applied(
            RetainedLayerMutation(
                kind: .removed,
                id: id,
                oldPainterIndex: index,
                newPainterIndex: nil,
                damage: RetainedLayerDamage(
                    oldBounds: oldLayer.visibleBounds,
                    newBounds: nil
                )
            )
        )
    }

    private mutating func replaceExisting(
        with layer: RetainedLayer
    ) -> RetainedLayerMutationResult {
        guard let oldIndex = painterIndex(for: layer.id) else {
            return .rejected(.identifierNotFound)
        }
        let oldLayer = storedLayer(at: oldIndex)

        closeGap(at: oldIndex)
        count -= 1
        let newIndex = painterInsertionIndex(for: layer)
        makeGap(at: newIndex)
        setStoredLayer(layer, at: newIndex)
        count += 1

        return .applied(
            RetainedLayerMutation(
                kind: .updated,
                id: layer.id,
                oldPainterIndex: oldIndex,
                newPainterIndex: newIndex,
                damage: RetainedLayerDamage(
                    oldBounds: oldLayer.visibleBounds,
                    newBounds: layer.visibleBounds
                )
            )
        )
    }

    private func painterInsertionIndex(for layer: RetainedLayer) -> Int {
        var index = 0
        while index < count {
            if isPaintedBefore(layer, storedLayer(at: index)) { return index }
            index += 1
        }
        return count
    }

    private func isPaintedBefore(
        _ first: RetainedLayer,
        _ second: RetainedLayer
    ) -> Bool {
        if first.zOrder != second.zOrder {
            return first.zOrder < second.zOrder
        }
        return first.id.rawValue < second.id.rawValue
    }

    private mutating func makeGap(at index: Int) {
        var destination = count
        while destination > index {
            setStoredLayer(storedLayer(at: destination - 1), at: destination)
            destination -= 1
        }
    }

    private mutating func closeGap(at index: Int) {
        var destination = index
        while destination + 1 < count {
            setStoredLayer(storedLayer(at: destination + 1), at: destination)
            destination += 1
        }
    }

    private func storedLayer(at index: Int) -> RetainedLayer {
        switch index {
        case 0: return layer0
        case 1: return layer1
        case 2: return layer2
        case 3: return layer3
        case 4: return layer4
        case 5: return layer5
        case 6: return layer6
        default: return layer7
        }
    }

    private mutating func setStoredLayer(
        _ layer: RetainedLayer,
        at index: Int
    ) {
        switch index {
        case 0: layer0 = layer
        case 1: layer1 = layer
        case 2: layer2 = layer
        case 3: layer3 = layer
        case 4: layer4 = layer
        case 5: layer5 = layer
        case 6: layer6 = layer
        default: layer7 = layer
        }
    }
}

private enum RetainedLayerGeometry {
    static func isValid(_ rectangle: Rectangle) -> Bool {
        guard rectangle.width > 0, rectangle.height > 0 else { return false }
        let endX = rectangle.x.addingReportingOverflow(rectangle.width)
        let endY = rectangle.y.addingReportingOverflow(rectangle.height)
        return !endX.overflow && !endY.overflow
    }

    static func maximumCornerRadius(for rectangle: Rectangle) -> Int {
        let shortestSide = rectangle.width < rectangle.height
            ? rectangle.width
            : rectangle.height
        return shortestSide / 2
    }

    static func intersection(
        _ first: Rectangle,
        _ second: Rectangle
    ) -> Rectangle? {
        let firstEndX = first.x + first.width
        let firstEndY = first.y + first.height
        let secondEndX = second.x + second.width
        let secondEndY = second.y + second.height
        let startX = first.x > second.x ? first.x : second.x
        let startY = first.y > second.y ? first.y : second.y
        let endX = firstEndX < secondEndX ? firstEndX : secondEndX
        let endY = firstEndY < secondEndY ? firstEndY : secondEndY
        guard startX < endX, startY < endY else { return nil }
        return Rectangle(
            x: startX,
            y: startY,
            width: endX - startX,
            height: endY - startY
        )
    }
}
