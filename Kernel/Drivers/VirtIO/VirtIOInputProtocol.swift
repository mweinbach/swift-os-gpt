enum VirtIOInputConfigurationSelector {
    static let unset: UInt8 = 0x00
    static let identifierName: UInt8 = 0x01
    static let identifierSerial: UInt8 = 0x02
    static let deviceIdentifiers: UInt8 = 0x03
    static let propertyBits: UInt8 = 0x10
    static let eventBits: UInt8 = 0x11
    static let absoluteInformation: UInt8 = 0x12
}

enum VirtIOInputEventType {
    static let synchronization: UInt16 = 0
    static let key: UInt16 = 1
    static let relative: UInt16 = 2
}

enum VirtIOInputEventCode {
    static let synchronizationReport: UInt16 = 0

    static let relativeX: UInt16 = 0
    static let relativeY: UInt16 = 1
    static let horizontalWheel: UInt16 = 6
    static let verticalWheel: UInt16 = 8

    static let primaryButton: UInt16 = 0x110
    static let secondaryButton: UInt16 = 0x111
    static let middleButton: UInt16 = 0x112
    static let sideButton: UInt16 = 0x113
    static let extraButton: UInt16 = 0x114
}

struct VirtIOInputWireEvent: Equatable {
    static let byteCount: UInt64 = 8

    let type: UInt16
    let code: UInt16
    let rawValue: UInt32

    var signedValue: Int32 {
        Int32(bitPattern: rawValue)
    }

    static func decode(at cpuPhysicalAddress: UInt64) -> Self {
        Self(
            type: PhysicalBytes.readLE16(at: cpuPhysicalAddress),
            code: PhysicalBytes.readLE16(at: cpuPhysicalAddress + 2),
            rawValue: PhysicalBytes.readLE32(at: cpuPhysicalAddress + 4)
        )
    }
}

struct VirtIOInputCapabilities: Equatable {
    let keyboard: Bool
    let relativePointer: Bool
    let primaryPointerButton: Bool
    let verticalScroll: Bool
    let horizontalScroll: Bool

    var isUsable: Bool {
        keyboard || (relativePointer && primaryPointerButton)
    }
}

struct VirtIOInputTranslationSummary: Equatable {
    private(set) var recognizedWireEventCount: UInt16 = 0
    private(set) var ignoredWireEventCount: UInt16 = 0
    private(set) var attemptedEmissionCount: UInt16 = 0
    private(set) var enqueuedEmissionCount: UInt16 = 0
    private(set) var droppedEmissionCount: UInt16 = 0
    private(set) var synchronizationCount: UInt16 = 0

    mutating func recognized() {
        recognizedWireEventCount &+= 1
    }

    mutating func ignored() {
        ignoredWireEventCount &+= 1
    }

    mutating func synchronized() {
        synchronizationCount &+= 1
    }

    mutating func record(_ result: InputEventSubmissionResult) {
        attemptedEmissionCount &+= 1
        switch result {
        case .enqueued:
            enqueuedEmissionCount &+= 1
        case .dropped:
            droppedEmissionCount &+= 1
        }
    }

    mutating func merge(_ other: Self) {
        recognizedWireEventCount &+= other.recognizedWireEventCount
        ignoredWireEventCount &+= other.ignoredWireEventCount
        attemptedEmissionCount &+= other.attemptedEmissionCount
        enqueuedEmissionCount &+= other.enqueuedEmissionCount
        droppedEmissionCount &+= other.droppedEmissionCount
        synchronizationCount &+= other.synchronizationCount
    }
}

/// Converts Linux evdev codes at the VirtIO boundary into SwiftOS' canonical
/// USB HID keyboard usages and transport-neutral pointer records. Relative
/// axes are coalesced until SYN_REPORT so one device update is not exposed as
/// partially updated X/Y or wheel state.
struct VirtIOInputEventTranslator {
    let deviceID: InputDeviceID

    private var currentModifiers = KeyboardModifierMask.none
    private var pendingDeltaX: Int32 = 0
    private var pendingDeltaY: Int32 = 0
    private var pendingVerticalScroll: Int32 = 0
    private var pendingHorizontalScroll: Int32 = 0

    init(deviceID: InputDeviceID) {
        self.deviceID = deviceID
    }

    mutating func process<S: InputEventSink>(
        _ wireEvent: VirtIOInputWireEvent,
        timestampTicks: UInt64,
        into sink: inout S
    ) -> VirtIOInputTranslationSummary {
        var summary = VirtIOInputTranslationSummary()
        switch wireEvent.type {
        case VirtIOInputEventType.key:
            processKey(
                code: wireEvent.code,
                rawValue: wireEvent.rawValue,
                timestampTicks: timestampTicks,
                into: &sink,
                summary: &summary
            )
        case VirtIOInputEventType.relative:
            processRelative(
                code: wireEvent.code,
                value: wireEvent.signedValue,
                summary: &summary
            )
        case VirtIOInputEventType.synchronization:
            guard wireEvent.code
                    == VirtIOInputEventCode.synchronizationReport
            else {
                summary.ignored()
                return summary
            }
            summary.recognized()
            flushPendingPointerState(
                timestampTicks: timestampTicks,
                into: &sink,
                summary: &summary
            )
            emitSynchronization(
                timestampTicks: timestampTicks,
                into: &sink,
                summary: &summary
            )
            summary.synchronized()
        default:
            summary.ignored()
        }
        return summary
    }

    private mutating func processKey<S: InputEventSink>(
        code: UInt16,
        rawValue: UInt32,
        timestampTicks: UInt64,
        into sink: inout S,
        summary: inout VirtIOInputTranslationSummary
    ) {
        guard rawValue <= 2 else {
            summary.ignored()
            return
        }
        let isPressed = rawValue != 0
        if let modifier = Self.modifier(for: code) {
            summary.recognized()
            // Repeats do not change modifier state.
            guard rawValue != 2 else { return }
            let previous = currentModifiers
            if isPressed {
                currentModifiers = KeyboardModifierMask(
                    rawValue: previous.rawValue | modifier.rawValue
                )
            } else {
                currentModifiers = KeyboardModifierMask(
                    rawValue: previous.rawValue & ~modifier.rawValue
                )
            }
            guard currentModifiers != previous else { return }
            summary.record(
                sink.submit(
                    .keyboardModifiers(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        changed: modifier,
                        current: currentModifiers
                    )
                )
            )
            return
        }
        if let usage = Self.keyboardUsage(for: code) {
            summary.recognized()
            summary.record(
                sink.submit(
                    .keyboardUsage(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        usage: .keyboard(usage),
                        isPressed: isPressed
                    )
                )
            )
            return
        }
        if let button = Self.pointerButton(for: code), rawValue != 2 {
            summary.recognized()
            summary.record(
                sink.submit(
                    .pointerButton(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        button: button,
                        isPressed: isPressed
                    )
                )
            )
            return
        }
        summary.ignored()
    }

    private mutating func processRelative(
        code: UInt16,
        value: Int32,
        summary: inout VirtIOInputTranslationSummary
    ) {
        switch code {
        case VirtIOInputEventCode.relativeX:
            pendingDeltaX = Self.saturatingAdd(pendingDeltaX, value)
        case VirtIOInputEventCode.relativeY:
            pendingDeltaY = Self.saturatingAdd(pendingDeltaY, value)
        case VirtIOInputEventCode.verticalWheel:
            pendingVerticalScroll = Self.saturatingAdd(
                pendingVerticalScroll,
                value
            )
        case VirtIOInputEventCode.horizontalWheel:
            pendingHorizontalScroll = Self.saturatingAdd(
                pendingHorizontalScroll,
                value
            )
        default:
            summary.ignored()
            return
        }
        summary.recognized()
    }

    private mutating func flushPendingPointerState<S: InputEventSink>(
        timestampTicks: UInt64,
        into sink: inout S,
        summary: inout VirtIOInputTranslationSummary
    ) {
        if pendingDeltaX != 0 || pendingDeltaY != 0 {
            summary.record(
                sink.submit(
                    .pointerMotion(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        deltaX: pendingDeltaX,
                        deltaY: pendingDeltaY
                    )
                )
            )
        }
        if pendingVerticalScroll != 0 || pendingHorizontalScroll != 0 {
            summary.record(
                sink.submit(
                    .pointerScroll(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        vertical: pendingVerticalScroll,
                        horizontal: pendingHorizontalScroll
                    )
                )
            )
        }
        pendingDeltaX = 0
        pendingDeltaY = 0
        pendingVerticalScroll = 0
        pendingHorizontalScroll = 0
    }

    private func emitSynchronization<S: InputEventSink>(
        timestampTicks: UInt64,
        into sink: inout S,
        summary: inout VirtIOInputTranslationSummary
    ) {
        summary.record(
            sink.submit(
                .synchronization(
                    timestampTicks: timestampTicks,
                    deviceID: deviceID
                )
            )
        )
    }

    private static func saturatingAdd(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= 0 ? Int32.max : Int32.min
    }

    static func pointerButton(for evdevCode: UInt16) -> UInt8? {
        switch evdevCode {
        case VirtIOInputEventCode.primaryButton: return 1
        case VirtIOInputEventCode.secondaryButton: return 2
        case VirtIOInputEventCode.middleButton: return 3
        case VirtIOInputEventCode.sideButton: return 4
        case VirtIOInputEventCode.extraButton: return 5
        default: return nil
        }
    }

    static func modifier(for evdevCode: UInt16) -> KeyboardModifierMask? {
        switch evdevCode {
        case 29: return .leftControl
        case 42: return .leftShift
        case 56: return .leftAlt
        case 125: return .leftGUI
        case 97: return .rightControl
        case 54: return .rightShift
        case 100: return .rightAlt
        case 126: return .rightGUI
        default: return nil
        }
    }

    /// Linux input key codes to USB HID keyboard-page usages. This covers the
    /// complete boot-keyboard set and the navigation/function keys needed by
    /// the first SwiftOS desktop without making evdev part of the core ABI.
    static func keyboardUsage(for evdevCode: UInt16) -> UInt16? {
        switch evdevCode {
        case 30: return 0x04 // A
        case 48: return 0x05 // B
        case 46: return 0x06 // C
        case 32: return 0x07 // D
        case 18: return 0x08 // E
        case 33: return 0x09 // F
        case 34: return 0x0a // G
        case 35: return 0x0b // H
        case 23: return 0x0c // I
        case 36: return 0x0d // J
        case 37: return 0x0e // K
        case 38: return 0x0f // L
        case 50: return 0x10 // M
        case 49: return 0x11 // N
        case 24: return 0x12 // O
        case 25: return 0x13 // P
        case 16: return 0x14 // Q
        case 19: return 0x15 // R
        case 31: return 0x16 // S
        case 20: return 0x17 // T
        case 22: return 0x18 // U
        case 47: return 0x19 // V
        case 17: return 0x1a // W
        case 45: return 0x1b // X
        case 21: return 0x1c // Y
        case 44: return 0x1d // Z
        case 2: return 0x1e
        case 3: return 0x1f
        case 4: return 0x20
        case 5: return 0x21
        case 6: return 0x22
        case 7: return 0x23
        case 8: return 0x24
        case 9: return 0x25
        case 10: return 0x26
        case 11: return 0x27
        case 28: return 0x28 // Enter
        case 1: return 0x29 // Escape
        case 14: return 0x2a // Backspace
        case 15: return 0x2b // Tab
        case 57: return 0x2c // Space
        case 12: return 0x2d
        case 13: return 0x2e
        case 26: return 0x2f
        case 27: return 0x30
        case 43: return 0x31
        case 39: return 0x33
        case 40: return 0x34
        case 41: return 0x35
        case 51: return 0x36
        case 52: return 0x37
        case 53: return 0x38
        case 58: return 0x39 // Caps Lock
        case 59...68: return 0x3a + (evdevCode - 59)
        case 87: return 0x44 // F11
        case 88: return 0x45 // F12
        case 99: return 0x46 // Print Screen
        case 70: return 0x47 // Scroll Lock
        case 119: return 0x48 // Pause
        case 110: return 0x49 // Insert
        case 102: return 0x4a // Home
        case 104: return 0x4b // Page Up
        case 111: return 0x4c // Delete
        case 107: return 0x4d // End
        case 109: return 0x4e // Page Down
        case 106: return 0x4f // Right
        case 105: return 0x50 // Left
        case 108: return 0x51 // Down
        case 103: return 0x52 // Up
        case 69: return 0x53 // Num Lock
        case 98: return 0x54
        case 55: return 0x55
        case 74: return 0x56
        case 78: return 0x57
        case 96: return 0x58
        case 79: return 0x59
        case 80: return 0x5a
        case 81: return 0x5b
        case 75: return 0x5c
        case 76: return 0x5d
        case 77: return 0x5e
        case 71: return 0x5f
        case 72: return 0x60
        case 73: return 0x61
        case 82: return 0x62
        case 83: return 0x63
        case 86: return 0x64
        case 127: return 0x65 // Application/Compose
        case 116: return 0x66 // Power
        case 117: return 0x67 // Keypad equals
        default: return nil
        }
    }
}
