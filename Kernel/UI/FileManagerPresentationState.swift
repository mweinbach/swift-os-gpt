enum FileManagerHitRegion: Equatable {
    case titleBar
    case closeButton
    case sidebarSystem
    case sidebarUser
    case listRow(Int)
    case listBackground
    case resizeLeft
    case resizeRight
    case resizeTop
    case resizeBottom
}

/// Validated logical geometry shared by file-manager interaction and GPU scene
/// compilation. Every hit test uses half-open rectangles, matching rendering.
struct FileManagerLayout {
    static let minimumWindowWidth = 420
    static let minimumWindowHeight = 300
    static let titleBarHeight = 44
    static let listRowHeight = 34
    static let resizeEdgeThickness = 6

    let desktopBounds: Rectangle
    let windowFrame: Rectangle
    let shadowFrame: Rectangle
    let titleBarFrame: Rectangle
    let closeButtonFrame: Rectangle
    let sidebarFrame: Rectangle
    let listFrame: Rectangle
    let rowCapacity: Int

    init?(desktopBounds: Rectangle, windowFrame: Rectangle) {
        guard Self.isValid(desktopBounds),
              Self.isValid(windowFrame),
              windowFrame.width >= Self.minimumWindowWidth,
              windowFrame.height >= Self.minimumWindowHeight,
              windowFrame.x <= Int.max - 8,
              windowFrame.y <= Int.max - 10,
              Self.contains(desktopBounds, windowFrame)
        else {
            return nil
        }
        let sidebarWidth = Self.clamp(
            windowFrame.width / 4,
            minimum: 128,
            maximum: 192
        )
        let contentHeight = windowFrame.height - Self.titleBarHeight
        let listWidth = windowFrame.width - sidebarWidth
        guard contentHeight > 0, listWidth > 0 else { return nil }

        self.desktopBounds = desktopBounds
        self.windowFrame = windowFrame
        shadowFrame = Rectangle(
            x: windowFrame.x + 8,
            y: windowFrame.y + 10,
            width: windowFrame.width,
            height: windowFrame.height
        )
        titleBarFrame = Rectangle(
            x: windowFrame.x,
            y: windowFrame.y,
            width: windowFrame.width,
            height: Self.titleBarHeight
        )
        closeButtonFrame = Rectangle(
            x: windowFrame.x + 16,
            y: windowFrame.y + 14,
            width: 16,
            height: 16
        )
        sidebarFrame = Rectangle(
            x: windowFrame.x,
            y: windowFrame.y + Self.titleBarHeight,
            width: sidebarWidth,
            height: contentHeight
        )
        listFrame = Rectangle(
            x: windowFrame.x + sidebarWidth,
            y: windowFrame.y + Self.titleBarHeight,
            width: listWidth,
            height: contentHeight
        )
        rowCapacity = contentHeight / Self.listRowHeight
        guard rowCapacity > 0 else { return nil }
    }

    func sidebarItemFrame(at index: Int) -> Rectangle? {
        guard index >= 0, index < 2 else { return nil }
        return Rectangle(
            x: sidebarFrame.x + 10,
            y: sidebarFrame.y + 12 + index * 40,
            width: sidebarFrame.width - 20,
            height: 34
        )
    }

    func listRowFrame(at row: Int) -> Rectangle? {
        guard row >= 0, row < rowCapacity else { return nil }
        return Rectangle(
            x: listFrame.x + 8,
            y: listFrame.y + row * Self.listRowHeight,
            width: listFrame.width - 16,
            height: Self.listRowHeight
        )
    }

    func hitTest(_ point: Point) -> FileManagerHitRegion? {
        guard Self.contains(windowFrame, point) else { return nil }
        let localX = point.x - windowFrame.x
        let localY = point.y - windowFrame.y
        if localX < Self.resizeEdgeThickness { return .resizeLeft }
        if localX >= windowFrame.width - Self.resizeEdgeThickness {
            return .resizeRight
        }
        if localY < Self.resizeEdgeThickness { return .resizeTop }
        if localY >= windowFrame.height - Self.resizeEdgeThickness {
            return .resizeBottom
        }
        if Self.contains(closeButtonFrame, point) { return .closeButton }
        if Self.contains(titleBarFrame, point) { return .titleBar }
        if let system = sidebarItemFrame(at: 0),
           Self.contains(system, point) {
            return .sidebarSystem
        }
        if let user = sidebarItemFrame(at: 1), Self.contains(user, point) {
            return .sidebarUser
        }
        if Self.contains(listFrame, point) {
            let row = (point.y - listFrame.y) / Self.listRowHeight
            return row < rowCapacity ? .listRow(row) : .listBackground
        }
        return .listBackground
    }

    func controlID(for region: FileManagerHitRegion) -> UIControlID {
        let rawValue: UInt32
        switch region {
        case .titleBar: rawValue = 1
        case .closeButton: rawValue = 2
        case .sidebarSystem: rawValue = 10
        case .sidebarUser: rawValue = 11
        case .listBackground: rawValue = 20
        case .resizeLeft: rawValue = 30
        case .resizeRight: rawValue = 31
        case .resizeTop: rawValue = 32
        case .resizeBottom: rawValue = 33
        case .listRow(let row):
            rawValue = row >= 0 && row <= Int(UInt32.max - 1_000)
                ? 1_000 + UInt32(row)
                : UInt32.max
        }
        return UIControlID(rawValue: rawValue)!
    }

    func cursorShape(for region: FileManagerHitRegion?) -> UICursorShape {
        switch region {
        case .resizeLeft, .resizeRight:
            return .resizeHorizontal
        case .resizeTop, .resizeBottom:
            return .resizeVertical
        case .sidebarSystem, .sidebarUser, .closeButton, .listRow:
            return .pointingHand
        case .titleBar, .listBackground, nil:
            return .arrow
        }
    }

    private static func isValid(_ rectangle: Rectangle) -> Bool {
        guard rectangle.width > 0, rectangle.height > 0 else { return false }
        return !rectangle.x.addingReportingOverflow(rectangle.width).overflow
            && !rectangle.y.addingReportingOverflow(rectangle.height).overflow
    }

    private static func contains(_ outer: Rectangle, _ inner: Rectangle) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width
            && inner.y + inner.height <= outer.y + outer.height
    }

    private static func contains(_ rectangle: Rectangle, _ point: Point) -> Bool {
        point.x >= rectangle.x && point.x < rectangle.x + rectangle.width
            && point.y >= rectangle.y && point.y < rectangle.y + rectangle.height
    }

    private static func clamp(
        _ value: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        value < minimum ? minimum : (value > maximum ? maximum : value)
    }
}

/// A retargetable normalized channel. Changing direction samples the current
/// value first, so hover/focus animations never jump when input reverses.
struct DeterministicUIAnimationChannel {
    let durationTicks: UInt64
    let curve: AnimationCurve
    private(set) var startValue: AnimationProgress
    private(set) var targetValue: AnimationProgress
    private(set) var startedAt: UInt64

    init?(
        durationTicks: UInt64,
        initialValue: AnimationProgress,
        curve: AnimationCurve = .easeOut,
        startingAt: UInt64
    ) {
        guard durationTicks != 0 else { return nil }
        self.durationTicks = durationTicks
        self.curve = curve
        startValue = initialValue
        targetValue = initialValue
        startedAt = startingAt
    }

    mutating func setTarget(
        _ target: AnimationProgress,
        at counterTick: UInt64
    ) {
        let current = sample(at: counterTick)
        startValue = current
        targetValue = target
        startedAt = counterTick
    }

    func sample(at counterTick: UInt64) -> AnimationProgress {
        guard startValue != targetValue else { return targetValue }
        let elapsed = counterTick &- startedAt
        let linear = AnimationProgress.fraction(elapsed, of: durationTicks)
            ?? .one
        let curved = curve.transform(linear)
        let raw = curved.interpolate(
            from: Int64(startValue.rawValue),
            to: Int64(targetValue.rawValue)
        )
        return AnimationProgress(clampingRawValue: UInt32(raw))
    }
}

struct FileManagerAnimationSample: Equatable {
    let windowOpacity: UInt8
    let focusOpacity: UInt8
    let selectionOpacity: UInt8
    let hoverOpacity: UInt8
    let cursorIsVisible: Bool
}

struct FileManagerAnimationAdvance: Equatable {
    let sample: FileManagerAnimationSample
    let framesDue: UInt64
    let droppedFrames: UInt64
    let ticksUntilNextFrame: UInt64
}

/// Counter-driven presentation state for the file-manager scene. It contains
/// no wall clock, floating point, backend handle, or board-specific behavior.
struct FileManagerAnimationState {
    private let cursorHalfPeriodTicks: UInt64
    private let startedAt: UInt64
    private var pacer: FramePacer
    private var opening: DeterministicUIAnimationChannel
    private var focus: DeterministicUIAnimationChannel
    private var selection: DeterministicUIAnimationChannel
    private var hover: DeterministicUIAnimationChannel

    init?(
        counterFrequency: UInt64,
        targetFramesPerSecond: UInt64 = 60,
        startingAt counterTick: UInt64,
        initiallyFocused: Bool = true
    ) {
        guard targetFramesPerSecond > 0,
              counterFrequency >= targetFramesPerSecond,
              counterFrequency / 5 > 0,
              counterFrequency / 2 > 0,
              let pacer = FramePacer(
                  ticksPerFrame: counterFrequency / targetFramesPerSecond,
                  startingAt: counterTick
              ),
              var opening = DeterministicUIAnimationChannel(
                  durationTicks: counterFrequency / 5,
                  initialValue: .zero,
                  curve: .easeOut,
                  startingAt: counterTick
              ),
              let focus = DeterministicUIAnimationChannel(
                  durationTicks: counterFrequency / 8,
                  initialValue: initiallyFocused ? .one : .zero,
                  curve: .easeInOut,
                  startingAt: counterTick
              ),
              let selection = DeterministicUIAnimationChannel(
                  durationTicks: counterFrequency / 8,
                  initialValue: .zero,
                  curve: .easeOut,
                  startingAt: counterTick
              ),
              let hover = DeterministicUIAnimationChannel(
                  durationTicks: counterFrequency / 10,
                  initialValue: .zero,
                  curve: .easeOut,
                  startingAt: counterTick
              )
        else {
            return nil
        }
        opening.setTarget(.one, at: counterTick)
        cursorHalfPeriodTicks = counterFrequency / 2
        startedAt = counterTick
        self.pacer = pacer
        self.opening = opening
        self.focus = focus
        self.selection = selection
        self.hover = hover
    }

    mutating func setFocused(_ focused: Bool, at counterTick: UInt64) {
        focus.setTarget(focused ? .one : .zero, at: counterTick)
    }

    mutating func setSelectionVisible(_ visible: Bool, at counterTick: UInt64) {
        selection.setTarget(visible ? .one : .zero, at: counterTick)
    }

    mutating func setHoverVisible(_ visible: Bool, at counterTick: UInt64) {
        hover.setTarget(visible ? .one : .zero, at: counterTick)
    }

    func sample(at counterTick: UInt64) -> FileManagerAnimationSample {
        FileManagerAnimationSample(
            windowOpacity: scaledByte(opening.sample(at: counterTick), 255),
            focusOpacity: scaledByte(focus.sample(at: counterTick), 255),
            selectionOpacity: scaledByte(
                selection.sample(at: counterTick),
                112
            ),
            hoverOpacity: scaledByte(hover.sample(at: counterTick), 64),
            cursorIsVisible:
                focus.sample(at: counterTick).rawValue
                    > AnimationProgress.unitRawValue / 2
                && ((counterTick &- startedAt) / cursorHalfPeriodTicks) & 1 == 0
        )
    }

    mutating func advance(to counterTick: UInt64) -> FileManagerAnimationAdvance {
        let decision = pacer.advance(to: counterTick)
        return FileManagerAnimationAdvance(
            sample: sample(at: counterTick),
            framesDue: decision.framesDue,
            droppedFrames: decision.droppedFrames,
            ticksUntilNextFrame: decision.ticksUntilNextFrame
        )
    }

    private func scaledByte(
        _ progress: AnimationProgress,
        _ maximum: UInt8
    ) -> UInt8 {
        UInt8(
            progress.interpolate(from: 0, to: Int64(maximum))
        )
    }
}
