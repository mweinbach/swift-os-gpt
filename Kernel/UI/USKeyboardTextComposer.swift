enum TextNavigation: UInt8, Equatable {
    case left
    case right
    case up
    case down
    case home
    case end
    case pageUp
    case pageDown
}

enum TextInputAction: Equatable {
    case insertASCII(UInt8)
    case deleteBackward
    case deleteForward
    case navigate(TextNavigation)
    case submit
    case cancel
    case tab(backward: Bool)
    /// A printable key modified by Control, Alt, or GUI remains available to
    /// window/application policy instead of accidentally inserting text.
    case command(usage: InputUsage, modifiers: KeyboardModifierMask)
}

enum KeyboardCompositionResult: Equatable {
    case ignored
    case stateChanged
    case action(TextInputAction, isRepeat: Bool)
}

/// Device-scoped USB-HID keyboard-page composition for a basic US layout.
/// The composer is transport-neutral: USB boot reports and VirtIO evdev input
/// both arrive as canonical InputEvents before reaching this state machine.
struct USKeyboardTextComposer {
    let deviceID: InputDeviceID
    private(set) var modifiers = KeyboardModifierMask.none
    private(set) var capsLockEnabled = false

    private var pressedUsages0To63: UInt64 = 0
    private var pressedUsages64To127: UInt64 = 0

    init(deviceID: InputDeviceID) {
        self.deviceID = deviceID
    }

    mutating func process(_ event: InputEvent) -> KeyboardCompositionResult {
        guard event.deviceID == deviceID else { return .ignored }
        if let transition = event.modifierTransition {
            modifiers = transition.current
            return .stateChanged
        }
        guard event.kind == .keyboardUsage,
              let usage = event.keyboardUsage,
              usage.page == InputUsage.keyboardPage
        else {
            return .ignored
        }

        let wasPressed = isPressed(usage.usage)
        if event.isPressed {
            setPressed(usage.usage, pressed: true)
        } else {
            setPressed(usage.usage, pressed: false)
            return wasPressed ? .stateChanged : .ignored
        }

        let isRepeat = wasPressed
        if usage.usage == 0x39 {
            if !isRepeat { capsLockEnabled.toggle() }
            return .stateChanged
        }
        guard let action = action(for: usage) else { return .ignored }
        return .action(action, isRepeat: isRepeat)
    }

    private func action(for usage: InputUsage) -> TextInputAction? {
        switch usage.usage {
        case 0x28: return .submit
        case 0x29: return .cancel
        case 0x2a: return .deleteBackward
        case 0x2b: return .tab(backward: shiftIsActive)
        case 0x4a: return .navigate(.home)
        case 0x4b: return .navigate(.pageUp)
        case 0x4c: return .deleteForward
        case 0x4d: return .navigate(.end)
        case 0x4e: return .navigate(.pageDown)
        case 0x4f: return .navigate(.right)
        case 0x50: return .navigate(.left)
        case 0x51: return .navigate(.down)
        case 0x52: return .navigate(.up)
        default:
            break
        }

        guard let ascii = printableASCII(for: usage.usage) else { return nil }
        if commandModifierIsActive {
            return .command(usage: usage, modifiers: modifiers)
        }
        return .insertASCII(ascii)
    }

    private func printableASCII(for usage: UInt16) -> UInt8? {
        if usage >= 0x04, usage <= 0x1d {
            let lowercase = UInt8(0x61 + usage - 0x04)
            return shiftIsActive != capsLockEnabled
                ? lowercase - 0x20
                : lowercase
        }
        if usage >= 0x1e, usage <= 0x27 {
            return digitASCII(index: Int(usage - 0x1e), shifted: shiftIsActive)
        }
        switch usage {
        case 0x2c: return 0x20
        case 0x2d: return shiftIsActive ? 0x5f : 0x2d
        case 0x2e: return shiftIsActive ? 0x2b : 0x3d
        case 0x2f: return shiftIsActive ? 0x7b : 0x5b
        case 0x30: return shiftIsActive ? 0x7d : 0x5d
        case 0x31: return shiftIsActive ? 0x7c : 0x5c
        case 0x33: return shiftIsActive ? 0x3a : 0x3b
        case 0x34: return shiftIsActive ? 0x22 : 0x27
        case 0x35: return shiftIsActive ? 0x7e : 0x60
        case 0x36: return shiftIsActive ? 0x3c : 0x2c
        case 0x37: return shiftIsActive ? 0x3e : 0x2e
        case 0x38: return shiftIsActive ? 0x3f : 0x2f
        default: return nil
        }
    }

    private func digitASCII(index: Int, shifted: Bool) -> UInt8? {
        guard index >= 0, index < 10 else { return nil }
        if !shifted {
            return index == 9 ? 0x30 : UInt8(0x31 + index)
        }
        switch index {
        case 0: return 0x21
        case 1: return 0x40
        case 2: return 0x23
        case 3: return 0x24
        case 4: return 0x25
        case 5: return 0x5e
        case 6: return 0x26
        case 7: return 0x2a
        case 8: return 0x28
        default: return 0x29
        }
    }

    private var shiftIsActive: Bool {
        modifiers.contains(.leftShift) || modifiers.contains(.rightShift)
    }

    private var commandModifierIsActive: Bool {
        modifiers.contains(.leftControl)
            || modifiers.contains(.rightControl)
            || modifiers.contains(.leftAlt)
            || modifiers.contains(.rightAlt)
            || modifiers.contains(.leftGUI)
            || modifiers.contains(.rightGUI)
    }

    private func isPressed(_ usage: UInt16) -> Bool {
        if usage < 64 {
            return pressedUsages0To63 & (UInt64(1) << UInt64(usage)) != 0
        }
        if usage < 128 {
            return pressedUsages64To127
                & (UInt64(1) << UInt64(usage - 64)) != 0
        }
        return false
    }

    private mutating func setPressed(_ usage: UInt16, pressed: Bool) {
        if usage < 64 {
            let bit = UInt64(1) << UInt64(usage)
            pressedUsages0To63 = pressed
                ? pressedUsages0To63 | bit
                : pressedUsages0To63 & ~bit
        } else if usage < 128 {
            let bit = UInt64(1) << UInt64(usage - 64)
            pressedUsages64To127 = pressed
                ? pressedUsages64To127 | bit
                : pressedUsages64To127 & ~bit
        }
    }
}

struct BoundedASCIITextView {
    private let bytes: UnsafePointer<UInt8>
    let byteCount: Int
    let cursorOffset: Int

    fileprivate init(
        bytes: UnsafePointer<UInt8>,
        byteCount: Int,
        cursorOffset: Int
    ) {
        self.bytes = bytes
        self.byteCount = byteCount
        self.cursorOffset = cursorOffset
    }

    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < byteCount else { return nil }
        return bytes[index]
    }
}

enum BoundedTextEditResult: Equatable {
    case changed
    case unchanged
    case capacityExhausted
    case notHandled
}

/// Caller-owned ASCII editing state suitable for a file-manager rename or
/// type-ahead field. Unicode filename storage remains a VFS concern; this is
/// intentionally the first bounded keyboard-editing contract.
struct BoundedASCIITextBuffer {
    private let storage: UnsafeMutableRawBufferPointer
    private(set) var count = 0
    private(set) var cursorOffset = 0

    init?(storage: UnsafeMutableRawBufferPointer) {
        guard storage.baseAddress != nil, !storage.isEmpty else { return nil }
        self.storage = storage
    }

    var capacity: Int { storage.count }

    var view: BoundedASCIITextView {
        BoundedASCIITextView(
            bytes: UnsafePointer(
                storage.baseAddress!.assumingMemoryBound(to: UInt8.self)
            ),
            byteCount: count,
            cursorOffset: cursorOffset
        )
    }

    mutating func clear() {
        count = 0
        cursorOffset = 0
    }

    mutating func apply(_ action: TextInputAction) -> BoundedTextEditResult {
        switch action {
        case .insertASCII(let byte):
            guard byte >= 0x20, byte <= 0x7e else { return .notHandled }
            guard count < storage.count else { return .capacityExhausted }
            var index = count
            while index > cursorOffset {
                storage[index] = storage[index - 1]
                index -= 1
            }
            storage[cursorOffset] = byte
            cursorOffset += 1
            count += 1
            return .changed
        case .deleteBackward:
            guard cursorOffset > 0 else { return .unchanged }
            var index = cursorOffset - 1
            while index + 1 < count {
                storage[index] = storage[index + 1]
                index += 1
            }
            cursorOffset -= 1
            count -= 1
            return .changed
        case .deleteForward:
            guard cursorOffset < count else { return .unchanged }
            var index = cursorOffset
            while index + 1 < count {
                storage[index] = storage[index + 1]
                index += 1
            }
            count -= 1
            return .changed
        case .navigate(let navigation):
            let previous = cursorOffset
            switch navigation {
            case .left:
                if cursorOffset > 0 { cursorOffset -= 1 }
            case .right:
                if cursorOffset < count { cursorOffset += 1 }
            case .home:
                cursorOffset = 0
            case .end:
                cursorOffset = count
            case .up, .down, .pageUp, .pageDown:
                return .notHandled
            }
            return cursorOffset == previous ? .unchanged : .changed
        case .submit, .cancel, .tab, .command:
            return .notHandled
        }
    }
}
