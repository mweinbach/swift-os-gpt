private struct InputDispatchTestRecorder {
    var callCount: UInt32 = 0
    var event: InputEvent?
}

private nonisolated(unsafe) var selfRemovingCallCount: UInt32 = 0

@_cdecl("swiftos_test_record_synchronous_input_event")
private func recordSynchronousInputEvent(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeRawPointer
) {
    guard let context else {
        fatalError("input dispatch omitted recorder context")
    }
    let recorder = context.assumingMemoryBound(
        to: InputDispatchTestRecorder.self
    )
    recorder.pointee.callCount += 1
    recorder.pointee.event = event.assumingMemoryBound(to: InputEvent.self)
        .pointee
}

@_cdecl("swiftos_test_remove_synchronous_input_handler")
private func removeSynchronousInputHandler(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeRawPointer
) {
    _ = context
    _ = event
    selfRemovingCallCount += 1
    SynchronousInputEventDispatcher.uninstall()
}

@main
struct SynchronousInputEventDispatchTests {
    static func main() {
        noHandlerIsInert()
        dispatchIsSynchronousAndPreservesTheEvent()
        invalidEventsNeverReachTheHandler()
        aHandlerCanRemoveItselfForSubsequentEvents()
        print("synchronous input dispatch host tests: 4 groups passed")
    }

    private static func noHandlerIsInert() {
        SynchronousInputEventDispatcher.uninstall()
        expect(!SynchronousInputEventDispatcher.hasHandler, "stale handler")
        expect(
            SynchronousInputEventDispatcher.dispatch(event(timestamp: 1))
                == .noHandler,
            "handlerless event was reported delivered"
        )
    }

    private static func dispatchIsSynchronousAndPreservesTheEvent() {
        var recorder = InputDispatchTestRecorder()
        withUnsafeMutablePointer(to: &recorder) { pointer in
            SynchronousInputEventDispatcher.install(
                recordSynchronousInputEvent,
                context: UnsafeMutableRawPointer(pointer)
            )
            let submitted = event(timestamp: 0x1122_3344_5566_7788)
            expect(
                SynchronousInputEventDispatcher.dispatch(submitted)
                    == .delivered,
                "valid event was not delivered"
            )
            expect(
                pointer.pointee.callCount == 1,
                "handler did not complete inline"
            )
            expect(
                pointer.pointee.event == submitted,
                "event payload changed"
            )
        }
        SynchronousInputEventDispatcher.uninstall()
    }

    private static func invalidEventsNeverReachTheHandler() {
        var recorder = InputDispatchTestRecorder()
        withUnsafeMutablePointer(to: &recorder) { pointer in
            SynchronousInputEventDispatcher.install(
                recordSynchronousInputEvent,
                context: UnsafeMutableRawPointer(pointer)
            )
            let invalid = InputEvent.keyboardModifiers(
                timestampTicks: 9,
                deviceID: InputDeviceID(rawValue: 2),
                changed: .none,
                current: .leftShift
            )
            expect(
                SynchronousInputEventDispatcher.dispatch(invalid)
                    == .invalidEvent,
                "malformed canonical event was accepted"
            )
            expect(
                pointer.pointee.callCount == 0,
                "invalid event reached handler"
            )
        }
        SynchronousInputEventDispatcher.uninstall()
    }

    private static func aHandlerCanRemoveItselfForSubsequentEvents() {
        selfRemovingCallCount = 0
        SynchronousInputEventDispatcher.install(
            removeSynchronousInputHandler
        )
        expect(
            SynchronousInputEventDispatcher.dispatch(event(timestamp: 10))
                == .delivered,
            "self-removing handler did not receive event"
        )
        expect(selfRemovingCallCount == 1, "handler call count")
        expect(!SynchronousInputEventDispatcher.hasHandler, "handler remained")
        expect(
            SynchronousInputEventDispatcher.dispatch(event(timestamp: 11))
                == .noHandler,
            "removed handler received another event"
        )
        expect(selfRemovingCallCount == 1, "removed handler ran twice")
    }

    private static func event(timestamp: UInt64) -> InputEvent {
        InputEvent.pointerMotion(
            timestampTicks: timestamp,
            deviceID: InputDeviceID(rawValue: 7),
            deltaX: 37,
            deltaY: -19
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("synchronous input dispatch failed: \(message)")
        }
    }
}
