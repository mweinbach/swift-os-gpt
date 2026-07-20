enum RaspberryPi5USBPowerDisposition: Equatable {
    case managed
    case unmanaged
    case reject
}

/// Decides whether the Pi 5 may continue to its DT-described DWC2 device
/// controller after the optional legacy firmware power-domain request.
enum RaspberryPi5USBPowerPolicy {
    static func disposition(
        for result: FirmwareMailboxPowerStateResult
    ) -> RaspberryPi5USBPowerDisposition {
        switch result {
        case .completed:
            return .managed
        case .deviceUnavailable, .stateMismatch:
            // Device ID 3 describes the legacy USB HCD power domain, not the
            // DT-selected BCM2712 DWC2 instance. Pi 5 firmware may return a
            // fully validated exists-but-off state even though DWC2 MMIO is
            // independently described and available for capability probing.
            return .unmanaged
        case .invalidPollLimit,
             .cacheCleanFailed,
             .writeTimedOut,
             .responseTimedOut,
             .cacheInvalidationFailed,
             .malformedResponse:
            return .reject
        }
    }
}
