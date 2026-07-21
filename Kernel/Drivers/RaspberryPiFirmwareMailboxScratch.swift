enum RaspberryPiFirmwareMailboxScratchDisposition: UInt8, Equatable {
    case reusable
    case poisoned
}

/// Ownership policy for the single 64-byte property-mailbox tail in the Pi DMA
/// scratch page. A response timeout may leave firmware using that address, and
/// a failed cache invalidation cannot prove that CPU reuse is coherent. Either
/// result therefore forbids a later tryboot transaction in the same boot.
enum RaspberryPiFirmwareMailboxScratchPolicy {
    static func disposition(
        after result: FirmwareMailboxPowerStateResult
    ) -> RaspberryPiFirmwareMailboxScratchDisposition {
        switch result {
        case .responseTimedOut, .cacheInvalidationFailed:
            return .poisoned
        case .completed, .deviceUnavailable, .stateMismatch,
             .invalidPollLimit, .cacheCleanFailed, .writeTimedOut,
             .malformedResponse:
            return .reusable
        }
    }
}

enum RaspberryPi5FirmwareMailboxScratchRuntime {
    private nonisolated(unsafe) static var disposition =
        RaspberryPiFirmwareMailboxScratchDisposition.reusable

    static var isReusable: Bool { disposition == .reusable }

    static func recordPowerStateResult(
        _ result: FirmwareMailboxPowerStateResult
    ) {
        if RaspberryPiFirmwareMailboxScratchPolicy.disposition(after: result)
            == .poisoned {
            disposition = .poisoned
        }
    }
}
