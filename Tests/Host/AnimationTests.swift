@main
struct AnimationTests {
    static func main() {
        testProgressConstructionAndFractions()
        testCurveEndpointsAndShape()
        testCurveMonotonicity()
        testScalarInterpolation()
        testOnceAndLoopTimelines()
        testAutoreverseAndCounterWrapping()
        testFramePacingAndCatchUp()
        testFramePacingWrapAndExtremeIntervals()
        print("animation host tests: 8 groups passed")
    }

    private static func testProgressConstructionAndFractions() {
        expect(
            AnimationProgress(rawValue: 0) == .zero,
            "zero raw progress"
        )
        expect(
            AnimationProgress(
                rawValue: AnimationProgress.unitRawValue
            ) == .one,
            "one raw progress"
        )
        expect(
            AnimationProgress(
                rawValue: AnimationProgress.unitRawValue + 1
            ) == nil,
            "out-of-range raw progress accepted"
        )
        expect(
            AnimationProgress(clampingRawValue: UInt32.max) == .one,
            "raw progress did not saturate"
        )
        expect(
            AnimationProgress.fraction(1, of: 0) == nil,
            "zero fraction denominator accepted"
        )
        expect(
            AnimationProgress.fraction(0, of: UInt64.max) == .zero,
            "zero fraction"
        )
        expect(
            AnimationProgress.fraction(UInt64.max, of: UInt64.max) == .one,
            "maximum exact fraction"
        )
        expect(
            AnimationProgress.fraction(UInt64.max, of: 1) == .one,
            "oversized fraction did not saturate"
        )
        expect(
            AnimationProgress.fraction(1, of: 2)?.rawValue
                == AnimationProgress.unitRawValue / 2,
            "half fraction"
        )
        expect(
            AnimationProgress.fraction(
                UInt64.max / 2,
                of: UInt64.max
            )?.rawValue == AnimationProgress.unitRawValue / 2 - 1,
            "maximum-width fraction conversion overflowed"
        )
        expect(AnimationProgress.zero.inverted == .one, "zero inversion")
        expect(AnimationProgress.one.inverted == .zero, "one inversion")
    }

    private static func testCurveEndpointsAndShape() {
        let curves: [AnimationCurve] = [
            .linear,
            .easeIn,
            .easeOut,
            .easeInOut,
        ]
        for curve in curves {
            expect(curve.transform(.zero) == .zero, "curve zero endpoint")
            expect(curve.transform(.one) == .one, "curve one endpoint")
        }

        let quarter = requireProgress(
            rawValue: AnimationProgress.unitRawValue / 4
        )
        let half = requireProgress(
            rawValue: AnimationProgress.unitRawValue / 2
        )
        let threeQuarters = requireProgress(
            rawValue: AnimationProgress.unitRawValue * 3 / 4
        )
        expect(
            AnimationCurve.linear.transform(quarter) == quarter,
            "linear curve changed progress"
        )
        expect(
            AnimationCurve.easeIn.transform(quarter) < quarter,
            "ease-in shape"
        )
        expect(
            AnimationCurve.easeOut.transform(quarter) > quarter,
            "ease-out shape"
        )
        expect(
            AnimationCurve.easeInOut.transform(half) == half,
            "ease-in-out midpoint"
        )
        expect(
            AnimationCurve.easeInOut.transform(quarter).inverted
                == AnimationCurve.easeInOut.transform(threeQuarters),
            "ease-in-out symmetry"
        )
    }

    private static func testCurveMonotonicity() {
        let curves: [AnimationCurve] = [
            .linear,
            .easeIn,
            .easeOut,
            .easeInOut,
        ]
        for curve in curves {
            var previous = AnimationProgress.zero
            var rawValue: UInt32 = 0
            while rawValue <= AnimationProgress.unitRawValue {
                let input = requireProgress(rawValue: rawValue)
                let output = curve.transform(input)
                expect(output >= previous, "curve was not monotonic")
                expect(
                    output.rawValue <= AnimationProgress.unitRawValue,
                    "curve escaped normalized range"
                )
                previous = output
                rawValue += 1
            }
        }
    }

    private static func testScalarInterpolation() {
        let quarter = requireProgress(
            rawValue: AnimationProgress.unitRawValue / 4
        )
        let half = requireProgress(
            rawValue: AnimationProgress.unitRawValue / 2
        )
        expect(
            AnimationProgress.zero.interpolate(from: -90, to: 110) == -90,
            "interpolation zero endpoint"
        )
        expect(
            AnimationProgress.one.interpolate(from: -90, to: 110) == 110,
            "interpolation one endpoint"
        )
        expect(
            quarter.interpolate(from: -100, to: 100) == -50,
            "ascending interpolation"
        )
        expect(
            quarter.interpolate(from: 100, to: -100) == 50,
            "descending interpolation"
        )
        expect(
            half.interpolate(from: Int64.min, to: Int64.max) == -1,
            "full-domain ascending midpoint"
        )
        expect(
            half.interpolate(from: Int64.max, to: Int64.min) == 0,
            "full-domain descending midpoint"
        )
        expect(
            AnimationProgress.zero.interpolate(
                from: Int64.min,
                to: Int64.max
            ) == Int64.min,
            "full-domain zero endpoint"
        )
        expect(
            AnimationProgress.one.interpolate(
                from: Int64.min,
                to: Int64.max
            ) == Int64.max,
            "full-domain one endpoint"
        )
        expect(
            half.interpolate(from: Int64.min, to: Int64.min) == Int64.min,
            "identical extreme interpolation"
        )

        var previous = Int64.min
        var rawValue: UInt32 = 0
        while rawValue <= AnimationProgress.unitRawValue {
            let value = requireProgress(rawValue: rawValue).interpolate(
                from: Int64.min,
                to: Int64.max
            )
            expect(value >= previous, "extreme interpolation was not monotonic")
            previous = value
            rawValue += 257
        }
        expect(
            AnimationProgress.one.interpolate(
                from: Int64.min,
                to: Int64.max
            ) >= previous,
            "extreme interpolation final ordering"
        )
    }

    private static func testOnceAndLoopTimelines() {
        expect(
            AnimationTimeline(durationTicks: 0) == nil,
            "zero-duration timeline accepted"
        )
        let once = requireTimeline(
            durationTicks: 100,
            curve: .linear,
            repeatMode: .once
        )
        expect(once.sample(elapsedTicks: 0).progress == .zero, "once start")
        let halfway = once.sample(elapsedTicks: 50)
        expect(
            halfway.progress.rawValue == AnimationProgress.unitRawValue / 2,
            "once midpoint"
        )
        expect(!halfway.isComplete, "once completed early")
        expect(once.sample(elapsedTicks: 99).progress < .one, "once early end")
        let terminal = once.sample(elapsedTicks: 100)
        expect(terminal.progress == .one, "once endpoint")
        expect(terminal.isComplete, "once completion flag")
        expect(
            once.sample(elapsedTicks: UInt64.max).progress == .one,
            "once maximum elapsed clamp"
        )

        let loop = requireTimeline(
            durationTicks: 10,
            curve: .linear,
            repeatMode: .loop
        )
        expect(loop.sample(elapsedTicks: 9).progress < .one, "loop pre-wrap")
        let wrapped = loop.sample(elapsedTicks: 10)
        expect(wrapped.progress == .zero, "loop boundary")
        expect(wrapped.legIndex == 1, "loop leg index")
        expect(!wrapped.isComplete, "loop reported completion")
        expect(
            loop.sample(elapsedTicks: UInt64.max).legIndex
                == UInt64.max / 10,
            "loop maximum elapsed leg"
        )
    }

    private static func testAutoreverseAndCounterWrapping() {
        let timeline = requireTimeline(
            durationTicks: 10,
            curve: .linear,
            repeatMode: .autoreverse
        )
        expect(timeline.sample(elapsedTicks: 0).progress == .zero, "auto start")
        let forward = timeline.sample(elapsedTicks: 5)
        expect(forward.direction == .forward, "auto forward direction")
        expect(
            forward.progress.rawValue == AnimationProgress.unitRawValue / 2,
            "auto forward midpoint"
        )
        let reverseStart = timeline.sample(elapsedTicks: 10)
        expect(reverseStart.progress == .one, "auto reverse endpoint")
        expect(reverseStart.direction == .reverse, "auto reverse direction")
        expect(reverseStart.legIndex == 1, "auto reverse leg")
        expect(
            timeline.sample(elapsedTicks: 15).progress.rawValue
                == AnimationProgress.unitRawValue / 2,
            "auto reverse midpoint"
        )
        expect(
            timeline.sample(elapsedTicks: 20).progress == .zero,
            "auto full-cycle endpoint"
        )
        let maximum = requireTimeline(
            durationTicks: 1,
            curve: .linear,
            repeatMode: .autoreverse
        ).sample(elapsedTicks: UInt64.max)
        expect(maximum.legIndex == UInt64.max, "auto maximum leg")
        expect(maximum.direction == .reverse, "auto maximum direction")
        expect(maximum.progress == .one, "auto maximum progress")

        let wrappingOnce = requireTimeline(
            durationTicks: 10,
            curve: .easeInOut,
            repeatMode: .once
        )
        let start = UInt64.max - 4
        expect(
            wrappingOnce.sample(counterTick: 5, startedAt: start).isComplete,
            "timeline counter wrap"
        )
    }

    private static func testFramePacingAndCatchUp() {
        expect(
            FramePacer(ticksPerFrame: 0, startingAt: 0) == nil,
            "zero frame interval accepted"
        )
        var pacer = requirePacer(ticksPerFrame: 10, startingAt: 100)
        let idle = pacer.advance(to: 100)
        expect(!idle.shouldPresent, "same-tick frame due")
        expect(idle.framesDue == 0, "same-tick frame count")
        expect(idle.ticksUntilNextFrame == 10, "same-tick deadline")

        let partial = pacer.advance(to: 106)
        expect(!partial.shouldPresent, "partial frame due")
        expect(partial.ticksUntilNextFrame == 4, "partial frame remainder")
        let due = pacer.advance(to: 110)
        expect(due.shouldPresent, "frame boundary not due")
        expect(due.framesDue == 1, "frame boundary count")
        expect(due.droppedFrames == 0, "on-time frame dropped")
        expect(due.ticksUntilNextFrame == 10, "on-time next deadline")

        let late = pacer.advance(to: 145)
        expect(late.framesDue == 3, "late frame count")
        expect(late.droppedFrames == 2, "late dropped frame count")
        expect(late.ticksUntilNextFrame == 5, "late phase preservation")
        let caughtUp = pacer.advance(to: 150)
        expect(caughtUp.framesDue == 1, "catch-up boundary")
        expect(caughtUp.ticksUntilNextFrame == 10, "catch-up cadence")

        pacer.reset(at: 500)
        expect(pacer.lastCounterTick == 500, "pacer reset tick")
        expect(pacer.carriedTicks == 0, "pacer reset phase")
        expect(!pacer.advance(to: 509).shouldPresent, "pacer reset deadline")
    }

    private static func testFramePacingWrapAndExtremeIntervals() {
        var wrapping = requirePacer(
            ticksPerFrame: 4,
            startingAt: UInt64.max - 2
        )
        let wrapped = wrapping.advance(to: 2)
        expect(wrapped.framesDue == 1, "pacer wrap frame count")
        expect(wrapped.droppedFrames == 0, "pacer wrap dropped count")
        expect(wrapped.ticksUntilNextFrame == 3, "pacer wrap remainder")

        var unit = requirePacer(
            ticksPerFrame: 1,
            startingAt: UInt64.max
        )
        let unitWrapped = unit.advance(to: 0)
        expect(unitWrapped.framesDue == 1, "unit interval wrap")
        expect(unitWrapped.ticksUntilNextFrame == 1, "unit interval next")

        var extreme = requirePacer(
            ticksPerFrame: UInt64.max,
            startingAt: 0
        )
        let almost = extreme.advance(to: UInt64.max - 1)
        expect(almost.framesDue == 0, "extreme interval early frame")
        expect(almost.ticksUntilNextFrame == 1, "extreme interval remainder")
        let boundary = extreme.advance(to: UInt64.max)
        expect(boundary.framesDue == 1, "extreme interval boundary")
        expect(boundary.ticksUntilNextFrame == UInt64.max, "extreme next")

        var late = requirePacer(ticksPerFrame: 2, startingAt: 0)
        let maximumLate = late.advance(to: UInt64.max)
        expect(
            maximumLate.framesDue == UInt64.max / 2,
            "maximum late frame quotient"
        )
        expect(
            maximumLate.ticksUntilNextFrame == 1,
            "maximum late frame remainder"
        )
    }

    private static func requireProgress(rawValue: UInt32) -> AnimationProgress {
        guard let progress = AnimationProgress(rawValue: rawValue) else {
            fatalError("valid animation progress fixture rejected")
        }
        return progress
    }

    private static func requireTimeline(
        durationTicks: UInt64,
        curve: AnimationCurve,
        repeatMode: AnimationRepeatMode
    ) -> AnimationTimeline {
        guard let timeline = AnimationTimeline(
            durationTicks: durationTicks,
            curve: curve,
            repeatMode: repeatMode
        ) else {
            fatalError("valid animation timeline fixture rejected")
        }
        return timeline
    }

    private static func requirePacer(
        ticksPerFrame: UInt64,
        startingAt counterTick: UInt64
    ) -> FramePacer {
        guard let pacer = FramePacer(
            ticksPerFrame: ticksPerFrame,
            startingAt: counterTick
        ) else {
            fatalError("valid frame pacer fixture rejected")
        }
        return pacer
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("animation test failed: \(message)")
        }
    }
}
