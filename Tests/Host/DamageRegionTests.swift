@main
struct DamageRegionTests {
    static func main() {
        testInitializationAndEmptyDamage()
        testClippingAndNegativeCoordinates()
        testNormalizationAndIntegerOverflow()
        testOverlapAndTouchMerging()
        testTransitiveMerging()
        testCapacityFallback()
        testDeterministicAccessAndIteration()
        testFullDamageClearAndBoundingRectangle()
        print("damage region host tests: 8 groups passed")
    }

    private static func testInitializationAndEmptyDamage() {
        expect(
            DamageRegion(
                logicalBounds: Rectangle(x: 0, y: 0, width: 0, height: 10)
            ) == nil,
            "zero-width bounds accepted"
        )
        expect(
            DamageRegion(
                logicalBounds: Rectangle(
                    x: Int.max - 5,
                    y: 0,
                    width: 10,
                    height: 10
                )
            ) == nil,
            "overflowing bounds accepted"
        )
        expect(
            DamageRegion(
                logicalBounds: bounds(),
                capacity: DamageRegion.maximumRectangleCount + 1
            ) == nil,
            "oversized capacity accepted"
        )
        expect(
            DamageRegion(logicalBounds: bounds(), capacity: 0) == nil,
            "zero capacity accepted"
        )

        var region = requireRegion()
        region.add(Rectangle(x: 10, y: 10, width: 0, height: 5))
        region.add(Rectangle(x: 10, y: 10, width: 5, height: 0))
        region.add(Rectangle(x: -50, y: -50, width: 10, height: 10))
        region.add(Rectangle(x: 800, y: 0, width: 10, height: 10))
        expect(region.isEmpty, "empty or out-of-bounds damage was recorded")
        expect(region.count == 0, "empty damage count")
        expect(region.rectangle(at: 0) == nil, "empty access succeeded")
        expect(region[-1] == nil, "negative access succeeded")
        expect(region.boundingRectangle == nil, "empty bounding rectangle")
    }

    private static func testClippingAndNegativeCoordinates() {
        var region = requireRegion()
        region.add(Rectangle(x: -20, y: 590, width: 50, height: 40))
        expectRectangle(
            region[0],
            x: 0,
            y: 590,
            width: 30,
            height: 10,
            "negative-origin clipping"
        )

        region.clear()
        region.add(Rectangle(x: 790, y: -10, width: 30, height: 30))
        expectRectangle(
            region[0],
            x: 790,
            y: 0,
            width: 10,
            height: 20,
            "far-edge clipping"
        )
    }

    private static func testNormalizationAndIntegerOverflow() {
        var region = requireRegion()
        region.add(Rectangle(x: 20, y: 30, width: -10, height: -20))
        expectRectangle(
            region[0],
            x: 10,
            y: 10,
            width: 10,
            height: 20,
            "negative extent normalization"
        )

        region.clear()
        region.add(
            Rectangle(x: -10, y: 590, width: Int.max, height: Int.max)
        )
        expectRectangle(
            region[0],
            x: 0,
            y: 590,
            width: 800,
            height: 10,
            "positive endpoint overflow clipping"
        )

        region.clear()
        region.add(Rectangle(x: 20, y: 30, width: Int.min, height: Int.min))
        expectRectangle(
            region[0],
            x: 0,
            y: 0,
            width: 20,
            height: 30,
            "negative endpoint overflow clipping"
        )

        region.clear()
        region.add(
            Rectangle(
                x: Int.min + 2,
                y: Int.min + 2,
                width: -100,
                height: -100
            )
        )
        expect(region.isEmpty, "underflowing offscreen rectangle was recorded")

        region.clear()
        region.add(
            Rectangle(
                x: Int.max - 2,
                y: Int.max - 2,
                width: 100,
                height: 100
            )
        )
        expect(region.isEmpty, "overflowing offscreen rectangle was recorded")
    }

    private static func testOverlapAndTouchMerging() {
        var region = requireRegion()
        region.add(Rectangle(x: 10, y: 10, width: 20, height: 20))
        region.add(Rectangle(x: 20, y: 20, width: 20, height: 10))
        expect(region.count == 1, "overlap was not merged")
        expectRectangle(
            region[0],
            x: 10,
            y: 10,
            width: 30,
            height: 20,
            "overlap union"
        )

        region.add(Rectangle(x: 40, y: 15, width: 5, height: 5))
        expect(region.count == 1, "edge-touching rectangle was not merged")
        expectRectangle(
            region[0],
            x: 10,
            y: 10,
            width: 35,
            height: 20,
            "edge-touching union"
        )

        region.add(Rectangle(x: 45, y: 30, width: 5, height: 5))
        expect(region.count == 1, "corner-touching rectangle was not merged")
        expectRectangle(
            region[0],
            x: 10,
            y: 10,
            width: 40,
            height: 25,
            "corner-touching union"
        )
    }

    private static func testTransitiveMerging() {
        var region = requireRegion()
        region.add(Rectangle(x: 0, y: 0, width: 10, height: 10))
        region.add(Rectangle(x: 30, y: 0, width: 10, height: 10))
        region.add(Rectangle(x: 10, y: 0, width: 20, height: 10))
        expect(region.count == 1, "transitive horizontal merge failed")
        expectRectangle(
            region[0],
            x: 0,
            y: 0,
            width: 40,
            height: 10,
            "transitive horizontal union"
        )

        region.clear()
        // The last union expands toward a rectangle checked earlier, requiring
        // the merge scan to restart to find the newly touching rectangle.
        region.add(Rectangle(x: 0, y: 0, width: 10, height: 10))
        region.add(Rectangle(x: 20, y: 0, width: 10, height: 20))
        region.add(Rectangle(x: 0, y: 20, width: 20, height: 10))
        expect(region.count == 1, "expanding transitive merge failed")
        expectRectangle(
            region[0],
            x: 0,
            y: 0,
            width: 30,
            height: 30,
            "expanding transitive union"
        )
    }

    private static func testCapacityFallback() {
        var region = requireRegion(capacity: 2)
        region.add(Rectangle(x: 10, y: 10, width: 5, height: 5))
        region.add(Rectangle(x: 30, y: 30, width: 5, height: 5))
        expect(region.count == 2, "capacity fixture did not fill")
        region.add(Rectangle(x: 50, y: 50, width: 5, height: 5))
        expect(region.isFullDamage, "capacity exhaustion did not collapse")
        expect(region.count == 1, "collapsed region count")
        expectRectangle(
            region[0],
            x: 0,
            y: 0,
            width: 800,
            height: 600,
            "capacity fallback bounds"
        )

        // Once full, further arbitrary or overflowing input cannot narrow it.
        region.add(Rectangle(x: Int.min, y: Int.min, width: 1, height: 1))
        expect(region.isFullDamage && region.count == 1, "full damage narrowed")
    }

    private static func testDeterministicAccessAndIteration() {
        var first = requireRegion()
        first.add(Rectangle(x: 300, y: 200, width: 10, height: 10))
        first.add(Rectangle(x: 50, y: 100, width: 10, height: 10))
        first.add(Rectangle(x: 200, y: 100, width: 10, height: 10))

        var second = requireRegion()
        second.add(Rectangle(x: 200, y: 100, width: 10, height: 10))
        second.add(Rectangle(x: 300, y: 200, width: 10, height: 10))
        second.add(Rectangle(x: 50, y: 100, width: 10, height: 10))

        expect(first.count == 3 && second.count == 3, "ordering fixture count")
        var index = 0
        while index < first.count {
            expectSameRectangle(
                first[index],
                second[index],
                "insertion-order-independent access"
            )
            index += 1
        }
        expectRectangle(
            first[0],
            x: 50,
            y: 100,
            width: 10,
            height: 10,
            "row-major first rectangle"
        )
        expectRectangle(
            first[1],
            x: 200,
            y: 100,
            width: 10,
            height: 10,
            "row-major second rectangle"
        )
        expect(first[first.count] == nil, "past-end access succeeded")

        var visitedCount = 0
        var previousY = Int.min
        var previousX = Int.min
        first.forEachRectangle { rectangle in
            expect(
                rectangle.y > previousY
                    || (rectangle.y == previousY && rectangle.x > previousX),
                "iteration order"
            )
            previousY = rectangle.y
            previousX = rectangle.x
            visitedCount += 1
        }
        expect(visitedCount == first.count, "iteration count")
    }

    private static func testFullDamageClearAndBoundingRectangle() {
        var region = requireRegion()
        region.add(Rectangle(x: 20, y: 30, width: 10, height: 10))
        region.add(Rectangle(x: 100, y: 120, width: 20, height: 30))
        expectRectangle(
            region.boundingRectangle,
            x: 20,
            y: 30,
            width: 100,
            height: 120,
            "conservative bounding rectangle"
        )

        region.addFullDamage()
        expect(region.isFullDamage, "explicit full damage missing")
        expectRectangle(
            region.boundingRectangle,
            x: 0,
            y: 0,
            width: 800,
            height: 600,
            "explicit full bounding rectangle"
        )

        region.clear()
        expect(region.isEmpty, "clear did not empty region")
        expect(!region.isFullDamage, "clear retained full-damage state")
        region.add(Rectangle(x: 1, y: 2, width: 3, height: 4))
        expectRectangle(
            region[0],
            x: 1,
            y: 2,
            width: 3,
            height: 4,
            "reuse after clear"
        )
    }

    private static func bounds() -> Rectangle {
        Rectangle(x: 0, y: 0, width: 800, height: 600)
    }

    private static func requireRegion(capacity: Int = 8) -> DamageRegion {
        guard let region = DamageRegion(
                  logicalBounds: bounds(),
                  capacity: capacity
              )
        else {
            fatalError("valid damage region rejected")
        }
        return region
    }

    private static func expectRectangle(
        _ rectangle: Rectangle?,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        _ message: String
    ) {
        guard let rectangle else {
            fatalError(message)
        }
        expect(
            rectangle.x == x && rectangle.y == y
                && rectangle.width == width && rectangle.height == height,
            message
        )
    }

    private static func expectSameRectangle(
        _ left: Rectangle?,
        _ right: Rectangle?,
        _ message: String
    ) {
        guard let left, let right else {
            fatalError(message)
        }
        expect(
            left.x == right.x && left.y == right.y
                && left.width == right.width && left.height == right.height,
            message
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fatalError(message)
        }
    }
}
