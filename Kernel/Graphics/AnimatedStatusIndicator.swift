enum AnimatedStatusFrameResult {
    case idle
    case rendered(damage: DamageRegion, droppedFrames: UInt64)
    case failed
}

/// A first live retained-mode component used to prove the modern renderer
/// stack end to end. It intentionally owns no board logic: the monitor supplies
/// counter ticks, the canvas supplies pixels, and the display backend presents
/// the returned damage.
struct AnimatedStatusIndicator {
    static let frame = Rectangle(x: 774, y: 11, width: 12, height: 12)
    static let backgroundColor = PixelColor.chrome
    static let indicatorColor = PixelColor.green
    static let minimumOpacity: Int64 = 72
    static let maximumOpacity: Int64 = 255
    static let peakMarkerOpacity: UInt8 = 250
    static let targetFramesPerSecond: UInt64 = 30

    private let logicalBounds: Rectangle
    private let indicatorID: LayerID
    private let timeline: AnimationTimeline
    private let startedAt: UInt64
    private var pacer: FramePacer
    private var tree: RetainedLayerTree

    private(set) var renderedFrameCount: UInt64 = 0
    private(set) var droppedFrameCount: UInt64 = 0
    private(set) var currentOpacity = UInt8(minimumOpacity)

    init?(
        logicalBounds: Rectangle,
        counterFrequency: UInt64,
        startingAt counterTick: UInt64
    ) {
        guard Self.contains(logicalBounds, Self.frame),
              counterFrequency >= Self.targetFramesPerSecond,
              let indicatorID = LayerID(rawValue: 1),
              let timeline = AnimationTimeline(
                  durationTicks: counterFrequency / 2,
                  curve: .easeInOut,
                  repeatMode: .autoreverse
              ),
              let pacer = FramePacer(
                  ticksPerFrame:
                      counterFrequency / Self.targetFramesPerSecond,
                  startingAt: counterTick
              ),
              var tree = RetainedLayerTree(capacity: 1),
              let initialLayer = Self.makeLayer(
                  id: indicatorID,
                  opacity: UInt8(Self.minimumOpacity)
              )
        else {
            return nil
        }
        guard case .applied = tree.insert(initialLayer) else { return nil }

        self.logicalBounds = logicalBounds
        self.indicatorID = indicatorID
        self.timeline = timeline
        self.startedAt = counterTick
        self.pacer = pacer
        self.tree = tree
    }

    /// Draws the retained component's initial state before the first full
    /// scanout presentation.
    mutating func renderInitial(on canvas: ScaledFramebufferCanvas) -> Bool {
        guard var damage = DamageRegion(logicalBounds: logicalBounds) else {
            return false
        }
        damage.add(Self.frame)
        return SoftwareLayerCompositor.render(
            tree: tree,
            damage: damage,
            backgroundColor: Self.backgroundColor,
            on: canvas
        )
    }

    mutating func renderIfDue(
        counterTick: UInt64,
        on canvas: ScaledFramebufferCanvas
    ) -> AnimatedStatusFrameResult {
        let decision = pacer.advance(to: counterTick)
        guard decision.shouldPresent else { return .idle }

        let sample = timeline.sample(
            counterTick: counterTick,
            startedAt: startedAt
        )
        let interpolated = sample.progress.interpolate(
            from: Self.minimumOpacity,
            to: Self.maximumOpacity
        )
        guard interpolated >= 0,
              interpolated <= Int64(UInt8.max),
              let layer = Self.makeLayer(
                  id: indicatorID,
                  opacity: UInt8(interpolated)
              ),
              var damage = DamageRegion(logicalBounds: logicalBounds)
        else {
            return .failed
        }
        let mutation = tree.update(layer)
        guard SoftwareLayerCompositor.recordDamage(
                  from: mutation,
                  in: &damage
              ),
              !damage.isEmpty,
              SoftwareLayerCompositor.render(
                  tree: tree,
                  damage: damage,
                  backgroundColor: Self.backgroundColor,
                  on: canvas
              )
        else {
            return .failed
        }

        currentOpacity = UInt8(interpolated)
        renderedFrameCount &+= 1
        droppedFrameCount &+= decision.droppedFrames
        return .rendered(
            damage: damage,
            droppedFrames: decision.droppedFrames
        )
    }

    private static func makeLayer(
        id: LayerID,
        opacity: UInt8
    ) -> RetainedLayer? {
        RetainedLayer(
            id: id,
            content: .solidColor(Self.indicatorColor),
            frame: Self.frame,
            opacity: opacity,
            cornerRadius: Self.frame.width / 2,
            zOrder: 0,
            isVisible: true
        )
    }

    private static func contains(
        _ outer: Rectangle,
        _ inner: Rectangle
    ) -> Bool {
        guard outer.width > 0,
              outer.height > 0,
              inner.width > 0,
              inner.height > 0
        else {
            return false
        }
        let outerEndX = outer.x.addingReportingOverflow(outer.width)
        let outerEndY = outer.y.addingReportingOverflow(outer.height)
        let innerEndX = inner.x.addingReportingOverflow(inner.width)
        let innerEndY = inner.y.addingReportingOverflow(inner.height)
        guard !outerEndX.overflow,
              !outerEndY.overflow,
              !innerEndX.overflow,
              !innerEndY.overflow
        else {
            return false
        }
        return inner.x >= outer.x
            && inner.y >= outer.y
            && innerEndX.partialValue <= outerEndX.partialValue
            && innerEndY.partialValue <= outerEndY.partialValue
    }
}
