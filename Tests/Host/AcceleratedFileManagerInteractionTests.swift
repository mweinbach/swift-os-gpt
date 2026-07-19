@main
struct AcceleratedFileManagerInteractionTests {
    static func main() {
        pointerRoutingSelectsVisibleRows()
        scaledPointerMotionRetainsSubpixelRemainders()
        keyboardNavigationAndTypeaheadAreDeterministic()
        animationAndInvalidationRemainPaced()
        directoryLoadingRestartsAndCopiesBorrowedNames()
        print("Accelerated file-manager interaction: 5 groups passed")
    }

    private static func scaledPointerMotionRetainsSubpixelRemainders() {
        withState(pointerScale: 3) { state in
            let origin = state.router.cursor.position
            state.accept(
                .pointerMotion(
                    timestampTicks: 1,
                    deviceID: InputDeviceID(rawValue: 2),
                    deltaX: 2,
                    deltaY: -2
                )
            )
            expect(
                state.router.cursor.position.x == origin.x
                    && state.router.cursor.position.y == origin.y,
                "fractional physical motion moved the logical cursor"
            )
            state.accept(
                .pointerMotion(
                    timestampTicks: 2,
                    deviceID: InputDeviceID(rawValue: 2),
                    deltaX: 2,
                    deltaY: -2
                )
            )
            expect(
                state.router.cursor.position.x == origin.x + 1
                    && state.router.cursor.position.y == origin.y - 1,
                "scaled pointer remainder was not retained"
            )
        }
    }

    private static func pointerRoutingSelectsVisibleRows() {
        withState { state in
            append(&state, name: "Alpha", id: 1, kind: .regularFile)
            append(&state, name: "Beta", id: 2, kind: .regularFile)
            state.accept(
                .pointerMotion(
                    timestampTicks: 1,
                    deviceID: InputDeviceID(rawValue: 2),
                    deltaX: -100,
                    deltaY: -150
                )
            )
            expect(state.hoveredVisibleRow == 1, "row hover was not routed")
            expect(
                state.router.cursor.shape == .pointingHand,
                "row cursor shape"
            )
            state.accept(pointerButton(pressed: true, timestamp: 2))
            state.accept(pointerButton(pressed: false, timestamp: 3))
            expect(
                state.browser.selectedItem?.identifier.localValue == 2,
                "row click did not select Beta"
            )
            expect(
                state.router.cursor.capturedTarget == nil,
                "pointer capture survived release"
            )
        }
    }

    private static func keyboardNavigationAndTypeaheadAreDeterministic() {
        withState { state in
            append(&state, name: "Alpha", id: 1, kind: .regularFile)
            append(&state, name: "Beta", id: 2, kind: .regularFile)
            append(&state, name: "Gamma", id: 3, kind: .regularFile)
            state.accept(key(usage: 0x51, pressed: true, timestamp: 10))
            state.accept(key(usage: 0x51, pressed: false, timestamp: 11))
            expect(
                state.browser.selectedItem?.identifier.localValue == 2,
                "down key did not move selection"
            )
            state.accept(key(usage: 0x0a, pressed: true, timestamp: 12))
            expect(
                state.browser.selectedItem?.identifier.localValue == 3,
                "typeahead did not select Gamma"
            )
            state.accept(key(usage: 0x0a, pressed: true, timestamp: 13))
            expect(
                state.browser.selectedItem?.identifier.localValue == 3,
                "repeated printable key changed typeahead selection"
            )
            state.accept(key(usage: 0x0a, pressed: false, timestamp: 14))
        }
    }

    private static func animationAndInvalidationRemainPaced() {
        withState { state in
            append(&state, name: "Alpha", id: 1, kind: .regularFile)
            expect(state.needsPresentation, "initial frame was not dirty")
            state.markPresented()
            expect(!state.needsPresentation, "present did not clear dirty bit")
            let idle = state.advanceAnimations(to: 10)
            expect(idle.framesDue == 0, "animation frame arrived too early")
            let due = state.advanceAnimations(to: 20)
            expect(due.framesDue == 1, "animation frame was not paced")
            expect(due.sample.windowOpacity > 0, "opening animation did not move")
            expect(
                state.animationNeedsPresentation,
                "opening transition retired before its final frame"
            )
            _ = state.advanceAnimations(to: 200)
            state.markPresented()
            expect(
                !state.animationNeedsPresentation,
                "completed transition kept requesting frames"
            )
        }
    }

    private static func directoryLoadingRestartsAndCopiesBorrowedNames() {
        withState { state in
            var provider = TestDirectoryProvider()
            var scratch = [UInt8](repeating: 0, count: 255)
            let result = scratch.withUnsafeMutableBytes { nameScratch in
                FileManagerDirectoryLoader.load(
                    interaction: &state,
                    provider: &provider,
                    root: provider.root,
                    nameScratch: nameScratch
                )
            }
            expect(result == .loaded(entryCount: 2), "directory load failed")
            expect(provider.readCount == 4, "stale enumeration did not restart")
            _ = scratch.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
            expect(
                state.browser.item(at: 0).map {
                    name($0.name, equals: "Alpha")
                } == true,
                "first sorted name was not copied from provider scratch"
            )
            expect(
                state.browser.item(at: 1).map {
                    name($0.name, equals: "Beta")
                } == true,
                "second sorted name was not copied from provider scratch"
            )
        }
    }

    private static func withState(
        pointerScale: Int = 1,
        _ body: (inout AcceleratedFileManagerInteractionState) -> Void
    ) {
        var entries = [FileBrowserEntryRecord](repeating: .vacant, count: 8)
        var names = [UInt8](repeating: 0, count: 512)
        var windows = [UIWindowRecord](repeating: .vacant, count: 2)
        var typeahead = [UInt8](repeating: 0, count: 32)
        entries.withUnsafeMutableBufferPointer { entryStorage in
            names.withUnsafeMutableBytes { nameStorage in
                windows.withUnsafeMutableBufferPointer { windowStorage in
                    typeahead.withUnsafeMutableBytes { typeaheadStorage in
                        let layout = FileManagerLayout(
                            desktopBounds: Rectangle(
                                x: 0,
                                y: 0,
                                width: 800,
                                height: 600
                            ),
                            windowFrame: Rectangle(
                                x: 80,
                                y: 70,
                                width: 640,
                                height: 460
                            )
                        )!
                        var state = AcceleratedFileManagerInteractionState(
                            entryStorage: entryStorage,
                            nameStorage: nameStorage,
                            windowStorage: windowStorage,
                            typeaheadStorage: typeaheadStorage,
                            layout: layout,
                            counterFrequency: 1_000,
                            startingAt: 0,
                            pointerScale: pointerScale
                        )!
                        body(&state)
                    }
                }
            }
        }
    }

    private static func name(
        _ name: FileBrowserNameView,
        equals expected: String
    ) -> Bool {
        let bytes = Array(expected.utf8)
        guard name.byteCount == bytes.count else { return false }
        var index = 0
        while index < bytes.count {
            if name.byte(at: index) != bytes[index] { return false }
            index += 1
        }
        return true
    }

    private static func append(
        _ state: inout AcceleratedFileManagerInteractionState,
        name: String,
        id: UInt64,
        kind: VFSNodeKind
    ) {
        let bytes = Array(name.utf8)
        bytes.withUnsafeBytes { raw in
            guard case .name(let name) = VFSNameValidator.validate(raw),
                  let identifier = VFSNodeIdentifier(
                      volume: VFSVolumeIdentifier(rawValue: 1)!,
                      localValue: id
                  ), let timestamp = VFSTimestamp(
                      secondsSinceUnixEpoch: 0,
                      nanoseconds: 0
                  ), let metadata = VFSNodeMetadata(
                      identifier: identifier,
                      kind: kind,
                      byteCount: 10,
                      linkCount: 1,
                      generation: 1,
                      createdAt: timestamp,
                      modifiedAt: timestamp,
                      availableAccess: kind == .directory
                        ? .enumerate.union(.traverse)
                        : .readData
                  )
            else {
                fail("test metadata")
            }
            guard case .inserted = state.append(
                      VFSDirectoryEntry(
                          identifier: identifier,
                          kind: kind,
                          name: name
                      ),
                      metadata: metadata
                  )
            else {
                fail("append rejected")
            }
        }
    }

    private static func pointerButton(
        pressed: Bool,
        timestamp: UInt64
    ) -> InputEvent {
        .pointerButton(
            timestampTicks: timestamp,
            deviceID: InputDeviceID(rawValue: 2),
            button: 1,
            isPressed: pressed
        )
    }

    private static func key(
        usage: UInt16,
        pressed: Bool,
        timestamp: UInt64
    ) -> InputEvent {
        .keyboardUsage(
            timestampTicks: timestamp,
            deviceID: InputDeviceID(rawValue: 7),
            usage: .keyboard(usage),
            isPressed: pressed
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        print("FAIL:", message)
        fatalError()
    }
}

private struct TestDirectoryProvider: VFSNodeProvider {
    let volumeIdentifier = VFSVolumeIdentifier(rawValue: 7)!
    private(set) var readCount = 0
    private var hasReturnedStaleCookie = false

    var root: VFSNodeIdentifier {
        VFSNodeIdentifier(volume: volumeIdentifier, localValue: 1)!
    }

    mutating func metadata(for node: VFSNodeIdentifier) -> VFSMetadataResult {
        guard node.volume == volumeIdentifier,
              node.localValue == 2 || node.localValue == 3,
              let timestamp = VFSTimestamp(
                  secondsSinceUnixEpoch: 0,
                  nanoseconds: 0
              ), let metadata = VFSNodeMetadata(
                  identifier: node,
                  kind: .regularFile,
                  byteCount: node.localValue * 10,
                  linkCount: 1,
                  generation: 1,
                  createdAt: timestamp,
                  modifiedAt: timestamp,
                  availableAccess: .readData
              )
        else {
            return .failure(.notFound)
        }
        return .metadata(metadata)
    }

    mutating func lookup(
        parent: VFSNodeIdentifier,
        name: VFSNameView
    ) -> VFSLookupResult {
        .failure(.notFound)
    }

    mutating func readDirectory(
        node: VFSNodeIdentifier,
        after cookie: VFSDirectoryCookie,
        nameOutput: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult {
        readCount += 1
        guard node == root else { return .failure(.notFound) }
        if !hasReturnedStaleCookie {
            hasReturnedStaleCookie = true
            return .staleCookie
        }
        switch cookie.rawValue {
        case 0:
            return entry(
                name: "Beta",
                localIdentifier: 3,
                nextCookie: 1,
                output: nameOutput
            )
        case 1:
            return entry(
                name: "Alpha",
                localIdentifier: 2,
                nextCookie: 2,
                output: nameOutput
            )
        default:
            return .end
        }
    }

    mutating func read(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSDataIOResult {
        .failure(.ioFailure)
    }

    mutating func write(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> VFSDataIOResult {
        .failure(.ioFailure)
    }

    private func entry(
        name: String,
        localIdentifier: UInt64,
        nextCookie: UInt64,
        output: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult {
        let bytes = Array(name.utf8)
        guard bytes.count <= output.count else {
            return .nameBufferTooSmall(requiredByteCount: bytes.count)
        }
        var index = 0
        while index < bytes.count {
            output[index] = bytes[index]
            index += 1
        }
        let borrowed = UnsafeRawBufferPointer(
            start: output.baseAddress,
            count: bytes.count
        )
        guard case .name(let validatedName) = VFSNameValidator.validate(borrowed),
              let identifier = VFSNodeIdentifier(
                  volume: volumeIdentifier,
                  localValue: localIdentifier
              )
        else {
            return .failure(.corrupt)
        }
        return .entry(
            VFSDirectoryEntry(
                identifier: identifier,
                kind: .regularFile,
                name: validatedName
            ),
            nextCookie: VFSDirectoryCookie(rawValue: nextCookie)
        )
    }
}
