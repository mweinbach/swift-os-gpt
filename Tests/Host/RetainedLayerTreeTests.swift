@main
struct RetainedLayerTreeTests {
    static func main() {
        validatesIdentifiersAndGeometry()
        maintainsDeterministicPainterOrder()
        updatesAndUpsertsWithoutAllocation()
        removesLayersAndReportsOldDamage()
        enforcesCallerSuppliedCapacity()
        copiesInlineStateWithoutAliasing()
        preservesClipMetadataAndClipsDamage()
        reflectsVisibilityAndOpacityInDamage()
        print("retained layer tree host tests: 8 groups passed")
    }

    private static func validatesIdentifiersAndGeometry() {
        expect(LayerID(rawValue: 0) == nil, "zero layer ID accepted")
        expect(LayerID(rawValue: 1)?.rawValue == 1, "valid layer ID rejected")

        let id = requireID(1)
        expect(
            RetainedLayer(
                id: id,
                content: .solidColor(.blue),
                frame: Rectangle(x: 0, y: 0, width: 0, height: 10)
            ) == nil,
            "empty frame accepted"
        )
        expect(
            RetainedLayer(
                id: id,
                content: .solidColor(.blue),
                frame: Rectangle(x: 0, y: 0, width: 10, height: -1)
            ) == nil,
            "negative frame height accepted"
        )
        expect(
            RetainedLayer(
                id: id,
                content: .solidColor(.blue),
                frame: Rectangle(
                    x: Int.max - 4,
                    y: 0,
                    width: 5,
                    height: 1
                )
            ) == nil,
            "overflowing frame accepted"
        )
        expect(
            RetainedLayer(
                id: id,
                content: .solidColor(.blue),
                frame: Rectangle(x: 0, y: 0, width: 20, height: 10),
                clip: Rectangle(
                    x: 0,
                    y: Int.max,
                    width: 1,
                    height: 1
                )
            ) == nil,
            "overflowing clip accepted"
        )
        expect(
            RetainedLayer(
                id: id,
                content: .solidColor(.blue),
                frame: Rectangle(x: 0, y: 0, width: 20, height: 10),
                cornerRadius: -1
            ) == nil,
            "negative corner radius accepted"
        )
        expect(
            RetainedLayer(
                id: id,
                content: .solidColor(.blue),
                frame: Rectangle(x: 0, y: 0, width: 20, height: 10),
                cornerRadius: 6
            ) == nil,
            "oversized corner radius accepted"
        )
        expect(
            RetainedLayer(
                id: id,
                content: .solidColor(.blue),
                frame: Rectangle(x: -20, y: -10, width: 20, height: 10),
                cornerRadius: 5
            ) != nil,
            "valid offscreen geometry rejected"
        )

        expect(
            RetainedLayerTree(capacity: 0) == nil,
            "zero inline capacity accepted"
        )
    }

    private static func maintainsDeterministicPainterOrder() {
        withTree(capacity: 4) { tree in
            let front = requireLayer(id: 9, zOrder: 10)
            let tieHighID = requireLayer(id: 7, zOrder: 2)
            let back = requireLayer(id: 5, zOrder: -3)
            let tieLowID = requireLayer(id: 3, zOrder: 2)

            expectApplied(tree.insert(front), kind: .inserted)
            expectApplied(tree.insert(tieHighID), kind: .inserted)
            expectApplied(tree.insert(back), kind: .inserted)
            let insertion = requireApplied(tree.insert(tieLowID))
            expect(insertion.newPainterIndex == 1, "tie insertion index")

            expect(tree.count == 4, "layer count after inserts")
            expect(tree.layer(atPainterIndex: 0)?.id.rawValue == 5, "back z")
            expect(tree.layer(atPainterIndex: 1)?.id.rawValue == 3, "tie ID 3")
            expect(tree.layer(atPainterIndex: 2)?.id.rawValue == 7, "tie ID 7")
            expect(tree.layer(atPainterIndex: 3)?.id.rawValue == 9, "front z")
            expect(tree.painterIndex(for: requireID(7)) == 2, "ID lookup")
            expect(tree.layer(withID: requireID(3))?.zOrder == 2, "layer lookup")
            expect(tree.layer(atPainterIndex: -1) == nil, "negative index")
            expect(tree.layer(atPainterIndex: 4) == nil, "past-end index")

            let duplicate = tree.insert(requireLayer(id: 3, zOrder: 99))
            expectRejection(
                duplicate,
                equals: .duplicateIdentifier(existingPainterIndex: 1)
            )
            expect(tree.count == 4, "duplicate changed count")
        }
    }

    private static func updatesAndUpsertsWithoutAllocation() {
        withTree(capacity: 3) { tree in
            _ = tree.insert(
                requireLayer(
                    id: 1,
                    frame: Rectangle(x: 10, y: 20, width: 30, height: 40),
                    zOrder: 0
                )
            )
            _ = tree.insert(requireLayer(id: 2, zOrder: 1))
            _ = tree.insert(requireLayer(id: 3, zOrder: 2))

            let moved = requireLayer(
                id: 1,
                color: .green,
                frame: Rectangle(x: 100, y: 120, width: 50, height: 60),
                opacity: 200,
                cornerRadius: 8,
                zOrder: 5
            )
            let update = requireApplied(tree.update(moved))
            expect(update.kind == .updated, "update mutation kind")
            expect(update.oldPainterIndex == 0, "old painter index")
            expect(update.newPainterIndex == 2, "new painter index")
            expectRectangle(
                update.damage.oldBounds,
                x: 10,
                y: 20,
                width: 30,
                height: 40,
                "update old damage"
            )
            expectRectangle(
                update.damage.newBounds,
                x: 100,
                y: 120,
                width: 50,
                height: 60,
                "update new damage"
            )
            expect(tree.count == 3, "full-capacity update changed count")
            expect(tree.layer(atPainterIndex: 2)?.id.rawValue == 1, "reorder")
            expect(tree.layer(withID: requireID(1))?.opacity == 200, "opacity")
            expect(
                tree.layer(withID: requireID(1))?.cornerRadius == 8,
                "corner radius update"
            )
            if case .solidColor(let color)? = tree.layer(
                withID: requireID(1)
            )?.content {
                expect(color == .green, "content update")
            } else {
                fatalError("updated solid layer content missing")
            }

            let upsertUpdate = requireApplied(
                tree.upsert(requireLayer(id: 2, zOrder: 10))
            )
            expect(upsertUpdate.kind == .updated, "upsert existing kind")
            expect(tree.count == 3, "upsert existing changed count")

            expectRejection(
                tree.update(requireLayer(id: 99)),
                equals: .identifierNotFound
            )
        }

        withTree(capacity: 2) { tree in
            let insertion = requireApplied(tree.upsert(requireLayer(id: 8)))
            expect(insertion.kind == .inserted, "upsert missing kind")
            expect(tree.count == 1, "upsert missing count")
        }
    }

    private static func removesLayersAndReportsOldDamage() {
        withTree(capacity: 3) { tree in
            _ = tree.insert(requireLayer(id: 1, zOrder: 0))
            _ = tree.insert(
                requireLayer(
                    id: 2,
                    frame: Rectangle(x: 4, y: 6, width: 8, height: 10),
                    zOrder: 1
                )
            )
            _ = tree.insert(requireLayer(id: 3, zOrder: 2))

            let removal = requireApplied(tree.remove(id: requireID(2)))
            expect(removal.kind == .removed, "remove mutation kind")
            expect(removal.oldPainterIndex == 1, "remove painter index")
            expect(removal.newPainterIndex == nil, "remove new painter index")
            expectRectangle(
                removal.damage.oldBounds,
                x: 4,
                y: 6,
                width: 8,
                height: 10,
                "remove old damage"
            )
            expect(removal.damage.newBounds == nil, "remove new damage")
            expect(tree.count == 2, "remove count")
            expect(tree.layer(atPainterIndex: 1)?.id.rawValue == 3, "gap close")
            expectRejection(
                tree.remove(id: requireID(2)),
                equals: .identifierNotFound
            )
        }
    }

    private static func enforcesCallerSuppliedCapacity() {
        withTree(capacity: 2) { tree in
            expect(tree.capacity == 2, "reported capacity")
            _ = tree.insert(requireLayer(id: 1))
            _ = tree.insert(requireLayer(id: 2))
            expectRejection(
                tree.insert(requireLayer(id: 3)),
                equals: .capacityExhausted
            )
            expectRejection(
                tree.insert(requireLayer(id: 1, zOrder: 50)),
                equals: .duplicateIdentifier(existingPainterIndex: 0)
            )
            expect(tree.count == 2, "overflow changed count")
        }

        expect(
            RetainedLayerTree(
                capacity: RetainedLayerTree.maximumLayerCount + 1
            ) == nil,
            "oversized inline capacity accepted"
        )
    }

    private static func copiesInlineStateWithoutAliasing() {
        guard var original = RetainedLayerTree(capacity: 2) else {
            fatalError("inline retained tree fixture rejected")
        }
        _ = original.insert(requireLayer(id: 1))

        var copy = original
        _ = copy.upsert(requireLayer(id: 1, zOrder: 9))
        _ = copy.insert(requireLayer(id: 2))

        expect(original.count == 1, "inline copy changed original count")
        expect(
            original.layer(withID: requireID(1))?.zOrder == 0,
            "inline copy changed original layer"
        )
        expect(copy.count == 2, "inline copy did not retain independent state")
        expect(
            copy.layer(withID: requireID(1))?.zOrder == 9,
            "inline copy update missing"
        )
    }

    private static func preservesClipMetadataAndClipsDamage() {
        withTree(capacity: 1) { tree in
            let clip = Rectangle(x: 30, y: 25, width: 60, height: 20)
            let layer = requireLayer(
                id: 11,
                frame: Rectangle(x: 10, y: 20, width: 50, height: 40),
                clip: clip,
                cornerRadius: 10
            )
            let insertion = requireApplied(tree.insert(layer))
            expectRectangle(
                insertion.damage.newBounds,
                x: 30,
                y: 25,
                width: 30,
                height: 20,
                "clipped insertion damage"
            )
            let retained = tree.layer(withID: requireID(11))
            expectRectangle(
                retained?.clip,
                x: 30,
                y: 25,
                width: 60,
                height: 20,
                "retained clip metadata"
            )
            expect(retained?.cornerRadius == 10, "retained corner radius")
        }
    }

    private static func reflectsVisibilityAndOpacityInDamage() {
        withTree(capacity: 3) { tree in
            let hidden = requireLayer(id: 1, isVisible: false)
            let hiddenInsert = requireApplied(tree.insert(hidden))
            expect(hiddenInsert.damage.newBounds == nil, "hidden insert damage")

            let shown = requireLayer(
                id: 1,
                frame: Rectangle(x: 5, y: 7, width: 9, height: 11)
            )
            let showUpdate = requireApplied(tree.update(shown))
            expect(showUpdate.damage.oldBounds == nil, "hidden old damage")
            expectRectangle(
                showUpdate.damage.newBounds,
                x: 5,
                y: 7,
                width: 9,
                height: 11,
                "visible new damage"
            )

            let transparent = requireLayer(id: 2, opacity: 0)
            let transparentInsert = requireApplied(tree.insert(transparent))
            expect(
                transparentInsert.damage.newBounds == nil,
                "zero-opacity insert damage"
            )

            let clippedAway = requireLayer(
                id: 3,
                frame: Rectangle(x: 0, y: 0, width: 10, height: 10),
                clip: Rectangle(x: 20, y: 20, width: 5, height: 5)
            )
            let clippedInsert = requireApplied(tree.insert(clippedAway))
            expect(
                clippedInsert.damage.newBounds == nil,
                "fully clipped insert damage"
            )
        }
    }

    private static func requireLayer(
        id: UInt64,
        color: PixelColor = .blue,
        frame: Rectangle = Rectangle(x: 0, y: 0, width: 20, height: 20),
        clip: Rectangle? = nil,
        opacity: UInt8 = .max,
        cornerRadius: Int = 0,
        zOrder: Int32 = 0,
        isVisible: Bool = true
    ) -> RetainedLayer {
        guard let layer = RetainedLayer(
            id: requireID(id),
            content: .solidColor(color),
            frame: frame,
            clip: clip,
            opacity: opacity,
            cornerRadius: cornerRadius,
            zOrder: zOrder,
            isVisible: isVisible
        ) else {
            fatalError("valid retained layer fixture rejected")
        }
        return layer
    }

    private static func requireID(_ rawValue: UInt64) -> LayerID {
        guard let id = LayerID(rawValue: rawValue) else {
            fatalError("valid layer ID fixture rejected")
        }
        return id
    }

    private static func withTree(
        capacity: Int,
        _ body: (inout RetainedLayerTree) -> Void
    ) {
        guard var tree = RetainedLayerTree(capacity: capacity) else {
            fatalError("valid inline retained layer capacity rejected")
        }
        body(&tree)
    }

    @discardableResult
    private static func requireApplied(
        _ result: RetainedLayerMutationResult
    ) -> RetainedLayerMutation {
        guard case .applied(let mutation) = result else {
            fatalError("retained layer mutation was rejected")
        }
        return mutation
    }

    private static func expectApplied(
        _ result: RetainedLayerMutationResult,
        kind: RetainedLayerMutationKind
    ) {
        let mutation = requireApplied(result)
        expect(mutation.kind == kind, "unexpected mutation kind")
    }

    private static func expectRejection(
        _ result: RetainedLayerMutationResult,
        equals expected: RetainedLayerMutationRejection
    ) {
        guard case .rejected(let rejection) = result else {
            fatalError("retained layer mutation unexpectedly applied")
        }
        expect(rejection == expected, "unexpected mutation rejection")
    }

    private static func expectRectangle(
        _ rectangle: Rectangle?,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        _ message: StaticString
    ) {
        expect(rectangle?.x == x, message)
        expect(rectangle?.y == y, message)
        expect(rectangle?.width == width, message)
        expect(rectangle?.height == height, message)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("retained layer tree test failed: \(message)")
        }
    }
}
