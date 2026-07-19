@main
struct InputPrimitivesTests {
    static func main() {
        wireABIHasStableEncodingAndValidation()
        queuePreservesFIFOAcrossWraparound()
        queueDropsNewestWithSequenceLossAccounting()
        queueHandlesSequenceExhaustionInvalidEventsAndCorruption()
        keyboardEmitsDeterministicModifierAndUsageTransitions()
        keyboardRejectsRolloverAndMalformedReportsAtomically()
        keyboardAccountsForQueueOverflowAndDisconnects()
        mouseEmitsButtonsSignedMotionAndWheel()
        mouseRejectsMalformedReportsAndReleasesOnDisconnect()
        print("input primitives host tests: 9 groups passed")
    }

    private static func wireABIHasStableEncodingAndValidation() {
        let queued = QueuedInputEvent(
            sequence: 0x0102_0304_0506_0708,
            event: .pointerMotion(
                timestampTicks: 0x1112_1314_1516_1718,
                deviceID: InputDeviceID(rawValue: 0x2122_2324),
                deltaX: -2,
                deltaY: 0x0102_0304
            )
        )
        var bytes = [UInt8](
            repeating: 0xaa,
            count: InputEventWireCodec.recordByteCount
        )
        let encoded = bytes.withUnsafeMutableBytes {
            InputEventWireCodec.encode(queued, to: $0)
        }
        expect(encoded, "valid input event did not encode")
        expect(
            Array(bytes[0..<8]) == [
                0x53, 0x49, 0x4e, 0x50,
                0x01, 0x03, 0x02, 0x00,
            ],
            "input ABI header changed"
        )
        expect(
            Array(bytes[8..<16]) == [
                0x08, 0x07, 0x06, 0x05,
                0x04, 0x03, 0x02, 0x01,
            ],
            "input ABI sequence is not little-endian"
        )
        expect(
            Array(bytes[16..<24]) == [
                0x18, 0x17, 0x16, 0x15,
                0x14, 0x13, 0x12, 0x11,
            ],
            "input ABI timestamp is not little-endian"
        )
        expect(
            Array(bytes[24..<32]) == [
                0x24, 0x23, 0x22, 0x21,
                0x00, 0x00, 0x00, 0x00,
            ],
            "input ABI device/code fields changed"
        )
        expect(
            Array(bytes[32..<40]) == [
                0xfe, 0xff, 0xff, 0xff,
                0x04, 0x03, 0x02, 0x01,
            ],
            "input ABI signed values changed"
        )
        let decoded = bytes.withUnsafeBytes {
            InputEventWireCodec.decode(from: $0)
        }
        expect(decoded == queued, "input ABI record did not round trip")

        var corrupted = bytes
        corrupted[4] = 2
        expect(
            corrupted.withUnsafeBytes {
                InputEventWireCodec.decode(from: $0)
            } == nil,
            "unknown ABI version was accepted"
        )
        corrupted = bytes
        corrupted[5] = 0xff
        expect(
            corrupted.withUnsafeBytes {
                InputEventWireCodec.decode(from: $0)
            } == nil,
            "unknown input kind was accepted"
        )
        let truncated = Array(bytes.dropLast())
        expect(
            truncated.withUnsafeBytes {
                InputEventWireCodec.decode(from: $0)
            } == nil,
            "truncated input record was accepted"
        )

        let sync = QueuedInputEvent(
            sequence: 9,
            event: .synchronization(
                timestampTicks: 10,
                deviceID: .unknown
            )
        )
        expect(
            bytes.withUnsafeMutableBytes {
                InputEventWireCodec.encode(sync, to: $0)
            },
            "synchronization record was rejected"
        )
        expect(
            bytes.withUnsafeBytes {
                InputEventWireCodec.decode(from: $0)
            } == sync,
            "synchronization record did not round trip"
        )
    }

    private static func queuePreservesFIFOAcrossWraparound() {
        withQueueStorage(recordCount: 2, extraBytes: 17) { storage in
            guard var queue = InputEventQueue(
                storage: storage,
                firstSequence: 10
            ) else { fail("valid queue storage rejected") }
            expect(queue.capacity == 2, "partial record changed capacity")
            expect(
                queue.submit(motion(1)) == .enqueued(sequence: 10),
                "first queue sequence"
            )
            expect(
                queue.submit(motion(2)) == .enqueued(sequence: 11),
                "second queue sequence"
            )
            expect(dequeue(&queue) == entry(10, motion(1)), "first FIFO event")
            expect(
                queue.submit(motion(3)) == .enqueued(sequence: 12),
                "wrapped queue sequence"
            )
            expect(dequeue(&queue) == entry(11, motion(2)), "second FIFO event")
            expect(dequeue(&queue) == entry(12, motion(3)), "wrapped FIFO event")
            expect(queue.dequeue() == .empty, "empty queue was not empty")
            expect(
                queue.statistics == InputEventQueueStatistics(
                    capacity: 2,
                    retainedCount: 0,
                    nextSequence: 13,
                    enqueuedEventCount: 3,
                    dequeuedEventCount: 3,
                    capacityDropCount: 0,
                    sequenceExhaustionDropCount: 0,
                    invalidEventDropCount: 0,
                    corruptRecordCount: 0
                ),
                "wraparound queue statistics"
            )
            expect(!queue.statistics.didLoseEvents, "loss reported without loss")
        }

        let shortPointer = UnsafeMutableRawPointer.allocate(
            byteCount: InputEventWireCodec.recordByteCount - 1,
            alignment: 1
        )
        defer { shortPointer.deallocate() }
        expect(
            InputEventQueue(
                storage: UnsafeMutableRawBufferPointer(
                    start: shortPointer,
                    count: InputEventWireCodec.recordByteCount - 1
                )
            ) == nil,
            "short queue storage accepted"
        )
    }

    private static func queueDropsNewestWithSequenceLossAccounting() {
        withQueueStorage(recordCount: 2) { storage in
            var queue = InputEventQueue(
                storage: storage,
                firstSequence: 100
            )!
            expect(queue.submit(motion(1)) == .enqueued(sequence: 100), "q100")
            expect(queue.submit(motion(2)) == .enqueued(sequence: 101), "q101")
            expect(
                queue.submit(motion(3)) == .dropped(
                    sequence: 102,
                    reason: .capacityExhausted
                ),
                "full queue did not drop newest with a sequence"
            )
            expect(dequeue(&queue) == entry(100, motion(1)), "overflow displaced old")
            expect(
                queue.submit(motion(4)) == .enqueued(sequence: 103),
                "post-overflow sequence did not expose gap"
            )
            expect(dequeue(&queue) == entry(101, motion(2)), "q101 retained")
            expect(dequeue(&queue) == entry(103, motion(4)), "q103 retained")
            let statistics = queue.statistics
            expect(statistics.capacityDropCount == 1, "capacity loss count")
            expect(statistics.droppedEventCount == 1, "total drop count")
            expect(statistics.nextSequence == 104, "drop did not consume sequence")
            expect(statistics.didLoseEvents, "overflow loss flag")
        }
    }

    private static func queueHandlesSequenceExhaustionInvalidEventsAndCorruption() {
        withQueueStorage(recordCount: 1) { storage in
            var queue = InputEventQueue(
                storage: storage,
                firstSequence: UInt64.max
            )!
            expect(
                queue.submit(motion(1)) == .enqueued(sequence: UInt64.max),
                "maximum sequence was not accepted"
            )
            _ = queue.dequeue()
            expect(
                queue.submit(motion(2)) == .dropped(
                    sequence: nil,
                    reason: .sequenceExhausted
                ),
                "sequence wrap was accepted"
            )
            expect(queue.statistics.nextSequence == nil, "exhausted next sequence")
            expect(
                queue.statistics.sequenceExhaustionDropCount == 1,
                "sequence loss count"
            )
        }

        withQueueStorage(recordCount: 1) { storage in
            var queue = InputEventQueue(storage: storage)!
            let invalid = InputEvent.pointerButton(
                timestampTicks: 0,
                deviceID: .unknown,
                button: 0,
                isPressed: true
            )
            expect(
                queue.submit(invalid) == .dropped(
                    sequence: nil,
                    reason: .invalidEvent
                ),
                "invalid event entered queue"
            )
            expect(queue.nextSequence == 1, "invalid event consumed sequence")
            expect(queue.statistics.invalidEventDropCount == 1, "invalid loss count")
        }

        withQueueStorage(recordCount: 1) { storage in
            var queue = InputEventQueue(storage: storage)!
            _ = queue.submit(motion(9))
            storage[0] = 0
            expect(
                queue.dequeue() == .corruptRecordDiscarded,
                "corrupt queue record was returned or stalled"
            )
            expect(queue.isEmpty, "corrupt record was not discarded")
            expect(queue.statistics.corruptRecordCount == 1, "corrupt count")
            expect(queue.statistics.didLoseEvents, "corruption loss flag")
        }
    }

    private static func keyboardEmitsDeterministicModifierAndUsageTransitions() {
        var keyboard = USBHIDBootKeyboardStateMachine(
            deviceID: InputDeviceID(rawValue: 7)
        )
        var sink = CollectingInputSink()
        let first = keyboardReport(
            &keyboard,
            [0x02, 0, 0x05, 0x04, 0, 0, 0, 0],
            timestampTicks: 100,
            into: &sink
        )
        expect(
            first == .accepted(summary(attempted: 4, enqueued: 4)),
            "initial keyboard summary"
        )
        expect(sink.events.count == 4, "initial keyboard event count")
        expect(sink.events[0].kind == .keyboardModifiers, "modifier not first")
        guard let modifier = sink.events[0].modifierTransition else {
            fail("modifier transition missing")
        }
        expect(modifier.changed == .leftShift, "modifier changed mask")
        expect(modifier.current == .leftShift, "modifier current mask")
        expectUsage(sink.events[1], usage: 4, pressed: true)
        expectUsage(sink.events[2], usage: 5, pressed: true)
        expect(sink.events[3].kind == .synchronization, "keyboard sync missing")
        expect(keyboard.currentModifiers == .leftShift, "modifier state")
        expect(keyboard.isUsagePressed(4), "A not retained")
        expect(keyboard.isUsagePressed(5), "B not retained")

        let reordered = keyboardReport(
            &keyboard,
            [0x02, 0, 0x04, 0x05, 0, 0, 0, 0],
            timestampTicks: 101,
            into: &sink
        )
        expect(
            reordered == .accepted(InputEmissionSummary()),
            "slot reorder generated transitions"
        )
        expect(sink.events.count == 4, "slot reorder emitted events")

        let swappedModifier = keyboardReport(
            &keyboard,
            [0x10, 0, 0x04, 0x05, 0, 0, 0, 0],
            timestampTicks: 102,
            into: &sink
        )
        expect(
            swappedModifier == .accepted(summary(attempted: 2, enqueued: 2)),
            "modifier swap summary"
        )
        guard let modifierSwap = sink.events[4].modifierTransition else {
            fail("modifier swap missing")
        }
        expect(
            modifierSwap.changed.rawValue == 0x12,
            "modifier swap changed mask"
        )
        expect(modifierSwap.current == .rightControl, "modifier swap current")
        expect(sink.events[5].kind == .synchronization, "modifier swap sync")

        let changed = keyboardReport(
            &keyboard,
            [0x10, 0, 0x06, 0x04, 0, 0, 0, 0],
            timestampTicks: 103,
            into: &sink
        )
        expect(
            changed == .accepted(summary(attempted: 3, enqueued: 3)),
            "keyboard replacement summary"
        )
        expectUsage(sink.events[6], usage: 5, pressed: false)
        expectUsage(sink.events[7], usage: 6, pressed: true)
        expect(sink.events[8].kind == .synchronization, "replacement sync")

        let released = keyboardReport(
            &keyboard,
            [0, 0, 0, 0, 0, 0, 0, 0],
            timestampTicks: 104,
            into: &sink
        )
        expect(
            released == .accepted(summary(attempted: 4, enqueued: 4)),
            "keyboard release summary"
        )
        expectUsage(sink.events[9], usage: 4, pressed: false)
        expectUsage(sink.events[10], usage: 6, pressed: false)
        guard let modifierRelease = sink.events[11].modifierTransition else {
            fail("modifier release missing")
        }
        expect(
            modifierRelease.changed == .rightControl,
            "released modifier changed"
        )
        expect(modifierRelease.current == .none, "released modifier current")
        expect(sink.events[12].kind == .synchronization, "release sync")
    }

    private static func keyboardRejectsRolloverAndMalformedReportsAtomically() {
        var keyboard = USBHIDBootKeyboardStateMachine(
            deviceID: InputDeviceID(rawValue: 8)
        )
        var sink = CollectingInputSink()
        expect(
            keyboardReport(
                &keyboard,
                [0, 0, 4, 0, 0, 0, 0, 0],
                timestampTicks: 1,
                into: &sink
            ) == .accepted(summary(attempted: 2, enqueued: 2)),
            "keyboard setup report"
        )
        expect(sink.events.count == 2, "keyboard setup event count")

        expect(
            keyboardReport(
                &keyboard,
                [0, 0, 1, 5, 0, 0, 0, 0],
                timestampTicks: 2,
                into: &sink
            ) == .rollover,
            "rollover report not identified"
        )
        expect(
            keyboardReport(
                &keyboard,
                [0, 1, 5, 0, 0, 0, 0, 0],
                timestampTicks: 3,
                into: &sink
            ) == .malformed(.nonzeroReservedByte),
            "reserved byte report accepted"
        )
        expect(
            keyboardReport(
                &keyboard,
                [0, 0, 5, 5, 0, 0, 0, 0],
                timestampTicks: 4,
                into: &sink
            ) == .malformed(.duplicateKeyUsage),
            "duplicate usage report accepted"
        )
        expect(
            keyboardReport(
                &keyboard,
                [0, 0, 0xe1, 0, 0, 0, 0, 0],
                timestampTicks: 5,
                into: &sink
            ) == .malformed(.modifierInKeyArray),
            "modifier key-array report accepted"
        )
        expect(
            keyboardReport(
                &keyboard,
                [0, 0, 0xe8, 0, 0, 0, 0, 0],
                timestampTicks: 6,
                into: &sink
            ) == .malformed(.invalidKeyUsage),
            "reserved usage report accepted"
        )
        expect(
            keyboardReport(
                &keyboard,
                [0, 0, 0],
                timestampTicks: 7,
                into: &sink
            ) == .malformed(.invalidLength),
            "short keyboard report accepted"
        )
        expect(sink.events.count == 2, "rejected report emitted phantom events")
        expect(keyboard.isUsagePressed(4), "rejected report mutated key state")

        expect(
            keyboardReport(
                &keyboard,
                [0, 0, 0, 0, 0, 0, 0, 0],
                timestampTicks: 8,
                into: &sink
            ) == .accepted(summary(attempted: 2, enqueued: 2)),
            "post-error release summary"
        )
        expectUsage(sink.events[2], usage: 4, pressed: false)
        expect(sink.events[3].kind == .synchronization, "post-error sync")
        expect(
            sink.events.allSatisfy { event in
                event.keyboardUsage?.usage != 5
            },
            "rejected report created a phantom B transition"
        )
    }

    private static func keyboardAccountsForQueueOverflowAndDisconnects() {
        withQueueStorage(recordCount: 1) { storage in
            var queue = InputEventQueue(storage: storage)!
            var keyboard = USBHIDBootKeyboardStateMachine(
                deviceID: InputDeviceID(rawValue: 9)
            )
            expect(
                keyboardReport(
                    &keyboard,
                    [0x02, 0, 4, 0, 0, 0, 0, 0],
                    timestampTicks: 20,
                    into: &queue
                ) == .accepted(
                    summary(attempted: 3, enqueued: 1, dropped: 2)
                ),
                "keyboard overflow summary"
            )
            expect(queue.statistics.capacityDropCount == 2, "keyboard drops")
            expect(keyboard.currentModifiers == .leftShift, "overflow state modifier")
            expect(keyboard.isUsagePressed(4), "overflow state key")
            let first = dequeue(&queue)
            expect(first.sequence == 1, "first keyboard queue sequence")
            expect(first.event.kind == .keyboardModifiers, "modifier queue order")

            expect(
                keyboardReport(
                    &keyboard,
                    [0x02, 0, 4, 0, 0, 0, 0, 0],
                    timestampTicks: 21,
                    into: &queue
                ) == .accepted(InputEmissionSummary()),
                "unchanged report repeated dropped transitions"
            )
            expect(
                keyboard.releaseAll(timestampTicks: 22, into: &queue)
                    == summary(attempted: 3, enqueued: 1, dropped: 2),
                "keyboard disconnect overflow summary"
            )
            let release = dequeue(&queue)
            expect(release.sequence == 4, "overflow gaps not preserved")
            expectUsage(release.event, usage: 4, pressed: false)
            expect(queue.statistics.capacityDropCount == 4, "disconnect drops")
            expect(
                keyboard.releaseAll(timestampTicks: 23, into: &queue)
                    == InputEmissionSummary(),
                "keyboard disconnect was not idempotent"
            )
        }
    }

    private static func mouseEmitsButtonsSignedMotionAndWheel() {
        var mouse = USBHIDBootMouseStateMachine(
            deviceID: InputDeviceID(rawValue: 10)
        )
        var sink = CollectingInputSink()
        expect(
            mouseReport(
                &mouse,
                [0b0000_0101, 0xfe, 0x7f, 0xff],
                timestampTicks: 30,
                into: &sink
            ) == .accepted(summary(attempted: 5, enqueued: 5)),
            "initial mouse summary"
        )
        expectButton(sink.events[0], button: 1, pressed: true)
        expectButton(sink.events[1], button: 3, pressed: true)
        expectMotion(sink.events[2], deltaX: -2, deltaY: 127)
        expectScroll(sink.events[3], vertical: -1, horizontal: 0)
        expect(sink.events[4].kind == .synchronization, "mouse sync")
        expect(mouse.currentButtons == 0b0000_0101, "mouse button state")

        expect(
            mouseReport(
                &mouse,
                [0b0000_0101, 0, 0, 0],
                timestampTicks: 31,
                into: &sink
            ) == .accepted(InputEmissionSummary()),
            "stationary mouse emitted events"
        )

        expect(
            mouseReport(
                &mouse,
                [0b0000_0010, 0x80, 0, 1],
                timestampTicks: 32,
                into: &sink
            ) == .accepted(summary(attempted: 6, enqueued: 6)),
            "mouse transition summary"
        )
        expectButton(sink.events[5], button: 1, pressed: false)
        expectButton(sink.events[6], button: 2, pressed: true)
        expectButton(sink.events[7], button: 3, pressed: false)
        expectMotion(sink.events[8], deltaX: -128, deltaY: 0)
        expectScroll(sink.events[9], vertical: 1, horizontal: 0)
        expect(sink.events[10].kind == .synchronization, "mouse transition sync")
    }

    private static func mouseRejectsMalformedReportsAndReleasesOnDisconnect() {
        var mouse = USBHIDBootMouseStateMachine(
            deviceID: InputDeviceID(rawValue: 11)
        )
        var sink = CollectingInputSink()
        _ = mouseReport(
            &mouse,
            [0b0000_0010, 0, 0],
            timestampTicks: 40,
            into: &sink
        )
        expect(sink.events.count == 2, "mouse setup event count")
        expect(
            mouseReport(
                &mouse,
                [0, 0],
                timestampTicks: 41,
                into: &sink
            ) == .malformed(.invalidLength),
            "short mouse report accepted"
        )
        expect(
            mouseReport(
                &mouse,
                [0, 0, 0, 0, 0],
                timestampTicks: 42,
                into: &sink
            ) == .malformed(.invalidLength),
            "long mouse report accepted"
        )
        expect(mouse.currentButtons == 0b0000_0010, "bad report mutated buttons")
        expect(sink.events.count == 2, "bad mouse report emitted events")

        expect(
            mouse.releaseAll(timestampTicks: 43, into: &sink)
                == summary(attempted: 2, enqueued: 2),
            "mouse disconnect summary"
        )
        expectButton(sink.events[2], button: 2, pressed: false)
        expect(sink.events[3].kind == .synchronization, "mouse disconnect sync")
        expect(
            mouse.releaseAll(timestampTicks: 44, into: &sink)
                == InputEmissionSummary(),
            "mouse disconnect was not idempotent"
        )

        expect(
            mouseReport(
                &mouse,
                [0, 1, 0xff],
                timestampTicks: 45,
                into: &sink
            ) == .accepted(summary(attempted: 2, enqueued: 2)),
            "three-byte boot mouse report rejected"
        )
        expectMotion(sink.events[4], deltaX: 1, deltaY: -1)
        expect(sink.events[5].kind == .synchronization, "three-byte mouse sync")
    }

    private static func motion(_ x: Int32) -> InputEvent {
        .pointerMotion(
            timestampTicks: UInt64(UInt32(bitPattern: x)),
            deviceID: InputDeviceID(rawValue: 1),
            deltaX: x,
            deltaY: 0
        )
    }

    private static func entry(_ sequence: UInt64, _ event: InputEvent) -> QueuedInputEvent {
        QueuedInputEvent(sequence: sequence, event: event)
    }

    private static func dequeue(_ queue: inout InputEventQueue) -> QueuedInputEvent {
        guard case .event(let event) = queue.dequeue() else {
            fail("expected queued input event")
        }
        return event
    }

    private static func summary(
        attempted: Int,
        enqueued: Int,
        dropped: Int = 0
    ) -> InputEmissionSummary {
        var result = InputEmissionSummary()
        var sequence: UInt64 = 1
        var index = 0
        while index < enqueued {
            result.record(.enqueued(sequence: sequence))
            sequence += 1
            index += 1
        }
        while index < attempted {
            result.record(
                .dropped(sequence: sequence, reason: .capacityExhausted)
            )
            sequence += 1
            index += 1
        }
        expect(result.droppedCount == dropped, "test summary mismatch")
        return result
    }

    private static func keyboardReport<S: InputEventSink>(
        _ keyboard: inout USBHIDBootKeyboardStateMachine,
        _ report: [UInt8],
        timestampTicks: UInt64,
        into sink: inout S
    ) -> HIDBootReportResult {
        report.withUnsafeBytes {
            keyboard.processReport(
                $0,
                timestampTicks: timestampTicks,
                into: &sink
            )
        }
    }

    private static func mouseReport<S: InputEventSink>(
        _ mouse: inout USBHIDBootMouseStateMachine,
        _ report: [UInt8],
        timestampTicks: UInt64,
        into sink: inout S
    ) -> HIDBootReportResult {
        report.withUnsafeBytes {
            mouse.processReport(
                $0,
                timestampTicks: timestampTicks,
                into: &sink
            )
        }
    }

    private static func expectUsage(
        _ event: InputEvent,
        usage: UInt16,
        pressed: Bool
    ) {
        expect(event.kind == .keyboardUsage, "expected keyboard usage event")
        expect(event.keyboardUsage == .keyboard(usage), "keyboard usage value")
        expect(event.isPressed == pressed, "keyboard usage transition")
    }

    private static func expectButton(
        _ event: InputEvent,
        button: UInt32,
        pressed: Bool
    ) {
        expect(event.kind == .pointerButton, "expected pointer button event")
        expect(event.code == button, "pointer button number")
        expect(event.isPressed == pressed, "pointer button transition")
    }

    private static func expectMotion(
        _ event: InputEvent,
        deltaX: Int32,
        deltaY: Int32
    ) {
        expect(event.kind == .pointerMotion, "expected pointer motion event")
        expect(event.flags == .relative, "pointer motion was not relative")
        expect(event.value0 == deltaX, "pointer X delta")
        expect(event.value1 == deltaY, "pointer Y delta")
    }

    private static func expectScroll(
        _ event: InputEvent,
        vertical: Int32,
        horizontal: Int32
    ) {
        expect(event.kind == .pointerScroll, "expected pointer scroll event")
        expect(event.flags == .relative, "pointer scroll was not relative")
        expect(event.value0 == vertical, "vertical wheel delta")
        expect(event.value1 == horizontal, "horizontal wheel delta")
    }

    private static func withQueueStorage(
        recordCount: Int,
        extraBytes: Int = 0,
        _ body: (UnsafeMutableRawBufferPointer) -> Void
    ) {
        let byteCount = recordCount * InputEventWireCodec.recordByteCount
            + extraBytes
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 1
        )
        defer { pointer.deallocate() }
        body(UnsafeMutableRawBufferPointer(start: pointer, count: byteCount))
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}

private struct CollectingInputSink: InputEventSink {
    private(set) var events: [InputEvent] = []
    private var nextSequence: UInt64 = 1

    mutating func submit(_ event: InputEvent) -> InputEventSubmissionResult {
        events.append(event)
        let sequence = nextSequence
        nextSequence += 1
        return .enqueued(sequence: sequence)
    }
}
