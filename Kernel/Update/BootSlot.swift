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
