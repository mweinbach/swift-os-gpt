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
        case .deviceUnavailable:
            return .unmanaged
        case .stateMismatch,
             .invalidPollLimit,
             .cacheCleanFailed,
             .writeTimedOut,
             .responseTimedOut,
             .cacheInvalidationFailed,
             .malformedResponse:
            return .reject
        }
    }
}
