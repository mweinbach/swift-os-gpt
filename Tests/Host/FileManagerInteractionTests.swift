@main
struct FileManagerInteractionTests {
    static func main() {
        fileBrowserCopiesSortsSelectsAndScrolls()
        fileBrowserRejectsDuplicatesMetadataAndCapacityFailures()
        keyboardComposesUSLayoutModifiersAndNavigation()
        boundedTextEditingIsDeterministic()
        windowRouterFocusesHitTestsAndCaptures()
        fileManagerLayoutSharesHitGeometry()
        animationChannelsRetargetWithoutJumps()
        print("file-manager interaction host tests: 7 groups passed")
    }

    private static func fileBrowserCopiesSortsSelectsAndScrolls() {
        var records = [FileBrowserEntryRecord](repeating: .vacant, count: 4)
        var names = [UInt8](repeating: 0, count: 32)
        records.withUnsafeMutableBufferPointer { entryStorage in
            names.withUnsafeMutableBytes { nameStorage in
                var model = FileBrowserModel(
                    entryStorage: entryStorage,
                    nameStorage: nameStorage,
                    visibleRowCapacity: 2
                )!
                expectAppend(
                    &model,
                    name: "zeta",
                    id: 1,
                    kind: .regularFile,
                    size: 40
                )
                expectAppend(
                    &model,
                    name: "Beta",
                    id: 2,
                    kind: .directory,
                    size: 0
                )
                expectAppend(
                    &model,
                    name: "Alpha",
                    id: 3,
                    kind: .directory,
                    size: 0
                )
                expectAppend(
                    &model,
                    name: "aardvark",
                    id: 4,
                    kind: .regularFile,
                    size: 90
                )

                expect(model.count == 4, "browser count")
                expect(itemName(model, 0) == "Alpha", "directory sort Alpha")
                expect(itemName(model, 1) == "Beta", "directory sort Beta")
                expect(itemName(model, 2) == "aardvark", "file sort aardvark")
                expect(itemName(model, 3) == "zeta", "file sort zeta")
                expect(
                    model.selectedItem?.identifier.localValue == 1,
                    "insertion changed selected identity"
                )
                expect(model.selectedIndex == 3, "selected index did not move")
                expect(model.firstVisibleIndex == 2, "selection not scrolled visible")
                expect(model.visibleItemCount == 2, "visible item count")
                expect(
                    model.moveSelection(.pagePrevious) == .changed(index: 1),
                    "page previous"
                )
                expect(model.firstVisibleIndex == 1, "page selection visibility")
                expect(model.scroll(byRows: Int.max), "large forward scroll")
                expect(model.firstVisibleIndex == 2, "forward scroll clamp")
                expect(model.scroll(byRows: Int.min), "large reverse scroll")
                expect(model.firstVisibleIndex == 0, "reverse scroll clamp")

                let prefix = Array("be".utf8)
                let result = prefix.withUnsafeBytes {
                    model.selectFirstName(matchingPrefix: $0)
                }
                expect(result == .unchanged(index: 1), "type-ahead selection")
                expect(model.selectedItem?.identifier.localValue == 2, "prefix ID")
                expect(model.item(at: -1) == nil, "negative item index")
                expect(model.visibleItem(atRow: 2) == nil, "invalid visible row")

                let oldRevision = model.revision
                expect(model.beginReload(), "reload rejected")
                expect(model.revision == oldRevision + 1, "reload revision")
                expect(model.count == 0 && model.selectedIndex == nil, "reload clear")
            }
        }
    }

    private static func fileBrowserRejectsDuplicatesMetadataAndCapacityFailures() {
        var records = [FileBrowserEntryRecord](repeating: .vacant, count: 2)
        var names = [UInt8](repeating: 0, count: 8)
        records.withUnsafeMutableBufferPointer { entryStorage in
            names.withUnsafeMutableBytes { nameStorage in
                var model = FileBrowserModel(
                    entryStorage: entryStorage,
                    nameStorage: nameStorage,
                    visibleRowCapacity: 1
                )!
                expectAppend(
                    &model,
                    name: "one",
                    id: 1,
                    kind: .regularFile,
                    size: 1
                )
                expect(
                    append(&model, name: "two", id: 1, kind: .regularFile)
                        == .rejected(.duplicateIdentifier),
                    "duplicate node ID accepted"
                )
                expect(
                    append(&model, name: "one", id: 2, kind: .regularFile)
                        == .rejected(.duplicateName),
                    "duplicate name accepted"
                )
                let mismatch = withDirectoryEntry(
                    name: "two",
                    id: 2,
                    kind: .regularFile
                ) { entry in
                    model.append(
                        entry,
                        metadata: metadata(id: 3, kind: .regularFile, size: 2)
                    )
                }
                expect(
                    mismatch == .rejected(.metadataDoesNotMatchEntry),
                    "mismatched metadata accepted"
                )
                expectAppend(
                    &model,
                    name: "two",
                    id: 2,
                    kind: .regularFile,
                    size: 2
                )
                expect(
                    append(&model, name: "x", id: 3, kind: .regularFile)
                        == .rejected(.entryCapacityExhausted),
                    "entry capacity overflow"
                )
            }
        }

        var oneRecord = [FileBrowserEntryRecord](repeating: .vacant, count: 1)
        var tinyNames = [UInt8](repeating: 0, count: 2)
        oneRecord.withUnsafeMutableBufferPointer { entryStorage in
            tinyNames.withUnsafeMutableBytes { nameStorage in
                var model = FileBrowserModel(
                    entryStorage: entryStorage,
                    nameStorage: nameStorage,
                    visibleRowCapacity: 1
                )!
                expect(
                    append(&model, name: "long", id: 1, kind: .regularFile)
                        == .rejected(
                            .nameCapacityExhausted(
                                requiredByteCount: 4,
                                availableByteCount: 2
                            )
                        ),
                    "name capacity overflow"
                )
                expect(model.count == 0, "rejected name mutated listing")
            }
        }
    }

    private static func keyboardComposesUSLayoutModifiersAndNavigation() {
        let keyboard = InputDeviceID(rawValue: 7)
        var composer = USKeyboardTextComposer(deviceID: keyboard)
        expect(
            composer.process(key(usage: 0x04, pressed: true, device: keyboard))
                == .action(.insertASCII(0x61), isRepeat: false),
            "lowercase a"
        )
        expect(
            composer.process(key(usage: 0x04, pressed: true, device: keyboard))
                == .action(.insertASCII(0x61), isRepeat: true),
            "key repeat"
        )
        _ = composer.process(key(usage: 0x04, pressed: false, device: keyboard))

        let shift = KeyboardModifierMask.leftShift
        expect(
            composer.process(modifiers(shift, changed: shift, device: keyboard))
                == .stateChanged,
            "shift transition"
        )
        expect(
            composer.process(key(usage: 0x1e, pressed: true, device: keyboard))
                == .action(.insertASCII(0x21), isRepeat: false),
            "shifted digit"
        )
        _ = composer.process(key(usage: 0x1e, pressed: false, device: keyboard))
        _ = composer.process(modifiers(.none, changed: shift, device: keyboard))

        expect(
            composer.process(key(usage: 0x39, pressed: true, device: keyboard))
                == .stateChanged,
            "caps lock transition"
        )
        expect(composer.capsLockEnabled, "caps lock did not enable")
        _ = composer.process(key(usage: 0x39, pressed: true, device: keyboard))
        expect(composer.capsLockEnabled, "caps repeat toggled state")
        _ = composer.process(key(usage: 0x39, pressed: false, device: keyboard))
        expect(
            composer.process(key(usage: 0x05, pressed: true, device: keyboard))
                == .action(.insertASCII(0x42), isRepeat: false),
            "caps uppercase letter"
        )
        _ = composer.process(key(usage: 0x05, pressed: false, device: keyboard))

        let control = KeyboardModifierMask.leftControl
        _ = composer.process(modifiers(control, changed: control, device: keyboard))
        expect(
            composer.process(key(usage: 0x04, pressed: true, device: keyboard))
                == .action(
                    .command(usage: .keyboard(0x04), modifiers: control),
                    isRepeat: false
                ),
            "control shortcut inserted text"
        )
        _ = composer.process(key(usage: 0x04, pressed: false, device: keyboard))
        _ = composer.process(modifiers(.none, changed: control, device: keyboard))
        expect(
            composer.process(key(usage: 0x50, pressed: true, device: keyboard))
                == .action(.navigate(.left), isRepeat: false),
            "left navigation"
        )
        expect(
            composer.process(key(usage: 0x2a, pressed: true, device: keyboard))
                == .action(.deleteBackward, isRepeat: false),
            "backspace action"
        )
        expect(
            composer.process(
                key(
                    usage: 0x04,
                    pressed: true,
                    device: InputDeviceID(rawValue: 8)
                )
            ) == .ignored,
            "foreign keyboard changed composer"
        )
    }

    private static func boundedTextEditingIsDeterministic() {
        var bytes = [UInt8](repeating: 0, count: 3)
        bytes.withUnsafeMutableBytes { storage in
            var buffer = BoundedASCIITextBuffer(storage: storage)!
            expect(buffer.apply(.insertASCII(0x61)) == .changed, "insert a")
            expect(buffer.apply(.insertASCII(0x63)) == .changed, "insert c")
            expect(buffer.apply(.navigate(.left)) == .changed, "move left")
            expect(buffer.apply(.insertASCII(0x62)) == .changed, "insert b")
            expect(text(buffer.view) == "abc", "middle insertion")
            expect(
                buffer.apply(.insertASCII(0x64)) == .capacityExhausted,
                "full text buffer accepted insert"
            )
            expect(buffer.apply(.deleteBackward) == .changed, "backspace")
            expect(text(buffer.view) == "ac", "backspace result")
            expect(buffer.apply(.deleteForward) == .changed, "forward delete")
            expect(text(buffer.view) == "a", "forward delete result")
            expect(buffer.apply(.navigate(.home)) == .changed, "home")
            expect(buffer.apply(.deleteBackward) == .unchanged, "backspace at start")
            expect(buffer.apply(.navigate(.up)) == .notHandled, "vertical edit")
            buffer.clear()
            expect(buffer.view.byteCount == 0, "text clear")
        }
    }

    private static func windowRouterFocusesHitTestsAndCaptures() {
        var records = [UIWindowRecord](repeating: .vacant, count: 4)
        records.withUnsafeMutableBufferPointer { storage in
            let first = UIWindowID(rawValue: 1)!
            let second = UIWindowID(rawValue: 2)!
            var router = WindowInputRouter(
                windowStorage: storage,
                desktopBounds: Rectangle(x: 0, y: 0, width: 800, height: 600),
                initialCursorPosition: Point(x: 160, y: 160)
            )!
            expect(
                router.registerWindow(
                    identifier: first,
                    frame: Rectangle(x: 100, y: 100, width: 300, height: 300)
                ) == .applied,
                "register first window"
            )
            expect(
                router.registerWindow(
                    identifier: second,
                    frame: Rectangle(x: 150, y: 150, width: 300, height: 300)
                ) == .applied,
                "register second window"
            )
            expect(router.focusedWindowID == first, "initial focus changed")
            let down = pointerButton(pressed: true)
            guard case .routed(let pressed) = router.route(
                down,
                controlHitTest: controlForWindow
            ) else { fail("pointer press not routed") }
            expect(pressed.target?.window == second, "topmost hit window")
            expect(
                pressed.target?.control == UIControlID(rawValue: 102),
                "control hit test"
            )
            expect(router.focusedWindowID == second, "press did not focus")
            expect(router.cursor.capturedTarget == pressed.target, "no capture")

            let move = InputEvent.pointerMotion(
                timestampTicks: 2,
                deviceID: InputDeviceID(rawValue: 9),
                deltaX: 1_000,
                deltaY: 1_000
            )
            guard case .routed(let moved) = router.route(
                move,
                controlHitTest: controlForWindow
            ) else { fail("pointer move not routed") }
            expect(router.cursor.position.x == 799, "cursor x clamp")
            expect(router.cursor.position.y == 599, "cursor y clamp")
            expect(moved.target?.window == second, "capture lost outside window")

            guard case .routed(let released) = router.route(
                pointerButton(pressed: false),
                controlHitTest: controlForWindow
            ) else { fail("pointer release not routed") }
            expect(
                released.kind == .pointerButtonReleased(
                    button: 1,
                    isClick: false
                ),
                "outside release became click"
            )
            expect(router.cursor.capturedTarget == nil, "capture not released")

            _ = router.route(
                pointerButton(pressed: true),
                controlHitTest: controlForWindow
            )
            expect(router.focusedWindowID == nil, "desktop click kept focus")
            expect(
                router.registerWindow(
                    identifier: first,
                    frame: Rectangle(x: 0, y: 0, width: 10, height: 10)
                ) == .rejected(.duplicateIdentifier),
                "duplicate window accepted"
            )
            expect(
                router.updateFrame(
                    of: second,
                    to: Rectangle(x: 900, y: 900, width: 20, height: 20)
                ) == .rejected(.invalidFrame),
                "off-desktop window accepted"
            )
            expect(router.removeWindow(identifier: second) == .applied, "remove")
            expect(router.window(withID: second) == nil, "removed window visible")
        }
    }

    private static func fileManagerLayoutSharesHitGeometry() {
        let layout = FileManagerLayout(
            desktopBounds: Rectangle(x: 0, y: 0, width: 800, height: 600),
            windowFrame: Rectangle(x: 80, y: 70, width: 640, height: 460)
        )!
        expect(layout.rowCapacity == 12, "row capacity")
        expect(
            layout.hitTest(Point(x: 97, y: 85)) == .closeButton,
            "close hit"
        )
        expect(
            layout.hitTest(Point(x: 200, y: 90)) == .titleBar,
            "title hit"
        )
        let system = layout.sidebarItemFrame(at: 0)!
        expect(
            layout.hitTest(Point(x: system.x + 2, y: system.y + 2))
                == .sidebarSystem,
            "system sidebar hit"
        )
        let row = layout.listRowFrame(at: 3)!
        expect(
            layout.hitTest(Point(x: row.x + 2, y: row.y + 2)) == .listRow(3),
            "list row hit"
        )
        expect(
            layout.hitTest(Point(x: 80, y: 200)) == .resizeLeft,
            "resize edge hit"
        )
        expect(
            layout.cursorShape(for: .listRow(0)) == .pointingHand,
            "list cursor shape"
        )
        expect(
            layout.controlID(for: .listRow(3)) == UIControlID(rawValue: 1_003),
            "row control identity"
        )
        expect(
            FileManagerLayout(
                desktopBounds: Rectangle(x: 0, y: 0, width: 800, height: 600),
                windowFrame: Rectangle(x: 0, y: 0, width: 300, height: 200)
            ) == nil,
            "undersized layout accepted"
        )
    }

    private static func animationChannelsRetargetWithoutJumps() {
        var animation = FileManagerAnimationState(
            counterFrequency: 1_000,
            startingAt: 100
        )!
        expect(animation.sample(at: 100).windowOpacity == 0, "opening start")
        let openingMiddle = animation.sample(at: 200).windowOpacity
        expect(
            openingMiddle > 180 && openingMiddle < 200,
            "opening ease-out midpoint"
        )
        expect(animation.sample(at: 300).windowOpacity == 255, "opening end")
        expect(animation.sample(at: 100).cursorIsVisible, "cursor first phase")
        expect(!animation.sample(at: 600).cursorIsVisible, "cursor hidden phase")
        expect(animation.sample(at: 1_100).cursorIsVisible, "cursor wrap phase")

        animation.setSelectionVisible(true, at: 300)
        expect(animation.sample(at: 300).selectionOpacity == 0, "selection jump")
        expect(animation.sample(at: 425).selectionOpacity == 112, "selection end")

        animation.setHoverVisible(true, at: 300)
        let hoverMiddle = animation.sample(at: 350).hoverOpacity
        expect(hoverMiddle > 0 && hoverMiddle < 64, "hover midpoint")
        animation.setHoverVisible(false, at: 350)
        expect(
            animation.sample(at: 350).hoverOpacity == hoverMiddle,
            "hover retarget jumped"
        )
        expect(animation.sample(at: 450).hoverOpacity == 0, "hover reverse end")

        animation.setFocused(false, at: 300)
        expect(animation.sample(at: 300).focusOpacity == 255, "focus jump")
        expect(animation.sample(at: 425).focusOpacity == 0, "focus fade end")
        let advance = animation.advance(to: 1_100)
        expect(advance.framesDue > 0, "frame pacer did not advance")
        expect(advance.droppedFrames + 1 == advance.framesDue, "drop accounting")
    }

    private static func controlForWindow(
        _ window: UIWindowID,
        _ point: Point
    ) -> UIControlID? {
        _ = point
        return UIControlID(rawValue: 100 + window.rawValue)
    }

    private static func pointerButton(pressed: Bool) -> InputEvent {
        .pointerButton(
            timestampTicks: 1,
            deviceID: InputDeviceID(rawValue: 9),
            button: 1,
            isPressed: pressed
        )
    }

    private static func key(
        usage: UInt16,
        pressed: Bool,
        device: InputDeviceID
    ) -> InputEvent {
        .keyboardUsage(
            timestampTicks: 1,
            deviceID: device,
            usage: .keyboard(usage),
            isPressed: pressed
        )
    }

    private static func modifiers(
        _ current: KeyboardModifierMask,
        changed: KeyboardModifierMask,
        device: InputDeviceID
    ) -> InputEvent {
        .keyboardModifiers(
            timestampTicks: 1,
            deviceID: device,
            changed: changed,
            current: current
        )
    }

    private static func append(
        _ model: inout FileBrowserModel,
        name: String,
        id: UInt64,
        kind: VFSNodeKind
    ) -> FileBrowserAppendResult {
        withDirectoryEntry(name: name, id: id, kind: kind) {
            model.append($0)
        }
    }

    private static func expectAppend(
        _ model: inout FileBrowserModel,
        name: String,
        id: UInt64,
        kind: VFSNodeKind,
        size: UInt64
    ) {
        let result = withDirectoryEntry(name: name, id: id, kind: kind) {
            model.append(
                $0,
                metadata: metadata(id: id, kind: kind, size: size)
            )
        }
        guard case .inserted = result else {
            fail("append rejected for \(name): \(result)")
        }
    }

    private static func withDirectoryEntry<T>(
        name: String,
        id: UInt64,
        kind: VFSNodeKind,
        _ body: (VFSDirectoryEntry) -> T
    ) -> T {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBytes { raw in
            guard case .name(let nameView) = VFSNameValidator.validate(raw)
            else { fail("invalid test name") }
            return body(
                VFSDirectoryEntry(
                    identifier: node(id),
                    kind: kind,
                    name: nameView
                )
            )
        }
    }

    private static func metadata(
        id: UInt64,
        kind: VFSNodeKind,
        size: UInt64
    ) -> VFSNodeMetadata {
        let available: VFSAccessRights
        switch kind {
        case .directory:
            available = .enumerate.union(.traverse).union(.readMetadata)
        case .regularFile:
            available = .readData.union(.readMetadata)
        case .symbolicLink:
            available = .readMetadata
        case .device:
            available = .readData.union(.readMetadata)
        }
        let timestamp = VFSTimestamp(secondsSinceUnixEpoch: 1, nanoseconds: 0)!
        return VFSNodeMetadata(
            identifier: node(id),
            kind: kind,
            byteCount: size,
            linkCount: 1,
            generation: 1,
            createdAt: timestamp,
            modifiedAt: timestamp,
            availableAccess: available
        )!
    }

    private static func node(_ localValue: UInt64) -> VFSNodeIdentifier {
        VFSNodeIdentifier(
            volume: VFSVolumeIdentifier(rawValue: 1)!,
            localValue: localValue
        )!
    }

    private static func itemName(_ model: FileBrowserModel, _ index: Int) -> String {
        guard let item = model.item(at: index) else { fail("missing item") }
        var bytes = [UInt8]()
        var offset = 0
        while offset < item.name.byteCount {
            bytes.append(item.name.byte(at: offset)!)
            offset += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func text(_ view: BoundedASCIITextView) -> String {
        var bytes = [UInt8]()
        var index = 0
        while index < view.byteCount {
            bytes.append(view.byte(at: index)!)
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError(message)
    }
}
