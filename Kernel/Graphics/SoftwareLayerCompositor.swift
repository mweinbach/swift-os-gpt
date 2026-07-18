/// Retained solid-layer compositor over the board-independent logical canvas.
///
/// The tree owns visual state, DamageRegion owns invalidation, and the canvas
/// owns logical-to-physical mapping. Display drivers only receive the resulting
/// physical damage rectangles; no board conditionals enter composition.
enum SoftwareLayerCompositor {
    /// Adds both sides of an applied mutation. A move must repaint the pixels
    /// at the old frame as well as the pixels at the new frame.
    @discardableResult
    static func recordDamage(
        from result: RetainedLayerMutationResult,
        in damage: inout DamageRegion
    ) -> Bool {
        guard case .applied(let mutation) = result else { return false }
        if let oldBounds = mutation.damage.oldBounds {
            damage.add(oldBounds)
        }
        if let newBounds = mutation.damage.newBounds {
            damage.add(newBounds)
        }
        return true
    }

    /// Repaints each invalid rectangle from a known background and walks the
    /// retained tree in deterministic back-to-front painter order.
    @discardableResult
    static func render(
        tree: RetainedLayerTree,
        damage: DamageRegion,
        backgroundColor: PixelColor,
        on canvas: ScaledFramebufferCanvas
    ) -> Bool {
        guard sameRectangle(damage.logicalBounds, canvas.viewport.logicalBounds)
        else {
            return false
        }

        var succeeded = true
        damage.forEachRectangle { damagedRectangle in
            guard succeeded,
                  canvas.blend(
                      damagedRectangle,
                      color: backgroundColor,
                      opacity: 255,
                      clippedTo: damagedRectangle
                  )
            else {
                succeeded = false
                return
            }

            var layerIndex = 0
            while layerIndex < tree.count {
                guard let layer = tree.layer(atPainterIndex: layerIndex) else {
                    succeeded = false
                    return
                }
                layerIndex += 1
                guard layer.isVisible,
                      layer.opacity != 0,
                      let visibleBounds = layer.visibleBounds,
                      intersects(visibleBounds, damagedRectangle)
                else {
                    continue
                }

                let layerClip: Rectangle
                if let clip = layer.clip {
                    guard let intersection = intersection(
                              clip,
                              damagedRectangle
                          )
                    else {
                        continue
                    }
                    layerClip = intersection
                } else {
                    layerClip = damagedRectangle
                }

                switch layer.content {
                case .solidColor(let color):
                    guard canvas.blend(
                              layer.frame,
                              color: color,
                              opacity: layer.opacity,
                              cornerRadius: layer.cornerRadius,
                              clippedTo: layerClip
                          )
                    else {
                        succeeded = false
                        return
                    }
                }
            }
        }
        return succeeded
    }

    private static func intersects(
        _ first: Rectangle,
        _ second: Rectangle
    ) -> Bool {
        intersection(first, second) != nil
    }

    private static func intersection(
        _ first: Rectangle,
        _ second: Rectangle
    ) -> Rectangle? {
        guard let firstEndX = checkedEnd(first.x, first.width),
              let firstEndY = checkedEnd(first.y, first.height),
              let secondEndX = checkedEnd(second.x, second.width),
              let secondEndY = checkedEnd(second.y, second.height)
        else {
            return nil
        }
        let startX = maximum(first.x, second.x)
        let startY = maximum(first.y, second.y)
        let endX = minimum(firstEndX, secondEndX)
        let endY = minimum(firstEndY, secondEndY)
        guard startX < endX, startY < endY else { return nil }
        return Rectangle(
            x: startX,
            y: startY,
            width: endX - startX,
            height: endY - startY
        )
    }

    private static func checkedEnd(_ start: Int, _ length: Int) -> Int? {
        guard length > 0 else { return nil }
        let result = start.addingReportingOverflow(length)
        return result.overflow ? nil : result.partialValue
    }

    private static func sameRectangle(
        _ first: Rectangle,
        _ second: Rectangle
    ) -> Bool {
        first.x == second.x && first.y == second.y
            && first.width == second.width && first.height == second.height
    }

    private static func minimum(_ left: Int, _ right: Int) -> Int {
        left < right ? left : right
    }

    private static func maximum(_ left: Int, _ right: Int) -> Int {
        left > right ? left : right
    }
}
