/// Allocation-free decoder for the three-byte USB HID boot-mouse report and
/// the common four-byte wheel extension. Deltas remain relative signed report
/// units; acceleration and pixel scaling belong above this transport layer.
struct USBHIDBootMouseStateMachine {
    static let baseReportByteCount = 3
    static let wheelReportByteCount = 4

    let deviceID: InputDeviceID
    private(set) var currentButtons: UInt8 = 0

    init(deviceID: InputDeviceID) {
        self.deviceID = deviceID
    }

    mutating func processReport<S: InputEventSink>(
        _ bytes: UnsafeRawBufferPointer,
        timestampTicks: UInt64,
        into sink: inout S
    ) -> HIDBootReportResult {
        guard bytes.count == Self.baseReportByteCount
                || bytes.count == Self.wheelReportByteCount
        else {
            return .malformed(.invalidLength)
        }
        guard bytes.baseAddress != nil else {
            return .malformed(.unavailableStorage)
        }

        // Every field is decoded before the first sink call. A future
        // validation rule can therefore reject the whole report atomically.
        let buttons = bytes[0]
        let deltaX = Int32(Int8(bitPattern: bytes[1]))
        let deltaY = Int32(Int8(bitPattern: bytes[2]))
        let verticalWheel = bytes.count == Self.wheelReportByteCount
            ? Int32(Int8(bitPattern: bytes[3]))
            : 0

        var summary = InputEmissionSummary()
        let changedButtons = currentButtons ^ buttons
        var bit = 0
        while bit < 8 {
            let mask: UInt8 = 1 << UInt8(bit)
            if changedButtons & mask != 0 {
                emit(
                    .pointerButton(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        button: UInt8(bit + 1),
                        isPressed: buttons & mask != 0
                    ),
                    into: &sink,
                    summary: &summary
                )
            }
            bit += 1
        }
        if deltaX != 0 || deltaY != 0 {
            emit(
                .pointerMotion(
                    timestampTicks: timestampTicks,
                    deviceID: deviceID,
                    deltaX: deltaX,
                    deltaY: deltaY
                ),
                into: &sink,
                summary: &summary
            )
        }
        if verticalWheel != 0 {
            emit(
                .pointerScroll(
                    timestampTicks: timestampTicks,
                    deviceID: deviceID,
                    vertical: verticalWheel,
                    horizontal: 0
                ),
                into: &sink,
                summary: &summary
            )
        }
        emitSynchronizationIfNeeded(
            timestampTicks: timestampTicks,
            into: &sink,
            summary: &summary
        )
        currentButtons = buttons
        return .accepted(summary)
    }

    /// Emits releases for retained buttons when the device disappears.
    mutating func releaseAll<S: InputEventSink>(
        timestampTicks: UInt64,
        into sink: inout S
    ) -> InputEmissionSummary {
        var summary = InputEmissionSummary()
        var bit = 0
        while bit < 8 {
            let mask: UInt8 = 1 << UInt8(bit)
            if currentButtons & mask != 0 {
                emit(
                    .pointerButton(
                        timestampTicks: timestampTicks,
                        deviceID: deviceID,
                        button: UInt8(bit + 1),
                        isPressed: false
                    ),
                    into: &sink,
                    summary: &summary
                )
            }
            bit += 1
        }
        emitSynchronizationIfNeeded(
            timestampTicks: timestampTicks,
            into: &sink,
            summary: &summary
        )
        currentButtons = 0
        return summary
    }

    private func emit<S: InputEventSink>(
        _ event: InputEvent,
        into sink: inout S,
        summary: inout InputEmissionSummary
    ) {
        summary.record(sink.submit(event))
    }

    private func emitSynchronizationIfNeeded<S: InputEventSink>(
        timestampTicks: UInt64,
        into sink: inout S,
        summary: inout InputEmissionSummary
    ) {
        guard summary.attemptedCount != 0 else { return }
        emit(
            .synchronization(
                timestampTicks: timestampTicks,
                deviceID: deviceID
            ),
            into: &sink,
            summary: &summary
        )
    }
}
