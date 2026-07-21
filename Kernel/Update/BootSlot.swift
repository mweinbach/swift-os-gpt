/// Logical update slot identity. Partition numbers and board-specific boot
/// selectors deliberately remain outside this type.
enum BootSlot: UInt8, Equatable {
    case a = 1
    case b = 2

    var peer: BootSlot {
        switch self {
        case .a: return .b
        case .b: return .a
        }
    }
}

/// Board-neutral evidence that the active firmware can perform the one-shot
/// alternate-slot transition required by transactional A/B updates. Platform
/// discovery maps its firmware-specific capability bits into this type; update
/// policy never interprets a Raspberry Pi bit mask or partition number.
enum PlatformTrialBootCapability: UInt8, Equatable {
    /// Missing, malformed, or incomplete firmware capability evidence.
    case unavailable
    /// A one-shot reboot can select the alternate payload without changing the
    /// persistent default, so failure naturally returns to the confirmed slot.
    case oneShotAlternateSlot
}
