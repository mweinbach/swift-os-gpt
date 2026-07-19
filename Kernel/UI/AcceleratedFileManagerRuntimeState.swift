/// Deterministic interaction state shared by the QEMU runtime and host tests.
/// Every backing buffer is caller-owned and must outlive this value.
struct AcceleratedFileManagerInteractionState {
    static let windowID = UIWindowID(rawValue: 1)!
    private static let maximumRenderedRowCount = 4

    private(set) var browser: FileBrowserModel
    private(set) var router: WindowInputRouter
    let layout: FileManagerLayout
    private(set) var animation: FileManagerAnimationState
    private(set) var hoveredVisibleRow: Int?
    private(set) var needsPresentation = true

    private var keyboardComposer: USKeyboardTextComposer?
    private var typeahead: BoundedASCIITextBuffer
    private let typeaheadStorageBase: UnsafeMutableRawPointer
    private let counterFrequency: UInt64
    private let pointerScale: Int64
    private var currentCounterTick: UInt64
    private var lastTypeaheadTick: UInt64?
    private var pointerRemainderX: Int64 = 0
    private var pointerRemainderY: Int64 = 0
    private var animationTransitionStartedAt: UInt64?
    private var animationTransitionDurationTicks: UInt64

    init?(
        entryStorage: UnsafeMutableBufferPointer<FileBrowserEntryRecord>,
        nameStorage: UnsafeMutableRawBufferPointer,
        windowStorage: UnsafeMutableBufferPointer<UIWindowRecord>,
        typeaheadStorage: UnsafeMutableRawBufferPointer,
        layout: FileManagerLayout,
        counterFrequency: UInt64,
        startingAt counterTick: UInt64,
        pointerScale: Int = 1
    ) {
        guard pointerScale > 0, pointerScale <= Int(Int32.max),
              let typeaheadStorageBase = typeaheadStorage.baseAddress,
              let browser = FileBrowserModel(
                  entryStorage: entryStorage,
                  nameStorage: nameStorage,
                  visibleRowCapacity: Self.minimum(
                      Self.minimum(
                          layout.rowCapacity,
                          Self.maximumRenderedRowCount
                      ),
                      entryStorage.count
                  )
              ), var router = WindowInputRouter(
                  windowStorage: windowStorage,
                  desktopBounds: layout.desktopBounds,
                  initialCursorPosition: Point(
                      x: layout.desktopBounds.x
                        + layout.desktopBounds.width / 2,
                      y: layout.desktopBounds.y
                        + layout.desktopBounds.height / 2
                  )
              ), router.registerWindow(
                  identifier: Self.windowID,
                  frame: layout.windowFrame
              ) == .applied,
              let animation = FileManagerAnimationState(
                  counterFrequency: counterFrequency,
                  startingAt: counterTick
              ), let typeahead = BoundedASCIITextBuffer(
                  storage: typeaheadStorage
              )
        else {
            return nil
        }
        self.browser = browser
        self.router = router
        self.layout = layout
        self.animation = animation
        self.typeahead = typeahead
        self.typeaheadStorageBase = typeaheadStorageBase
        self.counterFrequency = counterFrequency
        self.pointerScale = Int64(pointerScale)
        currentCounterTick = counterTick
        hoveredVisibleRow = nil
        animationTransitionStartedAt = counterTick
        animationTransitionDurationTicks = counterFrequency / 5
    }

    var animationNeedsPresentation: Bool {
        animationTransitionStartedAt != nil
    }

    @discardableResult
    mutating func beginDirectoryReload() -> Bool {
        guard browser.beginReload() else { return false }
        typeahead.clear()
        lastTypeaheadTick = nil
        hoveredVisibleRow = nil
        animation.setSelectionVisible(false, at: currentCounterTick)
        animation.setHoverVisible(false, at: currentCounterTick)
        scheduleAnimation(durationTicks: counterFrequency / 8)
        needsPresentation = true
        return true
    }

    mutating func append(
        _ entry: VFSDirectoryEntry,
        metadata: VFSNodeMetadata
    ) -> FileBrowserAppendResult {
        let result = browser.append(entry, metadata: metadata)
        if case .inserted = result {
            animation.setSelectionVisible(
                browser.selectedIndex != nil,
                at: currentCounterTick
            )
            scheduleAnimation(durationTicks: counterFrequency / 8)
            needsPresentation = true
        }
        return result
    }

    /// Consumes one already-validated canonical event. The QEMU input runtime
    /// calls this synchronously from its post-queue dispatch boundary.
    mutating func accept(_ event: InputEvent) {
        let previousFocus = router.focusedWindowID
        let previousCursor = router.cursor.position
        let layout = self.layout
        let routedEvent = scaledPointerMotion(event)
        let routed = router.route(routedEvent) { window, point in
            guard window == Self.windowID,
                  let region = layout.hitTest(point)
            else {
                return nil
            }
            return layout.controlID(for: region)
        }
        guard case .routed(let input) = routed else { return }

        if previousFocus != router.focusedWindowID {
            animation.setFocused(
                router.focusedWindowID == Self.windowID,
                at: currentCounterTick
            )
            scheduleAnimation(durationTicks: counterFrequency / 8)
            needsPresentation = true
        }

        switch input.kind {
        case .pointerMoved:
            updateHoverAndCursor()
            let cursor = router.cursor.position
            if cursor.x != previousCursor.x || cursor.y != previousCursor.y {
                needsPresentation = true
            }
        case .pointerButtonPressed:
            updateHoverAndCursor()
            needsPresentation = true
        case .pointerButtonReleased(let button, let isClick):
            updateHoverAndCursor()
            if button == 1, isClick {
                selectClickedRow()
            }
            needsPresentation = true
        case .pointerScrolled(let vertical, _):
            guard pointerIsOverList else { return }
            let rows = -Int(vertical)
            if browser.scroll(byRows: rows) { needsPresentation = true }
            updateHoverAndCursor()
        case .keyboard:
            guard input.target?.window == Self.windowID else { return }
            handleKeyboard(input.event)
        }
    }

    mutating func advanceAnimations(
        to counterTick: UInt64
    ) -> FileManagerAnimationAdvance {
        currentCounterTick = counterTick
        if let lastTypeaheadTick,
           counterTick &- lastTypeaheadTick >= counterFrequency {
            typeahead.clear()
            self.lastTypeaheadTick = nil
        }
        return animation.advance(to: counterTick)
    }

    mutating func markPresented() {
        needsPresentation = false
        if let startedAt = animationTransitionStartedAt,
           currentCounterTick &- startedAt
            >= animationTransitionDurationTicks {
            animationTransitionStartedAt = nil
        }
    }

    private mutating func updateHoverAndCursor() {
        let region = layout.hitTest(router.cursor.position)
        router.setCursorShape(layout.cursorShape(for: region))
        let nextHover: Int?
        if case .listRow(let row) = region,
           row >= 0,
           row < browser.visibleItemCount {
            nextHover = row
        } else {
            nextHover = nil
        }
        if nextHover != hoveredVisibleRow {
            hoveredVisibleRow = nextHover
            animation.setHoverVisible(
                nextHover != nil,
                at: currentCounterTick
            )
            scheduleAnimation(durationTicks: counterFrequency / 10)
            needsPresentation = true
        }
    }

    private var pointerIsOverList: Bool {
        switch layout.hitTest(router.cursor.position) {
        case .listRow, .listBackground:
            return true
        default:
            return false
        }
    }

    private mutating func selectClickedRow() {
        guard case .listRow(let row) = layout.hitTest(router.cursor.position),
              row >= 0,
              row < browser.visibleItemCount
        else {
            return
        }
        applySelection(
            browser.select(index: browser.firstVisibleIndex + row)
        )
    }

    private mutating func handleKeyboard(_ event: InputEvent) {
        if keyboardComposer == nil {
            keyboardComposer = USKeyboardTextComposer(deviceID: event.deviceID)
        }
        guard var composer = keyboardComposer else { return }
        let result = composer.process(event)
        keyboardComposer = composer
        guard case .action(let action, let isRepeat) = result else { return }

        switch action {
        case .navigate(let navigation):
            let command: FileBrowserSelectionCommand?
            switch navigation {
            case .up, .left: command = .previous
            case .down, .right: command = .next
            case .home: command = .first
            case .end: command = .last
            case .pageUp: command = .pagePrevious
            case .pageDown: command = .pageNext
            }
            if let command { applySelection(browser.moveSelection(command)) }
        case .insertASCII:
            guard !isRepeat else { return }
            if typeahead.apply(action) == .changed {
                lastTypeaheadTick = currentCounterTick
                selectTypeaheadPrefix()
            }
        case .deleteBackward:
            if typeahead.apply(action) == .changed {
                lastTypeaheadTick = currentCounterTick
                selectTypeaheadPrefix()
            }
        case .cancel:
            typeahead.clear()
            lastTypeaheadTick = nil
        case .deleteForward, .submit, .tab, .command:
            break
        }
    }

    private mutating func selectTypeaheadPrefix() {
        let view = typeahead.view
        guard view.byteCount > 0 else { return }
        applySelection(
            browser.selectFirstName(
                matchingPrefix: UnsafeRawBufferPointer(
                    start: typeaheadStorageBase,
                    count: view.byteCount
                )
            )
        )
    }

    private mutating func applySelection(
        _ result: FileBrowserSelectionResult
    ) {
        switch result {
        case .changed:
            animation.setSelectionVisible(true, at: currentCounterTick)
            scheduleAnimation(durationTicks: counterFrequency / 8)
            needsPresentation = true
        case .empty:
            animation.setSelectionVisible(false, at: currentCounterTick)
            scheduleAnimation(durationTicks: counterFrequency / 8)
            needsPresentation = true
        case .unchanged:
            break
        }
    }

    private static func minimum(_ left: Int, _ right: Int) -> Int {
        left < right ? left : right
    }

    private mutating func scaledPointerMotion(
        _ event: InputEvent
    ) -> InputEvent {
        guard event.kind == .pointerMotion, pointerScale > 1 else {
            return event
        }
        let accumulatedX = pointerRemainderX + Int64(event.value0)
        let accumulatedY = pointerRemainderY + Int64(event.value1)
        let logicalX = accumulatedX / pointerScale
        let logicalY = accumulatedY / pointerScale
        pointerRemainderX = accumulatedX % pointerScale
        pointerRemainderY = accumulatedY % pointerScale
        return .pointerMotion(
            timestampTicks: event.timestampTicks,
            deviceID: event.deviceID,
            deltaX: Int32(logicalX),
            deltaY: Int32(logicalY)
        )
    }

    private mutating func scheduleAnimation(durationTicks: UInt64) {
        var remainingTicks: UInt64 = 0
        if let startedAt = animationTransitionStartedAt {
            let elapsed = currentCounterTick &- startedAt
            if elapsed < animationTransitionDurationTicks {
                remainingTicks = animationTransitionDurationTicks - elapsed
            }
        }
        animationTransitionStartedAt = currentCounterTick
        animationTransitionDurationTicks = remainingTicks > durationTicks
            ? remainingTicks
            : durationTicks
    }
}

enum FileManagerDirectoryLoadResult: Equatable {
    case loaded(entryCount: Int, directoryWasTruncated: Bool)
    case failed
}

/// Loads one provider directory into the bounded browser model. Directory names
/// are copied synchronously before the provider may reuse its scratch buffer.
enum FileManagerDirectoryLoader {
    static func load<Provider: VFSNodeProvider>(
        interaction: inout AcceleratedFileManagerInteractionState,
        provider: inout Provider,
        root: VFSNodeIdentifier,
        nameScratch: UnsafeMutableRawBufferPointer
    ) -> FileManagerDirectoryLoadResult {
        let capacity = interaction.browser.capacity
        guard capacity <= Int.max - 2,
              interaction.beginDirectoryReload()
        else {
            return .failed
        }

        let enumerationStepBudget = capacity + 2
        var remainingSteps = enumerationStepBudget
        var cookie = VFSDirectoryCookie.start
        var didRestart = false
        while remainingSteps > 0 {
            if interaction.browser.count == capacity {
                // Probe one result beyond the bounded page so an exactly-full
                // directory is not mislabeled as truncated. Do not resolve
                // metadata or append the borrowed name for that probe.
                remainingSteps -= 1
                switch provider.readDirectory(
                    node: root,
                    after: cookie,
                    nameOutput: nameScratch
                ) {
                case .entry, .staleCookie:
                    return .loaded(
                        entryCount: interaction.browser.count,
                        directoryWasTruncated: true
                    )
                case .end:
                    return .loaded(
                        entryCount: interaction.browser.count,
                        directoryWasTruncated: false
                    )
                case .nameBufferTooSmall, .failure:
                    return .failed
                }
            }
            remainingSteps -= 1
            switch provider.readDirectory(
                node: root,
                after: cookie,
                nameOutput: nameScratch
            ) {
            case .entry(let entry, let nextCookie):
                let metadata: VFSNodeMetadata
                switch provider.metadata(for: entry.identifier) {
                case .metadata(let value): metadata = value
                case .failure: return .failed
                }
                guard case .inserted = interaction.append(
                          entry,
                          metadata: metadata
                      )
                else {
                    return .failed
                }
                cookie = nextCookie
            case .end:
                return .loaded(
                    entryCount: interaction.browser.count,
                    directoryWasTruncated: false
                )
            case .staleCookie:
                guard !didRestart, interaction.beginDirectoryReload() else {
                    return .failed
                }
                didRestart = true
                remainingSteps = enumerationStepBudget
                cookie = .start
            case .nameBufferTooSmall, .failure:
                return .failed
            }
        }
        return .failed
    }
}
