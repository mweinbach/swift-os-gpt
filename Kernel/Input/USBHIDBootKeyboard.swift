/// Allocation-free decoder for the USB HID boot-keyboard eight-byte report.
/// Parsing completes before any state mutation or sink call, so a malformed or
/// rollover report cannot create partial or phantom transitions.
struct USBHIDBootKeyboardStateMachine {
    static let reportByteCount = 8

    let deviceID: InputDeviceID
    private(set) var currentModifiers = KeyboardModifierMask.none
    private var pressedKeys = HIDBootKeyboardKeys()

    init(deviceID: InputDeviceID) {
        self.deviceID = deviceID
    }

    mutating func processReport<S: InputEventSink>(
        _ bytes: UnsafeRawBufferPointer,
        timestampTicks: UInt64,
        into sink: inout S
    ) -> HIDBootReportResult {
        switch Self.parse(bytes) {
        case .rollover:
            return .rollover
        case .malformed(let error):
            return .malformed(error)
        case .accepted(let report):
            var summary = InputEmissionSummary()
            emitTransition(
                to: report,
                timestampTicks: timestampTicks,
                into: &sink,
                summary: &summary
            )
            emitSynchronizationIfNeeded(
                timestampTicks: timestampTicks,
                into: &sink,
                summary: &summary
            )
            pressedKeys = report.keys
            currentModifiers = KeyboardModifierMask(
                rawValue: report.modifiers
            )
            return .accepted(summary)
        }
    }

    /// Releases every retained key and modifier when a transport disconnects
    /// or resets. Calling it again is a no-op, so teardown is idempotent.
    mutating func releaseAll<S: InputEventSink>(
        timestampTicks: UInt64,
        into sink: inout S
    ) -> InputEmissionSummary {
        var summary = InputEmissionSummary()
        var rawUsage: UInt16 = 4
        while rawUsage <= 0xdf {
            let usage = UInt8(truncatingIfNeeded: rawUsage)
            if pressedKeys.contains(usage) {
                emit(
                    .keyboardUsage(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        usage: .keyboard(rawUsage),
                        isPressed: false
                    ),
                    into: &sink,
                    summary: &summary
                )
            }
            rawUsage += 1
        }
        if currentModifiers != .none {
            emit(
                .keyboardModifiers(
                    timestampTicks: timestampTicks,
                    deviceID: deviceID,
                    changed: currentModifiers,
                    current: .none
                ),
                into: &sink,
                summary: &summary
            )
        }
        emitSynchronizationIfNeeded(
            timestampTicks: timestampTicks,
            into: &sink,
            summary: &summary
        )
        pressedKeys = HIDBootKeyboardKeys()
        currentModifiers = .none
        return summary
    }

    func isUsagePressed(_ usage: UInt16) -> Bool {
        guard usage >= 4, usage <= 0xdf else { return false }
        return pressedKeys.contains(UInt8(truncatingIfNeeded: usage))
    }

    private mutating func emitTransition<S: InputEventSink>(
        to report: HIDBootKeyboardReport,
        timestampTicks: UInt64,
        into sink: inout S,
        summary: inout InputEmissionSummary
    ) {
        // Key releases precede a modifier release, while a modifier press
        // precedes key presses. This preserves chord semantics for consumers.
        var rawUsage: UInt16 = 4
        while rawUsage <= 0xdf {
            let usage = UInt8(truncatingIfNeeded: rawUsage)
            if pressedKeys.contains(usage), !report.keys.contains(usage) {
                emit(
                    .keyboardUsage(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        usage: .keyboard(rawUsage),
                        isPressed: false
                    ),
                    into: &sink,
                    summary: &summary
                )
            }
            rawUsage += 1
        }

        let changedModifiers = currentModifiers.rawValue ^ report.modifiers
        if changedModifiers != 0 {
            emit(
                .keyboardModifiers(
                    timestampTicks: timestampTicks,
                    deviceID: deviceID,
                    changed: KeyboardModifierMask(
                        rawValue: changedModifiers
                    ),
                    current: KeyboardModifierMask(
                        rawValue: report.modifiers
                    )
                ),
                into: &sink,
                summary: &summary
            )
        }

        rawUsage = 4
        while rawUsage <= 0xdf {
            let usage = UInt8(truncatingIfNeeded: rawUsage)
            if report.keys.contains(usage), !pressedKeys.contains(usage) {
                emit(
                    .keyboardUsage(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        usage: .keyboard(rawUsage),
                        isPressed: true
                    ),
                    into: &sink,
                    summary: &summary
                )
            }
            rawUsage += 1
        }
    }

    private func emit<S: InputEventSink>(
        _ event: InputEvent,
        into sink: inout S,
        summary: inout InputEmissionSummary
    ) {
        summary.record(sink.submit(event))
    }

    private func emitSynchronizationIfNeeded<S: InputEventSink>(
        timestampTicks: UInt64,
        into sink: inout S,
        summary: inout InputEmissionSummary
    ) {
        guard summary.attemptedCount != 0 else { return }
        emit(
            .synchronization(
                timestampTicks: timestampTicks,
                deviceID: deviceID
            ),
            into: &sink,
            summary: &summary
        )
    }

    private static func parse(
        _ bytes: UnsafeRawBufferPointer
    ) -> HIDBootKeyboardParseResult {
        guard bytes.count == reportByteCount else {
            return .malformed(.invalidLength)
        }
        guard bytes.baseAddress != nil else {
            return .malformed(.unavailableStorage)
        }
        guard bytes[1] == 0 else {
            return .malformed(.nonzeroReservedByte)
        }

        let keys = HIDBootKeyboardKeys(
            bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]
        )
        var slot = 0
        while slot < HIDBootKeyboardKeys.capacity {
            let usage = keys.usage(at: slot)
            if usage >= 1, usage <= 3 {
                return .rollover
            }
            slot += 1
        }

        slot = 0
        while slot < HIDBootKeyboardKeys.capacity {
            let usage = keys.usage(at: slot)
            if usage != 0 {
                if usage >= 0xe0, usage <= 0xe7 {
                    return .malformed(.modifierInKeyArray)
                }
                guard usage >= 4, usage <= 0xdf else {
                    return .malformed(.invalidKeyUsage)
                }
                var earlierSlot = 0
                while earlierSlot < slot {
                    if keys.usage(at: earlierSlot) == usage {
                        return .malformed(.duplicateKeyUsage)
                    }
                    earlierSlot += 1
                }
            }
            slot += 1
        }
        return .accepted(
            HIDBootKeyboardReport(modifiers: bytes[0], keys: keys)
        )
    }
}

private enum HIDBootKeyboardParseResult {
    case accepted(HIDBootKeyboardReport)
    case rollover
    case malformed(HIDBootReportError)
}

private struct HIDBootKeyboardReport {
    let modifiers: UInt8
    let keys: HIDBootKeyboardKeys
}

/// Six scalar fields avoid heap-backed arrays and tuple-indexing tricks in the
/// freestanding decoder.
private struct HIDBootKeyboardKeys {
    static let capacity = 6

    private let key0: UInt8
    private let key1: UInt8
    private let key2: UInt8
    private let key3: UInt8
    private let key4: UInt8
    private let key5: UInt8

    init(
        _ key0: UInt8 = 0,
        _ key1: UInt8 = 0,
        _ key2: UInt8 = 0,
        _ key3: UInt8 = 0,
        _ key4: UInt8 = 0,
        _ key5: UInt8 = 0
    ) {
        self.key0 = key0
        self.key1 = key1
        self.key2 = key2
        self.key3 = key3
        self.key4 = key4
        self.key5 = key5
    }

    func usage(at index: Int) -> UInt8 {
        switch index {
        case 0: return key0
        case 1: return key1
        case 2: return key2
        case 3: return key3
        case 4: return key4
        default: return key5
        }
    }

    func contains(_ usage: UInt8) -> Bool {
        usage != 0 && (
            key0 == usage
                || key1 == usage
                || key2 == usage
                || key3 == usage
                || key4 == usage
                || key5 == usage
        )
    }
}
