enum RP1GEMDeferredActivationPolicy {
    /// Five seconds lets a directly attached host complete USB enumeration
    /// and fetch initial status before the polling PHY path can occupy the BSP.
    static let localObservationDelaySeconds: UInt64 = 5

    static func makeGate(
        counterFrequency: UInt64
    ) -> RP1GEMDeferredActivationGate? {
        guard counterFrequency > 0,
              localObservationDelaySeconds
                <= UInt64.max / counterFrequency
        else {
            return nil
        }
        return RP1GEMDeferredActivationGate(
            delayTicks: counterFrequency * localObservationDelaySeconds
        )
    }
}

/// Gives local display and USB diagnostics a deterministic service window
/// before RP1 Ethernet performs bounded, polling-only hardware discovery.
/// The delay starts on the first cooperative-service pass rather than at
/// scheduling time, so framebuffer setup cannot consume the observation
/// window.
struct RP1GEMDeferredActivationGate {
    private let delayTicks: UInt64
    private var firstServiceTicks: UInt64?
    private var consumed = false

    init?(delayTicks: UInt64) {
        guard delayTicks > 0 else { return nil }
        self.delayTicks = delayTicks
    }

    /// Returns true exactly once after the complete delay has elapsed.
    /// Wrapping subtraction is valid for intervals shorter than one full
    /// counter period, which this boot policy guarantees by construction.
    mutating func poll(nowTicks: UInt64) -> Bool {
        guard !consumed else { return false }
        guard let firstServiceTicks else {
            self.firstServiceTicks = nowTicks
            return false
        }
        guard nowTicks &- firstServiceTicks >= delayTicks else {
            return false
        }
        consumed = true
        return true
    }
}
