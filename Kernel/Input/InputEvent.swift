/// Stable identifiers assigned by the input service rather than by a
/// particular transport. Zero is reserved for events whose source is unknown.
struct InputDeviceID: RawRepresentable, Equatable {
    let rawValue: UInt32

    static let unknown = Self(rawValue: 0)
}

/// A usage on the USB HID usage tables. Keeping the page separate from the
/// usage makes the core useful to USB HID, VirtIO input, and future native
/// transports without importing a transport-specific key-code namespace.
struct InputUsage: Equatable {
    let page: UInt16
    let usage: UInt16

    static let keyboardPage: UInt16 = 0x0007

    static func keyboard(_ usage: UInt16) -> Self {
        Self(page: keyboardPage, usage: usage)
    }

    var packedValue: UInt32 {
        UInt32(page) << 16 | UInt32(usage)
    }

    init(page: UInt16, usage: UInt16) {
        self.page = page
        self.usage = usage
    }

    init(packedValue: UInt32) {
        page = UInt16(truncatingIfNeeded: packedValue >> 16)
        usage = UInt16(truncatingIfNeeded: packedValue)
    }
}

/// USB HID's eight boot-keyboard modifier bits. The input ABI transports the
/// complete current mask and the bits changed by a report in one event.
struct KeyboardModifierMask: RawRepresentable, Equatable {
    let rawValue: UInt8

    static let none = Self(rawValue: 0)
    static let leftControl = Self(rawValue: 1 << 0)
    static let leftShift = Self(rawValue: 1 << 1)
    static let leftAlt = Self(rawValue: 1 << 2)
    static let leftGUI = Self(rawValue: 1 << 3)
    static let rightControl = Self(rawValue: 1 << 4)
    static let rightShift = Self(rawValue: 1 << 5)
    static let rightAlt = Self(rawValue: 1 << 6)
    static let rightGUI = Self(rawValue: 1 << 7)

    func contains(_ other: Self) -> Bool {
        rawValue & other.rawValue == other.rawValue
    }
}

/// Numeric values are part of the user/kernel input record contract. New kinds
/// must receive new values; existing values must never be repurposed.
struct InputEventKind: RawRepresentable, Equatable {
    let rawValue: UInt8

    static let keyboardUsage = Self(rawValue: 1)
    static let keyboardModifiers = Self(rawValue: 2)
    static let pointerMotion = Self(rawValue: 3)
    static let pointerButton = Self(rawValue: 4)
    static let pointerScroll = Self(rawValue: 5)
    static let synchronization = Self(rawValue: 6)

    var isKnown: Bool {
        self == .keyboardUsage
            || self == .keyboardModifiers
            || self == .pointerMotion
            || self == .pointerButton
            || self == .pointerScroll
            || self == .synchronization
    }
}

struct InputEventFlags: RawRepresentable, Equatable {
    let rawValue: UInt16

    static let none = Self(rawValue: 0)
    static let pressed = Self(rawValue: 1 << 0)
    static let relative = Self(rawValue: 1 << 1)
}

/// Transport-neutral input payload. Its in-memory Swift layout is deliberately
/// not an ABI. InputEventWireCodec below is the stable, fixed-width boundary
/// used when records cross into user space.
struct InputEvent: Equatable {
    let timestampTicks: UInt64
    let deviceID: InputDeviceID
    let kind: InputEventKind
    let flags: InputEventFlags
    let code: UInt32
    let value0: Int32
    let value1: Int32

    static func keyboardUsage(
        timestampTicks: UInt64,
        deviceID: InputDeviceID,
        usage: InputUsage,
        isPressed: Bool
    ) -> Self {
        Self(
            timestampTicks: timestampTicks,
            deviceID: deviceID,
            kind: .keyboardUsage,
            flags: isPressed ? .pressed : .none,
            code: usage.packedValue,
            value0: 0,
            value1: 0
        )
    }

    static func keyboardModifiers(
        timestampTicks: UInt64,
        deviceID: InputDeviceID,
        changed: KeyboardModifierMask,
        current: KeyboardModifierMask
    ) -> Self {
        Self(
            timestampTicks: timestampTicks,
            deviceID: deviceID,
            kind: .keyboardModifiers,
            flags: .none,
            code: UInt32(changed.rawValue),
            value0: Int32(current.rawValue),
            value1: 0
        )
    }

    static func pointerMotion(
        timestampTicks: UInt64,
        deviceID: InputDeviceID,
        deltaX: Int32,
        deltaY: Int32
    ) -> Self {
        Self(
            timestampTicks: timestampTicks,
            deviceID: deviceID,
            kind: .pointerMotion,
            flags: .relative,
            code: 0,
            value0: deltaX,
            value1: deltaY
        )
    }

    static func pointerButton(
        timestampTicks: UInt64,
        deviceID: InputDeviceID,
        button: UInt8,
        isPressed: Bool
    ) -> Self {
        Self(
            timestampTicks: timestampTicks,
            deviceID: deviceID,
            kind: .pointerButton,
            flags: isPressed ? .pressed : .none,
            code: UInt32(button),
            value0: 0,
            value1: 0
        )
    }

    static func pointerScroll(
        timestampTicks: UInt64,
        deviceID: InputDeviceID,
        vertical: Int32,
        horizontal: Int32
    ) -> Self {
        Self(
            timestampTicks: timestampTicks,
            deviceID: deviceID,
            kind: .pointerScroll,
            flags: .relative,
            code: 0,
            value0: vertical,
            value1: horizontal
        )
    }

    /// Marks the end of one device report. VirtIO transports map SYN_REPORT to
    /// this event; report-based transports emit it after their transitions.
    static func synchronization(
        timestampTicks: UInt64,
        deviceID: InputDeviceID
    ) -> Self {
        Self(
            timestampTicks: timestampTicks,
            deviceID: deviceID,
            kind: .synchronization,
            flags: .none,
            code: 0,
            value0: 0,
            value1: 0
        )
    }

    var keyboardUsage: InputUsage? {
        guard kind == .keyboardUsage else { return nil }
        return InputUsage(packedValue: code)
    }

    var modifierTransition: (
        changed: KeyboardModifierMask,
        current: KeyboardModifierMask
    )? {
        guard kind == .keyboardModifiers else { return nil }
        return (
            KeyboardModifierMask(rawValue: UInt8(truncatingIfNeeded: code)),
            KeyboardModifierMask(rawValue: UInt8(truncatingIfNeeded: value0))
        )
    }

    var isPressed: Bool {
        flags.rawValue & InputEventFlags.pressed.rawValue != 0
    }

    fileprivate init(
        timestampTicks: UInt64,
        deviceID: InputDeviceID,
        kind: InputEventKind,
        flags: InputEventFlags,
        code: UInt32,
        value0: Int32,
        value1: Int32
    ) {
        self.timestampTicks = timestampTicks
        self.deviceID = deviceID
        self.kind = kind
        self.flags = flags
        self.code = code
        self.value0 = value0
        self.value1 = value1
    }
}

struct QueuedInputEvent: Equatable {
    let sequence: UInt64
    let event: InputEvent
}

/// Version-one user/kernel input record ABI (all integers little-endian):
///
///   0  magic "SINP"       4  version       5  kind
///   6  flags               8  queue sequence
///  16  timestamp ticks    24  device ID    28  kind-specific code
///  32  signed value 0     36  signed value 1
///
/// The explicit codec avoids relying on Swift enum or struct memory layout.
enum InputEventWireCodec {
    static let recordByteCount = 40
    static let version: UInt8 = 1

    private static let magic: UInt32 = 0x504e_4953

    @discardableResult
    static func encode(
        _ queuedEvent: QueuedInputEvent,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int = 0
    ) -> Bool {
        guard contains(bytes, offset: offset, count: recordByteCount),
              isWellFormed(queuedEvent.event),
              queuedEvent.sequence != 0
        else { return false }

        writeUInt32(magic, to: bytes, at: offset)
        bytes[offset + 4] = version
        bytes[offset + 5] = queuedEvent.event.kind.rawValue
        writeUInt16(
            queuedEvent.event.flags.rawValue,
            to: bytes,
            at: offset + 6
        )
        writeUInt64(queuedEvent.sequence, to: bytes, at: offset + 8)
        writeUInt64(
            queuedEvent.event.timestampTicks,
            to: bytes,
            at: offset + 16
        )
        writeUInt32(
            queuedEvent.event.deviceID.rawValue,
            to: bytes,
            at: offset + 24
        )
        writeUInt32(queuedEvent.event.code, to: bytes, at: offset + 28)
        writeUInt32(
            UInt32(bitPattern: queuedEvent.event.value0),
            to: bytes,
            at: offset + 32
        )
        writeUInt32(
            UInt32(bitPattern: queuedEvent.event.value1),
            to: bytes,
            at: offset + 36
        )
        return true
    }

    static func decode(
        from bytes: UnsafeRawBufferPointer,
        at offset: Int = 0
    ) -> QueuedInputEvent? {
        guard contains(bytes, offset: offset, count: recordByteCount),
              readUInt32(bytes, at: offset) == magic,
              bytes[offset + 4] == version
        else { return nil }

        let sequence = readUInt64(bytes, at: offset + 8)
        guard sequence != 0 else { return nil }
        let event = InputEvent(
            timestampTicks: readUInt64(bytes, at: offset + 16),
            deviceID: InputDeviceID(
                rawValue: readUInt32(bytes, at: offset + 24)
            ),
            kind: InputEventKind(rawValue: bytes[offset + 5]),
            flags: InputEventFlags(
                rawValue: readUInt16(bytes, at: offset + 6)
            ),
            code: readUInt32(bytes, at: offset + 28),
            value0: Int32(bitPattern: readUInt32(bytes, at: offset + 32)),
            value1: Int32(bitPattern: readUInt32(bytes, at: offset + 36))
        )
        guard isWellFormed(event) else { return nil }
        return QueuedInputEvent(sequence: sequence, event: event)
    }

    static func isWellFormed(_ event: InputEvent) -> Bool {
        guard event.kind.isKnown else { return false }
        switch event.kind {
        case .keyboardUsage:
            let usage = InputUsage(packedValue: event.code)
            return usage.page == InputUsage.keyboardPage
                && usage.usage != 0
                && event.flags.rawValue
                    & ~InputEventFlags.pressed.rawValue == 0
                && event.value0 == 0
                && event.value1 == 0
        case .keyboardModifiers:
            return event.flags == .none
                && event.code != 0
                && event.code <= UInt32(UInt8.max)
                && event.value0 >= 0
                && event.value0 <= Int32(UInt8.max)
                && event.value1 == 0
        case .pointerMotion:
            return event.flags == .relative
                && event.code == 0
        case .pointerButton:
            return event.code >= 1
                && event.code <= 32
                && event.flags.rawValue
                    & ~InputEventFlags.pressed.rawValue == 0
                && event.value0 == 0
                && event.value1 == 0
        case .pointerScroll:
            return event.flags == .relative
                && event.code == 0
        case .synchronization:
            return event.flags == .none
                && event.code == 0
                && event.value0 == 0
                && event.value1 == 0
        default:
            return false
        }
    }

    @inline(__always)
    private static func contains(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) -> Bool {
        guard offset >= 0,
              count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset
        else { return false }
        return count == 0 || bytes.baseAddress != nil
    }

    @inline(__always)
    private static func contains(
        _ bytes: UnsafeMutableRawBufferPointer,
        offset: Int,
        count: Int
    ) -> Bool {
        guard offset >= 0,
              count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset
        else { return false }
        return count == 0 || bytes.baseAddress != nil
    }

    @inline(__always)
    private static func writeUInt16(
        _ value: UInt16,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    @inline(__always)
    private static func writeUInt32(
        _ value: UInt32,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    @inline(__always)
    private static func writeUInt64(
        _ value: UInt64,
        to bytes: UnsafeMutableRawBufferPointer,
        at offset: Int
    ) {
        writeUInt32(UInt32(truncatingIfNeeded: value), to: bytes, at: offset)
        writeUInt32(
            UInt32(truncatingIfNeeded: value >> 32),
            to: bytes,
            at: offset + 4
        )
    }

    @inline(__always)
    private static func readUInt16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset])
            | UInt16(bytes[offset + 1]) << 8
    }

    @inline(__always)
    private static func readUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    @inline(__always)
    private static func readUInt64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        UInt64(readUInt32(bytes, at: offset))
            | UInt64(readUInt32(bytes, at: offset + 4)) << 32
    }
}
