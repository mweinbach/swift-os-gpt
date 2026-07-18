/// Transport-wide VirtIO feature bits. Device-specific feature masks remain
/// in their drivers and are passed into the transport during initialization.
enum VirtIOTransportFeature {
    static let version1: UInt64 = 1 << 32
}

/// A validated feature selection. Keeping this policy independent from MMIO
/// makes it possible to prove that a driver never acknowledges an unavailable
/// feature before touching a device status register.
struct VirtIOFeatureSelection: Equatable {
    let offered: UInt64
    let accepted: UInt64

    static func select(
        offered: UInt64,
        required: UInt64,
        optional: UInt64
    ) -> VirtIOFeatureSelection? {
        guard offered & required == required else { return nil }
        return VirtIOFeatureSelection(
            offered: offered,
            accepted: required | (offered & optional)
        )
    }
}
