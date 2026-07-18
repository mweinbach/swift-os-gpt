/// A normalized Q16 fixed-point value used by animation and compositing code.
///
/// The closed interval is represented exactly: `zero.rawValue == 0` and
/// `one.rawValue == 65_536`. Keeping the representation bounded makes curves
/// composable without requiring floating-point support or heap allocation.
struct AnimationProgress: Equatable, Comparable {
    static let fractionalBitCount: UInt32 = 16
    static let unitRawValue: UInt32 = 1 << fractionalBitCount

    static let zero = AnimationProgress(uncheckedRawValue: 0)
    static let one = AnimationProgress(uncheckedRawValue: unitRawValue)

    let rawValue: UInt32

    /// Creates a progress value only when `rawValue` is already normalized.
    init?(rawValue: UInt32) {
        guard rawValue <= Self.unitRawValue else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Creates a progress value by saturating an external fixed-point value.
    init(clampingRawValue rawValue: UInt32) {
        self.rawValue = rawValue > Self.unitRawValue
            ? Self.unitRawValue
            : rawValue
    }

    private init(uncheckedRawValue: UInt32) {
        self.rawValue = uncheckedRawValue
    }

    /// Converts an unsigned fraction to Q16 without multiplying the numerator.
    /// Values at or above the denominator saturate to one. A zero denominator
    /// has no normalized meaning and is rejected.
    static func fraction(
        _ numerator: UInt64,
        of denominator: UInt64
    ) -> AnimationProgress? {
        guard denominator != 0 else {
            return nil
        }
        guard numerator != 0 else {
            return .zero
        }
        guard numerator < denominator else {
            return .one
        }

        // Emit one binary fractional bit at a time. The conditional form of
        // `remainder * 2` avoids overflow even when the denominator is
        // UInt64.max.
        var remainder = numerator
        var result: UInt32 = 0
        for _ in 0..<16 {
            result <<= 1
            let distanceToDenominator = denominator - remainder
            if remainder >= distanceToDenominator {
                remainder -= distanceToDenominator
                result |= 1
            } else {
                remainder += remainder
            }
        }

        return AnimationProgress(uncheckedRawValue: result)
    }

    var inverted: AnimationProgress {
        AnimationProgress(
            uncheckedRawValue: Self.unitRawValue - rawValue
        )
    }

    var isZero: Bool { rawValue == 0 }
    var isComplete: Bool { rawValue == Self.unitRawValue }

    static func < (
        lhs: AnimationProgress,
        rhs: AnimationProgress
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Interpolates across the complete Int64 domain without overflowing a
    /// signed difference or multiplying a 64-bit distance by the Q16 factor.
    /// Intermediate results round toward the starting value.
    func interpolate(from start: Int64, to end: Int64) -> Int64 {
        guard start != end else {
            return start
        }

        let startBits = UInt64(bitPattern: start)
        let endBits = UInt64(bitPattern: end)
        if start < end {
            let distance = endBits &- startBits
            let offset = scaledMagnitude(distance)
            return Int64(bitPattern: startBits &+ offset)
        }

        let distance = startBits &- endBits
        let offset = scaledMagnitude(distance)
        return Int64(bitPattern: startBits &- offset)
    }

    private func scaledMagnitude(_ magnitude: UInt64) -> UInt64 {
        let unit = UInt64(Self.unitRawValue)
        let factor = UInt64(rawValue)
        let wholeUnits = magnitude / unit
        let remainder = magnitude % unit

        // Each term is bounded by magnitude, and their sum is exactly at most
        // magnitude because factor is in the closed normalized interval.
        return wholeUnits * factor + (remainder * factor) / unit
    }
}

/// Deterministic curves whose outputs remain in the normalized Q16 interval.
enum AnimationCurve: Equatable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    func transform(_ progress: AnimationProgress) -> AnimationProgress {
        switch self {
        case .linear:
            return progress
        case .easeIn:
            return Self.multiply(progress, progress)
        case .easeOut:
            let remaining = progress.inverted
            return Self.multiply(remaining, remaining).inverted
        case .easeInOut:
            let half = AnimationProgress.unitRawValue / 2
            if progress.rawValue <= half {
                let squared = Self.multiply(progress, progress)
                return AnimationProgress(
                    clampingRawValue: squared.rawValue * 2
                )
            }

            let remaining = progress.inverted
            let squared = Self.multiply(remaining, remaining)
            return AnimationProgress(
                clampingRawValue:
                    AnimationProgress.unitRawValue - squared.rawValue * 2
            )
        }
    }

    private static func multiply(
        _ lhs: AnimationProgress,
        _ rhs: AnimationProgress
    ) -> AnimationProgress {
        let product = UInt64(lhs.rawValue) * UInt64(rhs.rawValue)
        let scaled = UInt32(
            product / UInt64(AnimationProgress.unitRawValue)
        )
        return AnimationProgress(clampingRawValue: scaled)
    }
}

enum AnimationRepeatMode: Equatable {
    case once
    case loop
    case autoreverse
}

enum AnimationDirection: Equatable {
    case forward
    case reverse
}

/// A complete, allocation-free timeline observation for one counter tick.
struct AnimationSample: Equatable {
    /// Progress after applying the timeline's curve.
    let progress: AnimationProgress
    /// Progress after repeat handling but before applying the curve.
    let linearProgress: AnimationProgress
    /// The zero-based leg. Autoreverse timelines alternate direction per leg.
    let legIndex: UInt64
    let direction: AnimationDirection
    /// True only after a non-repeating timeline reaches its terminal value.
    let isComplete: Bool
}

/// Immutable animation timing state. Callers retain their own start counter and
/// can sample either an elapsed duration or a wrapping hardware counter value.
struct AnimationTimeline: Equatable {
    let durationTicks: UInt64
    let curve: AnimationCurve
    let repeatMode: AnimationRepeatMode

    init?(
        durationTicks: UInt64,
        curve: AnimationCurve = .linear,
        repeatMode: AnimationRepeatMode = .once
    ) {
        guard durationTicks != 0 else {
            return nil
        }
        self.durationTicks = durationTicks
        self.curve = curve
        self.repeatMode = repeatMode
    }

    func sample(elapsedTicks: UInt64) -> AnimationSample {
        let linearProgress: AnimationProgress
        let legIndex: UInt64
        let direction: AnimationDirection
        let isComplete: Bool

        switch repeatMode {
        case .once:
            legIndex = 0
            direction = .forward
            if elapsedTicks >= durationTicks {
                linearProgress = .one
                isComplete = true
            } else {
                linearProgress = AnimationProgress.fraction(
                    elapsedTicks,
                    of: durationTicks
                ) ?? .zero
                isComplete = false
            }
        case .loop:
            legIndex = elapsedTicks / durationTicks
            direction = .forward
            linearProgress = AnimationProgress.fraction(
                elapsedTicks % durationTicks,
                of: durationTicks
            ) ?? .zero
            isComplete = false
        case .autoreverse:
            legIndex = elapsedTicks / durationTicks
            let legProgress = AnimationProgress.fraction(
                elapsedTicks % durationTicks,
                of: durationTicks
            ) ?? .zero
            if legIndex & 1 == 0 {
                direction = .forward
                linearProgress = legProgress
            } else {
                direction = .reverse
                linearProgress = legProgress.inverted
            }
            isComplete = false
        }

        return AnimationSample(
            progress: curve.transform(linearProgress),
            linearProgress: linearProgress,
            legIndex: legIndex,
            direction: direction,
            isComplete: isComplete
        )
    }

    /// Samples a modular UInt64 counter. As with any wrapping counter, callers
    /// must sample before the counter completes an entire unobserved revolution.
    func sample(
        counterTick: UInt64,
        startedAt startTick: UInt64
    ) -> AnimationSample {
        sample(elapsedTicks: counterTick &- startTick)
    }
}

/// The result of advancing a frame pacer to a newly observed counter tick.
struct FramePacerDecision: Equatable {
    /// Cadence boundaries crossed since the preceding observation.
    let framesDue: UInt64
    /// Frames a render-once compositor may skip while catching up.
    let droppedFrames: UInt64
    /// Counter ticks remaining until the next cadence boundary.
    let ticksUntilNextFrame: UInt64

    var shouldPresent: Bool { framesDue != 0 }
}

/// A phase-preserving pacer for a wrapping monotonic counter.
///
/// Late observations report every crossed frame boundary while retaining the
/// sub-frame remainder. A compositor can render once, account for
/// `droppedFrames`, and resume the original cadence without deadline drift.
struct FramePacer {
    let ticksPerFrame: UInt64
    private(set) var lastCounterTick: UInt64
    private(set) var carriedTicks: UInt64

    init?(ticksPerFrame: UInt64, startingAt counterTick: UInt64) {
        guard ticksPerFrame != 0 else {
            return nil
        }
        self.ticksPerFrame = ticksPerFrame
        self.lastCounterTick = counterTick
        self.carriedTicks = 0
    }

    mutating func advance(to counterTick: UInt64) -> FramePacerDecision {
        let elapsed = counterTick &- lastCounterTick
        lastCounterTick = counterTick

        var framesDue = elapsed / ticksPerFrame
        let elapsedRemainder = elapsed % ticksPerFrame

        // Add two values known to be below ticksPerFrame without allowing the
        // addition itself to wrap when ticksPerFrame is near UInt64.max.
        let distanceToBoundary = ticksPerFrame - elapsedRemainder
        if carriedTicks >= distanceToBoundary {
            carriedTicks -= distanceToBoundary
            framesDue += 1
        } else {
            carriedTicks += elapsedRemainder
        }

        return FramePacerDecision(
            framesDue: framesDue,
            droppedFrames: framesDue == 0 ? 0 : framesDue - 1,
            ticksUntilNextFrame: carriedTicks == 0
                ? ticksPerFrame
                : ticksPerFrame - carriedTicks
        )
    }

    mutating func reset(at counterTick: UInt64) {
        lastCounterTick = counterTick
        carriedTicks = 0
    }
}
