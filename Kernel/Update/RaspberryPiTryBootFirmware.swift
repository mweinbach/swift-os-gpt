protocol RaspberryPiTryBootFirmwareInterface {
    mutating func setRebootFlags(
        _ flags: UInt32,
        maximumPollCount: Int
    ) -> FirmwareMailboxRebootResult

    mutating func notifyReboot(
        maximumPollCount: Int
    ) -> FirmwareMailboxRebootResult
}

extension FirmwarePropertyMailbox: RaspberryPiTryBootFirmwareInterface {}

enum RaspberryPiTryBootPreparationResult: Equatable {
    /// Once the request may have reached firmware, policy must reset
    /// immediately. A missing or malformed response cannot prove that the
    /// one-shot flag stayed clear, and the shared mailbox buffer must not be
    /// reused for NOTIFY_REBOOT while that transaction is indeterminate.
    case readyToReset(
        arm: FirmwareMailboxRebootResult,
        notification: FirmwareMailboxRebootResult?
    )
    case armRejected(FirmwareMailboxRebootResult)
}

enum RaspberryPiTryBootFirmwareCoordinator {
    static func prepareForReset<Firmware: RaspberryPiTryBootFirmwareInterface>(
        firmware: inout Firmware,
        maximumPollCount: Int
    ) -> RaspberryPiTryBootPreparationResult {
        let armed = firmware.setRebootFlags(
            1,
            maximumPollCount: maximumPollCount
        )
        switch armed {
        case .invalidFlags, .invalidPollLimit, .cacheCleanFailed,
             .writeTimedOut:
            // These failures occur before the request word is written.
            return .armRejected(armed)
        case .responseTimedOut, .cacheInvalidationFailed,
             .malformedResponse:
            // The request was written. Reset without reusing the mailbox
            // buffer because firmware may still own the transaction.
            return .readyToReset(arm: armed, notification: nil)
        case .completed:
            break
        }
        let notification = firmware.notifyReboot(
            maximumPollCount: maximumPollCount
        )
        return .readyToReset(arm: armed, notification: notification)
    }
}
