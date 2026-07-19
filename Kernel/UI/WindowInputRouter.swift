struct UIWindowID: RawRepresentable, Equatable {
    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct UIControlID: RawRepresentable, Equatable {
    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct UIHitTarget: Equatable {
    let window: UIWindowID
    let control: UIControlID?
}

enum UICursorShape: UInt8, Equatable {
    case arrow
    case text
    case pointingHand
    case resizeHorizontal
    case resizeVertical
    case resizeDiagonalDown
    case resizeDiagonalUp
}

struct DesktopCursorState {
    fileprivate(set) var position: Point
    fileprivate(set) var shape: UICursorShape
    fileprivate(set) var isVisible: Bool
    fileprivate(set) var pressedButtonMask: UInt32
    fileprivate(set) var hoveredTarget: UIHitTarget?
    fileprivate(set) var capturedTarget: UIHitTarget?
}

struct UIWindowRecord {
    fileprivate var identifier: UIWindowID?
    fileprivate var frame: Rectangle
    fileprivate var stackOrder: UInt32
    fileprivate var pendingStackOrder: UInt32
    fileprivate var isVisible: Bool
    fileprivate var acceptsFocus: Bool

    static let vacant = UIWindowRecord(
        identifier: nil,
        frame: Rectangle(x: 0, y: 0, width: 1, height: 1),
        stackOrder: 0,
        pendingStackOrder: 0,
        isVisible: false,
        acceptsFocus: false
    )
}

struct UIWindowView {
    let identifier: UIWindowID
    let frame: Rectangle
    let stackOrder: UInt32
    let isVisible: Bool
    let acceptsFocus: Bool
    let isFocused: Bool
}

enum UIWindowMutationRejection: Equatable {
    case capacityExhausted
    case duplicateIdentifier
    case identifierNotFound
    case invalidFrame
    case stackOrderExhausted
}

enum UIWindowMutationResult: Equatable {
    case applied
    case rejected(UIWindowMutationRejection)
}

enum UIWindowRoutedInputKind: Equatable {
    case pointerMoved
    case pointerButtonPressed(button: UInt8)
    case pointerButtonReleased(button: UInt8, isClick: Bool)
    case pointerScrolled(vertical: Int32, horizontal: Int32)
    case keyboard
}

struct UIWindowRoutedInput {
    let kind: UIWindowRoutedInputKind
    let target: UIHitTarget?
    let event: InputEvent
}

enum UIWindowInputRoutingResult {
    case routed(UIWindowRoutedInput)
    case ignored
}

/// Bounded desktop z-order, focus, pointer hit testing, and pointer capture.
/// A caller supplies control-level hit testing after the router chooses the
/// topmost window, keeping generic window policy independent from widgets.
struct WindowInputRouter {
    static let maximumWindowCount = 64

    private let windows: UnsafeMutableBufferPointer<UIWindowRecord>
    let desktopBounds: Rectangle
    private(set) var count = 0
    private(set) var focusedWindowID: UIWindowID?
    private(set) var cursor: DesktopCursorState

    init?(
        windowStorage: UnsafeMutableBufferPointer<UIWindowRecord>,
        desktopBounds: Rectangle,
        initialCursorPosition: Point
    ) {
        guard windowStorage.baseAddress != nil,
              !windowStorage.isEmpty,
              windowStorage.count <= Self.maximumWindowCount,
              Self.isValid(desktopBounds)
        else {
            return nil
        }
        windows = windowStorage
        self.desktopBounds = desktopBounds
        cursor = DesktopCursorState(
            position: Self.clamped(initialCursorPosition, to: desktopBounds),
            shape: .arrow,
            isVisible: true,
            pressedButtonMask: 0,
            hoveredTarget: nil,
            capturedTarget: nil
        )
        var index = 0
        while index < windows.count {
            windows[index] = .vacant
            index += 1
        }
    }

    mutating func registerWindow(
        identifier: UIWindowID,
        frame: Rectangle,
        isVisible: Bool = true,
        acceptsFocus: Bool = true
    ) -> UIWindowMutationResult {
        guard count < windows.count else {
            return .rejected(.capacityExhausted)
        }
        guard windowIndex(for: identifier) == nil else {
            return .rejected(.duplicateIdentifier)
        }
        guard Self.isValid(frame), Self.intersects(frame, desktopBounds) else {
            return .rejected(.invalidFrame)
        }
        guard let order = nextStackOrder() else {
            return .rejected(.stackOrderExhausted)
        }
        windows[count] = UIWindowRecord(
            identifier: identifier,
            frame: frame,
            stackOrder: order,
            pendingStackOrder: 0,
            isVisible: isVisible,
            acceptsFocus: acceptsFocus
        )
        count += 1
        if focusedWindowID == nil, isVisible, acceptsFocus {
            focusedWindowID = identifier
        }
        return .applied
    }

    mutating func updateFrame(
        of identifier: UIWindowID,
        to frame: Rectangle
    ) -> UIWindowMutationResult {
        guard let index = windowIndex(for: identifier) else {
            return .rejected(.identifierNotFound)
        }
        guard Self.isValid(frame), Self.intersects(frame, desktopBounds) else {
            return .rejected(.invalidFrame)
        }
        windows[index].frame = frame
        return .applied
    }

    mutating func setVisible(
        _ isVisible: Bool,
        window identifier: UIWindowID
    ) -> UIWindowMutationResult {
        guard let index = windowIndex(for: identifier) else {
            return .rejected(.identifierNotFound)
        }
        windows[index].isVisible = isVisible
        if !isVisible {
            if focusedWindowID == identifier { focusedWindowID = nil }
            if cursor.capturedTarget?.window == identifier {
                cursor.capturedTarget = nil
                cursor.pressedButtonMask = 0
            }
            if cursor.hoveredTarget?.window == identifier {
                cursor.hoveredTarget = nil
            }
        }
        return .applied
    }

    mutating func removeWindow(
        identifier: UIWindowID
    ) -> UIWindowMutationResult {
        guard let index = windowIndex(for: identifier) else {
            return .rejected(.identifierNotFound)
        }
        var destination = index
        while destination + 1 < count {
            windows[destination] = windows[destination + 1]
            destination += 1
        }
        count -= 1
        windows[count] = .vacant
        if focusedWindowID == identifier { focusedWindowID = nil }
        if cursor.hoveredTarget?.window == identifier {
            cursor.hoveredTarget = nil
        }
        if cursor.capturedTarget?.window == identifier {
            cursor.capturedTarget = nil
            cursor.pressedButtonMask = 0
        }
        return .applied
    }

    func window(withID identifier: UIWindowID) -> UIWindowView? {
        guard let index = windowIndex(for: identifier),
              let storedID = windows[index].identifier
        else {
            return nil
        }
        let record = windows[index]
        return UIWindowView(
            identifier: storedID,
            frame: record.frame,
            stackOrder: record.stackOrder,
            isVisible: record.isVisible,
            acceptsFocus: record.acceptsFocus,
            isFocused: focusedWindowID == storedID
        )
    }

    mutating func setCursorShape(_ shape: UICursorShape) {
        cursor.shape = shape
    }

    mutating func setCursorVisible(_ visible: Bool) {
        cursor.isVisible = visible
    }

    mutating func route(
        _ event: InputEvent,
        controlHitTest: (UIWindowID, Point) -> UIControlID?
    ) -> UIWindowInputRoutingResult {
        switch event.kind {
        case .pointerMotion:
            let moved = Point(
                x: Self.saturatedAdd(cursor.position.x, Int(event.value0)),
                y: Self.saturatedAdd(cursor.position.y, Int(event.value1))
            )
            cursor.position = Self.clamped(moved, to: desktopBounds)
            cursor.hoveredTarget = hitTarget(
                at: cursor.position,
                controlHitTest: controlHitTest
            )
            return .routed(
                UIWindowRoutedInput(
                    kind: .pointerMoved,
                    target: cursor.capturedTarget ?? cursor.hoveredTarget,
                    event: event
                )
            )
        case .pointerButton:
            return routeButton(event, controlHitTest: controlHitTest)
        case .pointerScroll:
            cursor.hoveredTarget = hitTarget(
                at: cursor.position,
                controlHitTest: controlHitTest
            )
            return .routed(
                UIWindowRoutedInput(
                    kind: .pointerScrolled(
                        vertical: event.value0,
                        horizontal: event.value1
                    ),
                    target: cursor.capturedTarget ?? cursor.hoveredTarget,
                    event: event
                )
            )
        case .keyboardUsage, .keyboardModifiers:
            let target = focusedWindowID.map {
                UIHitTarget(window: $0, control: nil)
            }
            return .routed(
                UIWindowRoutedInput(
                    kind: .keyboard,
                    target: target,
                    event: event
                )
            )
        case .synchronization:
            return .ignored
        default:
            return .ignored
        }
    }

    private mutating func routeButton(
        _ event: InputEvent,
        controlHitTest: (UIWindowID, Point) -> UIControlID?
    ) -> UIWindowInputRoutingResult {
        guard event.code >= 1, event.code <= 32 else { return .ignored }
        let button = UInt8(event.code)
        let mask = UInt32(1) << UInt32(button - 1)
        cursor.hoveredTarget = hitTarget(
            at: cursor.position,
            controlHitTest: controlHitTest
        )

        if event.isPressed {
            if cursor.pressedButtonMask == 0 {
                cursor.capturedTarget = cursor.hoveredTarget
                if let window = cursor.hoveredTarget?.window {
                    focusAndRaise(window)
                } else {
                    focusedWindowID = nil
                }
            }
            cursor.pressedButtonMask |= mask
            return .routed(
                UIWindowRoutedInput(
                    kind: .pointerButtonPressed(button: button),
                    target: cursor.capturedTarget ?? cursor.hoveredTarget,
                    event: event
                )
            )
        }

        guard cursor.pressedButtonMask & mask != 0 else { return .ignored }
        let target = cursor.capturedTarget ?? cursor.hoveredTarget
        let isClick = cursor.capturedTarget != nil
            && cursor.capturedTarget == cursor.hoveredTarget
        cursor.pressedButtonMask &= ~mask
        if cursor.pressedButtonMask == 0 {
            cursor.capturedTarget = nil
        }
        return .routed(
            UIWindowRoutedInput(
                kind: .pointerButtonReleased(
                    button: button,
                    isClick: isClick
                ),
                target: target,
                event: event
            )
        )
    }

    private func hitTarget(
        at point: Point,
        controlHitTest: (UIWindowID, Point) -> UIControlID?
    ) -> UIHitTarget? {
        guard let window = topmostWindow(at: point) else { return nil }
        return UIHitTarget(
            window: window,
            control: controlHitTest(window, point)
        )
    }

    private func topmostWindow(at point: Point) -> UIWindowID? {
        var selectedIndex: Int?
        var index = 0
        while index < count {
            let candidate = windows[index]
            if candidate.isVisible,
               candidate.identifier != nil,
               Self.contains(candidate.frame, point) {
                if let currentIndex = selectedIndex {
                    let current = windows[currentIndex]
                    if candidate.stackOrder > current.stackOrder
                        || candidate.stackOrder == current.stackOrder
                        && (candidate.identifier?.rawValue ?? 0)
                            > (current.identifier?.rawValue ?? 0) {
                        selectedIndex = index
                    }
                } else {
                    selectedIndex = index
                }
            }
            index += 1
        }
        guard let selectedIndex else { return nil }
        return windows[selectedIndex].identifier
    }

    private mutating func focusAndRaise(_ identifier: UIWindowID) {
        guard let index = windowIndex(for: identifier),
              windows[index].isVisible
        else {
            return
        }
        if windows[index].acceptsFocus { focusedWindowID = identifier }
        if let order = nextStackOrder() { windows[index].stackOrder = order }
    }

    private mutating func nextStackOrder() -> UInt32? {
        var maximum: UInt32 = 0
        var index = 0
        while index < count {
            if windows[index].stackOrder > maximum {
                maximum = windows[index].stackOrder
            }
            index += 1
        }
        if maximum == UInt32.max {
            rebaseStackOrder()
            maximum = UInt32(count)
        }
        guard maximum < UInt32.max else { return nil }
        return maximum + 1
    }

    private mutating func rebaseStackOrder() {
        var candidateIndex = 0
        while candidateIndex < count {
            var rank: UInt32 = 1
            var comparisonIndex = 0
            while comparisonIndex < count {
                if comparisonIndex != candidateIndex {
                    let candidate = windows[candidateIndex]
                    let comparison = windows[comparisonIndex]
                    if comparison.stackOrder < candidate.stackOrder
                        || comparison.stackOrder == candidate.stackOrder
                        && (comparison.identifier?.rawValue ?? 0)
                            < (candidate.identifier?.rawValue ?? 0) {
                        rank += 1
                    }
                }
                comparisonIndex += 1
            }
            windows[candidateIndex].pendingStackOrder = rank
            candidateIndex += 1
        }
        var commitIndex = 0
        while commitIndex < count {
            windows[commitIndex].stackOrder = windows[commitIndex]
                .pendingStackOrder
            windows[commitIndex].pendingStackOrder = 0
            commitIndex += 1
        }
    }

    private func windowIndex(for identifier: UIWindowID) -> Int? {
        var index = 0
        while index < count {
            if windows[index].identifier == identifier { return index }
            index += 1
        }
        return nil
    }

    private static func isValid(_ rectangle: Rectangle) -> Bool {
        guard rectangle.width > 0, rectangle.height > 0 else { return false }
        return !rectangle.x.addingReportingOverflow(rectangle.width).overflow
            && !rectangle.y.addingReportingOverflow(rectangle.height).overflow
    }

    private static func intersects(
        _ first: Rectangle,
        _ second: Rectangle
    ) -> Bool {
        first.x < second.x + second.width
            && second.x < first.x + first.width
            && first.y < second.y + second.height
            && second.y < first.y + first.height
    }

    private static func contains(_ rectangle: Rectangle, _ point: Point) -> Bool {
        point.x >= rectangle.x && point.x < rectangle.x + rectangle.width
            && point.y >= rectangle.y && point.y < rectangle.y + rectangle.height
    }

    private static func saturatedAdd(_ coordinate: Int, _ delta: Int) -> Int {
        let result = coordinate.addingReportingOverflow(delta)
        guard result.overflow else { return result.partialValue }
        return delta >= 0 ? Int.max : Int.min
    }

    private static func clamped(_ point: Point, to bounds: Rectangle) -> Point {
        let maximumX = bounds.x + bounds.width - 1
        let maximumY = bounds.y + bounds.height - 1
        return Point(
            x: point.x < bounds.x
                ? bounds.x
                : (point.x > maximumX ? maximumX : point.x),
            y: point.y < bounds.y
                ? bounds.y
                : (point.y > maximumY ? maximumY : point.y)
        )
    }
}
