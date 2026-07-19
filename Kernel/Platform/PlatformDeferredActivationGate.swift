enum PlatformLocalObservationPolicy {
    /// Five seconds lets a directly attached host complete USB enumeration
    /// and fetch initial status before any polling-only physical bootstrap can
    /// occupy the BSP.
    static let delaySeconds: UInt64 = 5

    static func makeGate(
        counterFrequency: UInt64
    ) -> PlatformDeferredActivationGate? {
        guard counterFrequency > 0,
              delaySeconds <= UInt64.max / counterFrequency
        else { return nil }
        return PlatformDeferredActivationGate(
            delayTicks: counterFrequency * delaySeconds
        )
    }
}

/// Board-neutral one-shot elapsed-time gate. The delay begins on the first
/// cooperative-service pass so framebuffer/USB setup cannot consume it.
struct PlatformDeferredActivationGate {
    private let delayTicks: UInt64
    private var firstServiceTicks: UInt64?
    private var consumed = false

    init?(delayTicks: UInt64) {
        guard delayTicks > 0 else { return nil }
        self.delayTicks = delayTicks
    }

    /// Idempotently fixes the deadline origin without consuming the gate.
    mutating func arm(nowTicks: UInt64) {
        guard !consumed, firstServiceTicks == nil else { return }
        firstServiceTicks = nowTicks
    }

    mutating func poll(nowTicks: UInt64) -> Bool {
        guard !consumed else { return false }
        guard let firstServiceTicks else {
            arm(nowTicks: nowTicks)
            return false
        }
        guard nowTicks &- firstServiceTicks >= delayTicks else {
            return false
        }
        consumed = true
        return true
    }
}
