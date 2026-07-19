enum HIDBootReportError: Equatable {
    case invalidLength
    case unavailableStorage
    case nonzeroReservedByte
    case duplicateKeyUsage
    case modifierInKeyArray
    case invalidKeyUsage
}

struct InputEmissionSummary: Equatable {
    private(set) var attemptedCount = 0
    private(set) var enqueuedCount = 0
    private(set) var droppedCount = 0

    mutating func record(_ result: InputEventSubmissionResult) {
        attemptedCount += 1
        switch result {
        case .enqueued:
            enqueuedCount += 1
        case .dropped:
            droppedCount += 1
        }
    }
}

enum HIDBootReportResult: Equatable {
    case accepted(InputEmissionSummary)
    /// One or more HID ErrorRollOver, POSTFail, or ErrorUndefined usages were
    /// present. The last good state is retained and no events are emitted.
    case rollover
    /// The report failed structural validation. State and output are untouched.
    case malformed(HIDBootReportError)
}
