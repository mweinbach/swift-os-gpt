/// An allocation-free set of damaged rectangles in a logical coordinate space.
///
/// Rectangles are clipped to `logicalBounds`, coalesced when they overlap or
/// touch, and kept in deterministic row-major order. If the configured inline
/// capacity cannot describe additional damage, the region conservatively
/// becomes one rectangle covering all logical bounds.
struct DamageRegion {
    /// Storage is inline so recording damage never depends on an allocator.
    static let maximumRectangleCount = 8

    let logicalBounds: Rectangle
    let capacity: Int

    private(set) var count: Int
    private(set) var isFullDamage: Bool

    private var rectangle0: Rectangle
    private var rectangle1: Rectangle
    private var rectangle2: Rectangle
    private var rectangle3: Rectangle
    private var rectangle4: Rectangle
    private var rectangle5: Rectangle
    private var rectangle6: Rectangle
    private var rectangle7: Rectangle

    /// Creates an empty region. Bounds must use positive, representable
    /// half-open dimensions and capacity must fit the inline storage.
    init?(logicalBounds: Rectangle, capacity: Int = maximumRectangleCount) {
        guard logicalBounds.width > 0, logicalBounds.height > 0,
              capacity > 0, capacity <= Self.maximumRectangleCount
        else {
            return nil
        }

        let boundsEndX = logicalBounds.x.addingReportingOverflow(
            logicalBounds.width
        )
        let boundsEndY = logicalBounds.y.addingReportingOverflow(
            logicalBounds.height
        )
        guard !boundsEndX.overflow, !boundsEndY.overflow else {
            return nil
        }

        self.logicalBounds = logicalBounds
        self.capacity = capacity
        count = 0
        isFullDamage = false

        let empty = Rectangle(x: 0, y: 0, width: 0, height: 0)
        rectangle0 = empty
        rectangle1 = empty
        rectangle2 = empty
        rectangle3 = empty
        rectangle4 = empty
        rectangle5 = empty
        rectangle6 = empty
        rectangle7 = empty
    }

    var isEmpty: Bool {
        count == 0
    }

    /// Removes all recorded damage while preserving bounds and capacity.
    mutating func clear() {
        count = 0
        isFullDamage = false
    }

    /// Records damage after normalizing negative dimensions and clipping it to
    /// the logical coordinate space. Zero-area and fully clipped rectangles do
    /// not change the region.
    mutating func add(_ rectangle: Rectangle) {
        guard !isFullDamage,
              let clipped = normalizedAndClipped(rectangle)
        else {
            return
        }

        var merged = clipped
        var index = 0
        while index < count {
            let existing = storedRectangle(at: index)
            if touchesOrOverlaps(existing, merged) {
                merged = union(existing, merged)
                remove(at: index)

                // The bounding union can reach an earlier rectangle which did
                // not touch before the merge, so restart for transitive closure.
                index = 0
            } else {
                index += 1
            }
        }

        if rectanglesEqual(merged, logicalBounds) {
            collapseToFullDamage()
            return
        }

        guard count < capacity else {
            collapseToFullDamage()
            return
        }
        insertInDeterministicOrder(merged)
    }

    /// Marks the complete logical surface as damaged.
    mutating func addFullDamage() {
        collapseToFullDamage()
    }

    /// Safe deterministic access for a compositor or scanout mapper.
    func rectangle(at index: Int) -> Rectangle? {
        guard index >= 0, index < count else {
            return nil
        }
        return storedRectangle(at: index)
    }

    subscript(index: Int) -> Rectangle? {
        rectangle(at: index)
    }

    /// Visits rectangles in the same deterministic order as indexed access.
    func forEachRectangle(_ body: (Rectangle) -> Void) {
        var index = 0
        while index < count {
            body(storedRectangle(at: index))
            index += 1
        }
    }

    /// A conservative single rectangle for display backends which cannot
    /// present multiple damage rectangles in one transaction.
    var boundingRectangle: Rectangle? {
        guard count > 0 else {
            return nil
        }

        var result = storedRectangle(at: 0)
        var index = 1
        while index < count {
            result = union(result, storedRectangle(at: index))
            index += 1
        }
        return result
    }

    private mutating func collapseToFullDamage() {
        setStoredRectangle(logicalBounds, at: 0)
        count = 1
        isFullDamage = true
    }

    private func normalizedAndClipped(
        _ rectangle: Rectangle
    ) -> Rectangle? {
        guard let horizontal = normalizedAxis(
                  origin: rectangle.x,
                  length: rectangle.width
              ),
              let vertical = normalizedAxis(
                  origin: rectangle.y,
                  length: rectangle.height
              )
        else {
            return nil
        }

        let boundsEndX = logicalBounds.x + logicalBounds.width
        let boundsEndY = logicalBounds.y + logicalBounds.height
        let clippedX = maximum(horizontal.start, logicalBounds.x)
        let clippedY = maximum(vertical.start, logicalBounds.y)
        let clippedEndX = minimum(horizontal.end, boundsEndX)
        let clippedEndY = minimum(vertical.end, boundsEndY)
        guard clippedX < clippedEndX, clippedY < clippedEndY else {
            return nil
        }

        // Both differences are bounded by a validated logical dimension, so
        // they are positive and representable as Int.
        return Rectangle(
            x: clippedX,
            y: clippedY,
            width: clippedEndX - clippedX,
            height: clippedEndY - clippedY
        )
    }

    /// Converts either direction of a nonzero half-open extent to ordered
    /// endpoints. Overflow saturates away from the origin before clipping,
    /// which never under-reports damage inside the logical bounds.
    private func normalizedAxis(
        origin: Int,
        length: Int
    ) -> (start: Int, end: Int)? {
        guard length != 0 else {
            return nil
        }

        let endpoint = origin.addingReportingOverflow(length)
        if length > 0 {
            return (
                start: origin,
                end: endpoint.overflow ? Int.max : endpoint.partialValue
            )
        }
        return (
            start: endpoint.overflow ? Int.min : endpoint.partialValue,
            end: origin
        )
    }

    private func touchesOrOverlaps(
        _ left: Rectangle,
        _ right: Rectangle
    ) -> Bool {
        let leftEndX = left.x + left.width
        let leftEndY = left.y + left.height
        let rightEndX = right.x + right.width
        let rightEndY = right.y + right.height
        return left.x <= rightEndX && right.x <= leftEndX
            && left.y <= rightEndY && right.y <= leftEndY
    }

    private func union(_ left: Rectangle, _ right: Rectangle) -> Rectangle {
        let unionX = minimum(left.x, right.x)
        let unionY = minimum(left.y, right.y)
        let unionEndX = maximum(
            left.x + left.width,
            right.x + right.width
        )
        let unionEndY = maximum(
            left.y + left.height,
            right.y + right.height
        )
        return Rectangle(
            x: unionX,
            y: unionY,
            width: unionEndX - unionX,
            height: unionEndY - unionY
        )
    }

    private mutating func insertInDeterministicOrder(_ rectangle: Rectangle) {
        var insertionIndex = count
        while insertionIndex > 0 {
            let previous = storedRectangle(at: insertionIndex - 1)
            if !isOrderedBefore(rectangle, previous) {
                break
            }
            setStoredRectangle(previous, at: insertionIndex)
            insertionIndex -= 1
        }
        setStoredRectangle(rectangle, at: insertionIndex)
        count += 1
    }

    private mutating func remove(at removedIndex: Int) {
        var index = removedIndex
        while index + 1 < count {
            setStoredRectangle(storedRectangle(at: index + 1), at: index)
            index += 1
        }
        count -= 1
    }

    /// Row-major order with complete tie-breakers makes output independent of
    /// insertion order, which keeps frame presentation and tests reproducible.
    private func isOrderedBefore(_ left: Rectangle, _ right: Rectangle) -> Bool {
        if left.y != right.y { return left.y < right.y }
        if left.x != right.x { return left.x < right.x }
        if left.height != right.height { return left.height < right.height }
        return left.width < right.width
    }

    private func rectanglesEqual(
        _ left: Rectangle,
        _ right: Rectangle
    ) -> Bool {
        left.x == right.x && left.y == right.y
            && left.width == right.width && left.height == right.height
    }

    private func storedRectangle(at index: Int) -> Rectangle {
        switch index {
        case 0: return rectangle0
        case 1: return rectangle1
        case 2: return rectangle2
        case 3: return rectangle3
        case 4: return rectangle4
        case 5: return rectangle5
        case 6: return rectangle6
        default: return rectangle7
        }
    }

    private mutating func setStoredRectangle(
        _ rectangle: Rectangle,
        at index: Int
    ) {
        switch index {
        case 0: rectangle0 = rectangle
        case 1: rectangle1 = rectangle
        case 2: rectangle2 = rectangle
        case 3: rectangle3 = rectangle
        case 4: rectangle4 = rectangle
        case 5: rectangle5 = rectangle
        case 6: rectangle6 = rectangle
        default: rectangle7 = rectangle
        }
    }

    private func minimum(_ left: Int, _ right: Int) -> Int {
        left < right ? left : right
    }

    private func maximum(_ left: Int, _ right: Int) -> Int {
        left > right ? left : right
    }
}
