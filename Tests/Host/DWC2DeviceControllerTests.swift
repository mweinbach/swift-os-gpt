private enum DWC2EndpointDisableCompletion {
    case clearEnable
    case endpointInterrupt
    case stalled
}

private final class DWC2TestTrace {
    var deviceControlWrites = [UInt32]()
    var powerSettleCount = 0
    var powerSettleResult = true
    var holdAHBNonIdleAfterReceiveFlush = false
    var endpointDisableCompletion = DWC2EndpointDisableCompletion.clearEnable
    var endpointDisableRequestCount = 0
    var endpointDisableCompletionCount = 0
    var fifoFlushWriteCount = 0
    var firstFIFOFlushRequestCount: Int?
    var firstFIFOFlushCompletionCount: Int?

    func resetRestartObservations() {
        endpointDisableRequestCount = 0
        endpointDisableCompletionCount = 0
        fifoFlushWriteCount = 0
        firstFIFOFlushRequestCount = nil
        firstFIFOFlushCompletionCount = nil
    }
}

private struct DWC2TestRegisters: DWC2RegisterAccess {
    let words: UnsafeMutableBufferPointer<UInt32>
    var emulateHardwareCompletion = true
    let trace: DWC2TestTrace

    init(
        words: UnsafeMutableBufferPointer<UInt32>,
        emulateHardwareCompletion: Bool = true,
        trace: DWC2TestTrace = DWC2TestTrace()
    ) {
        self.words = words
        self.emulateHardwareCompletion = emulateHardwareCompletion
        self.trace = trace
    }

    mutating func read32(at offset: UInt) -> UInt32 {
        words[Int(offset / 4)]
    }

    mutating func write32(_ value: UInt32, at offset: UInt) {
        let index = Int(offset / 4)
        if let interrupt = endpointInterrupt(forControl: offset),
           value & DWC2CoreBits.endpointDisable != 0,
           words[index] & DWC2CoreBits.endpointEnable != 0 {
            trace.endpointDisableRequestCount += 1
            switch trace.endpointDisableCompletion {
            case .clearEnable:
                words[index] = value & ~DWC2CoreBits.endpointEnable
                trace.endpointDisableCompletionCount += 1
            case .endpointInterrupt:
                words[index] = value
                words[Int(interrupt / 4)] |= DWC2CoreBits.endpointDisabled
                trace.endpointDisableCompletionCount += 1
            case .stalled:
                words[index] = value
            }
            return
        }
        if offset == DWC2RegisterLayout.resetControl,
           emulateHardwareCompletion,
           value & (
               DWC2CoreBits.coreSoftReset
                   | DWC2CoreBits.transmitFIFOFlush
                   | DWC2CoreBits.receiveFIFOFlush
           ) != 0 {
            if value & (
                DWC2CoreBits.transmitFIFOFlush
                    | DWC2CoreBits.receiveFIFOFlush
            ) != 0 {
                trace.fifoFlushWriteCount += 1
                if trace.firstFIFOFlushRequestCount == nil {
                    trace.firstFIFOFlushRequestCount =
                        trace.endpointDisableRequestCount
                    trace.firstFIFOFlushCompletionCount =
                        trace.endpointDisableCompletionCount
                }
            }
            words[index] = trace.holdAHBNonIdleAfterReceiveFlush
                && value & DWC2CoreBits.receiveFIFOFlush != 0
                ? 0 : DWC2CoreBits.ahbIdle
            return
        }
        if offset == DWC2RegisterLayout.deviceControl {
            trace.deviceControlWrites.append(value)
            words[index] = value & ~DWC2CoreBits.deviceControlCommandMask
            return
        }
        if offset == DWC2RegisterLayout.interruptStatus {
            words[index] &= ~value
            return
        }
        if isEndpointInterrupt(offset) {
            words[index] &= ~value
            return
        }
        words[index] = value
    }

    mutating func settleAfterPowerOnProgramming() -> Bool {
        trace.powerSettleCount += 1
        return trace.powerSettleResult
    }

    private func isEndpointInterrupt(_ offset: UInt) -> Bool {
        guard offset >= 0x908, offset <= 0xcf8 else { return false }
        let member = offset & 0x1f
        let block = offset & 0xf00
        return member == 0x08 && (block == 0x900 || block == 0xb00)
    }

    private func endpointInterrupt(forControl offset: UInt) -> UInt? {
        guard offset >= 0x900, offset <= 0xcf0,
              offset & 0x1f == 0
        else { return nil }
        let block = offset & 0xf00
        guard block == 0x900 || block == 0xb00 else { return nil }
        return offset + 8
    }
}

@main
struct DWC2DeviceControllerTests {
    static func main() {
        initializesADeviceCapableCore()
        initializesSixteenBitUTMI()
        rejectsInvalidAndTimedOutCores()
        rejectsIncompatibleEndpointDirections()
        handlesResetEnumerationAndConfiguration()
        queuesEndpointZeroOnlyWithGlobalCapacity()
        queuesBoundedInAndOutTransfers()
        quiescesControllerForRestartWithBoundedAHBWait()
        drainsReceivePacketsAndMalformedEntries()
        reportsInterruptSnapshots()
        print("DWC2 device controller: 10 groups passed")
    }

    private static func initializesADeviceCapableCore() {
        withRegisters { words in
            configureCapableCore(words)
            let trace = DWC2TestTrace()
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words, trace: trace)
            )
            guard case .ready(let capabilities) = controller.initialize(
                maximumPollCount: 4
            ) else {
                fail("valid controller did not initialize")
            }
            expect(controller.state == .disconnected, "wrong initialized state")
            expect(capabilities.fifoDepthInWords == 4_080, "capability lost")
            expect(
                words[Int(DWC2RegisterLayout.receiveFIFOSize / 4)] == 512,
                "receive FIFO was not programmed"
            )
            expect(
                words[Int(DWC2RegisterLayout.endpoint0TransmitFIFOSize / 4)]
                    == (64 << 16 | 512),
                "endpoint-zero FIFO was not programmed"
            )
            expect(
                words[Int(0x10c / 4)] == (1_024 << 16 | 720),
                "display FIFO was not programmed"
            )
            expect(
                words[Int(DWC2RegisterLayout.globalDFIFOConfiguration / 4)]
                    == (1_744 << 16 | 4_080),
                "endpoint-info base did not follow the dynamic FIFOs"
            )
            let usb = words[Int(DWC2RegisterLayout.usbConfiguration / 4)]
            expect(
                usb & DWC2CoreBits.forceDeviceMode != 0,
                "device mode was not forced"
            )
            expect(
                usb & DWC2CoreBits.usbTimeoutCalibrationMask == 7
                    && usb & DWC2CoreBits.usbTurnaroundTimeMask == 9 << 10,
                "eight-bit UTMI timing was not programmed"
            )
            expect(
                usb & (
                    DWC2CoreBits.forceHostMode
                        | DWC2CoreBits.usbPHYInterface16
                        | DWC2CoreBits.usbULPIUTMISelect
                        | DWC2CoreBits.usbFullSpeedPHYSelect
                        | DWC2CoreBits.usbDDRSelect
                        | DWC2CoreBits.usbSRPCapable
                        | DWC2CoreBits.usbHNPCapable
                ) == 0,
                "stale host, ULPI, or OTG PHY policy survived initialization"
            )
            expect(
                trace.powerSettleCount == 1
                    && trace.deviceControlWrites.contains(
                        DWC2CoreBits.softDisconnect
                            | DWC2CoreBits.powerOnProgrammingDone
                    )
                    && trace.deviceControlWrites.contains(
                        DWC2CoreBits.softDisconnect
                            | DWC2CoreBits.clearGlobalOutNAK
                            | DWC2CoreBits.clearGlobalNonPeriodicInNAK
                    ),
                "DCTL power-on and global-NAK commands were not sequenced"
            )
            expect(
                words[Int(DWC2RegisterLayout.ahbConfiguration / 4)]
                    & DWC2CoreBits.ahbGlobalInterruptEnable == 0,
                "polled driver enabled unowned IRQ delivery"
            )
        }
    }

    private static func queuesEndpointZeroOnlyWithGlobalCapacity() {
        withReadyController { controller, words in
            expect(controller.connect(), "controller did not connect")
            expect(controller.handleBusReset(), "bus reset was not handled")
            var payload: UInt32 = 0x4433_2211
            withUnsafeBytes(of: &payload) { bytes in
                words[Int(DWC2RegisterLayout.endpoint0TransmitFIFOStatus / 4)]
                    = 1 << 16 | 1
                expect(
                    controller.queueInTransfer(endpoint: 0, bytes: bytes)
                        == .queued,
                    "EP0 ignored global non-periodic transmit capacity"
                )
                words[Int(DWC2RegisterLayout.endpoint0TransmitFIFOStatus / 4)]
                    = 1 << 16
                expect(
                    controller.queueInTransfer(endpoint: 0, bytes: bytes)
                        == .fifoBusy,
                    "EP0 queued without non-periodic FIFO words"
                )
                words[Int(DWC2RegisterLayout.endpoint0TransmitFIFOStatus / 4)]
                    = 1
                expect(
                    controller.queueInTransfer(endpoint: 0, bytes: bytes)
                        == .fifoBusy,
                    "EP0 queued without a non-periodic request slot"
                )
            }
        }
    }

    private static func rejectsInvalidAndTimedOutCores() {
        withRegisters { words in
            words[Int(DWC2RegisterLayout.coreIdentifier / 4)] = 0x1234_5678
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words)
            )
            expect(
                controller.initialize(maximumPollCount: 1) == .unsupportedCore,
                "foreign core initialized"
            )
            expect(controller.state == .faulted, "failure did not latch")
        }
        withRegisters { words in
            configureCapableCore(words)
            words[Int(DWC2RegisterLayout.resetControl / 4)] = 0
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(
                    words: words,
                    emulateHardwareCompletion: false
                )
            )
            expect(
                controller.initialize(maximumPollCount: 2) == .ahbNotIdle,
                "AHB timeout was not bounded"
            )
        }
    }

    private static func initializesSixteenBitUTMI() {
        withRegisters { words in
            configureCapableCore(words)
            words[Int(DWC2RegisterLayout.hardwareConfiguration4 / 4)]
                |= 1 << 14
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words)
            )
            guard case .ready = controller.initialize(maximumPollCount: 4)
            else { fail("sixteen-bit UTMI controller did not initialize") }
            let usb = words[Int(DWC2RegisterLayout.usbConfiguration / 4)]
            expect(
                usb & DWC2CoreBits.usbPHYInterface16 != 0
                    && usb & DWC2CoreBits.usbTurnaroundTimeMask == 5 << 10,
                "sixteen-bit UTMI timing was not programmed"
            )
        }
    }

    private static func rejectsIncompatibleEndpointDirections() {
        withRegisters { words in
            configureCapableCore(words)
            words[Int(DWC2RegisterLayout.hardwareConfiguration1 / 4)] = 2 << 2
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words)
            )
            expect(
                controller.initialize(maximumPollCount: 4)
                    == .unsupportedConfiguration,
                "OUT-only endpoint 1 initialized for CDC notifications"
            )
            expect(
                controller.state == .faulted,
                "direction failure did not latch"
            )
        }
        withRegisters { words in
            configureCapableCore(words)
            words[Int(DWC2RegisterLayout.hardwareConfiguration1 / 4)] = 1 << 6
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words)
            )
            expect(
                controller.initialize(maximumPollCount: 4)
                    == .unsupportedConfiguration,
                "one-way endpoint 3 initialized for bidirectional display I/O"
            )
        }
    }

    private static func handlesResetEnumerationAndConfiguration() {
        withReadyController { controller, words in
            expect(controller.connect(), "controller did not connect")
            expect(controller.state == .connected, "wrong connected state")
            expect(controller.handleBusReset(), "bus reset was not handled")
            expect(
                words[Int(DWC2RegisterLayout.allEndpointInterruptMask / 4)]
                    == 0x0001_0001,
                "reset exposed non-control endpoints"
            )
            guard let setupSize = DWC2RegisterLayout.outEndpointTransferSize(0),
                  let setupControl = DWC2RegisterLayout.outEndpointControl(0)
            else {
                fail("endpoint-zero register missing")
            }
            expect(
                words[Int(setupSize / 4)]
                    == DWC2TransferSize.endpoint0SetupReception,
                "setup reception was not armed"
            )
            expect(
                words[Int(setupSize / 4)] & 0x7f == 24,
                "setup reception used the control endpoint MPS as XFRSIZ"
            )
            expect(
                words[Int(setupControl / 4)] & DWC2CoreBits.endpointEnable != 0,
                "endpoint zero was not enabled"
            )

            words[Int(DWC2RegisterLayout.deviceStatus / 4)] = 0
            controller.handleEnumerationDone()
            expect(controller.busSpeed == .high, "high speed was not captured")
            expect(
                controller.configureCompositeEndpoints(),
                "composite endpoints did not configure"
            )
            expect(controller.state == .configured, "wrong configured state")
            expect(
                words[Int(DWC2RegisterLayout.allEndpointInterruptMask / 4)]
                    == 0x000d_000f,
                "composite endpoint interrupt mask is wrong"
            )
            guard let displayIn = DWC2RegisterLayout.inEndpointControl(3) else {
                fail("display endpoint missing")
            }
            let displayControl = words[Int(displayIn / 4)]
            expect(
                displayControl & 0x7ff == 512,
                "high-speed display maximum packet is wrong"
            )
            expect(
                displayControl & (0xf << 22) == 3 << 22,
                "display endpoint uses the wrong FIFO"
            )
            expect(
                displayControl & DWC2CoreBits.setData0PID != 0,
                "new endpoint did not reset its data toggle"
            )
            expect(
                controller.setEndpointHalt(
                    endpointAddress: 0x83,
                    halted: true
                ),
                "display endpoint halt failed"
            )
            expect(
                words[Int(displayIn / 4)] & DWC2CoreBits.endpointStall != 0,
                "display endpoint did not stall"
            )
            expect(
                controller.setEndpointHalt(
                    endpointAddress: 0x83,
                    halted: false
                ),
                "display endpoint unhalt failed"
            )
            expect(
                words[Int(displayIn / 4)] & DWC2CoreBits.endpointStall == 0,
                "display endpoint stall did not clear"
            )
            expect(
                controller.armEndpoint0Out(byteCount: 0),
                "endpoint-zero OUT status was not armed"
            )
            guard let outSize = DWC2RegisterLayout.outEndpointTransferSize(0)
            else { fail("endpoint-zero OUT size missing") }
            expect(
                words[Int(outSize / 4)] == 1 << 19,
                "endpoint-zero OUT status size is wrong"
            )
            guard let displayFIFOStatus =
                      DWC2RegisterLayout.inEndpointFIFOStatus(3)
            else { fail("display FIFO status missing") }
            words[Int(displayFIFOStatus / 4)] = 1
            var displayWord: UInt32 = 0xaabb_ccdd
            withUnsafeBytes(of: &displayWord) { bytes in
                expect(
                    controller.queueInTransfer(endpoint: 3, bytes: bytes)
                        == .queued,
                    "display transfer did not enter flight"
                )
            }
            expect(
                controller.deconfigureCompositeEndpoints(),
                "configured endpoints did not quiesce"
            )
            expect(controller.state == .connected, "deconfigure state is wrong")
            expect(
                words[Int(displayIn / 4)]
                    & (DWC2CoreBits.endpointDisable | DWC2CoreBits.setNAK)
                    == (DWC2CoreBits.endpointDisable | DWC2CoreBits.setNAK),
                "deconfigure left the display IN transfer active"
            )
            expect(
                words[Int(DWC2RegisterLayout.allEndpointInterruptMask / 4)]
                    == 0x0001_0001,
                "deconfigure exposed data endpoints"
            )
        }
    }

    private static func queuesBoundedInAndOutTransfers() {
        withConfiguredController { controller, words in
            guard let fifoStatus = DWC2RegisterLayout.inEndpointFIFOStatus(3),
                  let transferSize = DWC2RegisterLayout.inEndpointTransferSize(3),
                  let fifo = DWC2RegisterLayout.fifoData(3)
            else {
                fail("display endpoint registers missing")
            }
            words[Int(fifoStatus / 4)] = 16
            let payload: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55]
            let result = payload.withUnsafeBytes { bytes in
                controller.queueInTransfer(endpoint: 3, bytes: bytes)
            }
            expect(result == .queued, "display transfer was not queued")
            expect(
                words[Int(transferSize / 4)] == (1 << 19 | 5),
                "display transfer size is wrong"
            )
            expect(
                words[Int(fifo / 4)] == 0x0000_0055,
                "trailing display FIFO word was not zero padded"
            )
            words[Int(fifoStatus / 4)] = 0
            expect(
                payload.withUnsafeBytes {
                    controller.queueInTransfer(endpoint: 3, bytes: $0)
                } == .fifoBusy,
                "full FIFO accepted another transfer"
            )
            expect(
                controller.armOutTransfer(endpoint: 3, byteCount: 1_024)
                    == .queued,
                "display command OUT transfer was not armed"
            )
            expect(
                controller.armOutTransfer(endpoint: 1, byteCount: 64)
                    == .invalidEndpoint,
                "notification endpoint accepted OUT data"
            )
        }
    }

    private static func quiescesControllerForRestartWithBoundedAHBWait() {
        let completionTrace = DWC2TestTrace()
        withConfiguredController(trace: completionTrace) { controller, words in
            expect(
                controller.armOutTransfer(endpoint: 2, byteCount: 512)
                    == .queued,
                "restart fixture did not arm endpoint two OUT"
            )
            guard let fifoStatus =
                    DWC2RegisterLayout.inEndpointFIFOStatus(2)
            else { fail("restart endpoint FIFO status missing") }
            words[Int(fifoStatus / 4)] = 128
            var word: UInt32 = 0xa5a5_5a5a
            withUnsafeBytes(of: &word) { bytes in
                expect(
                    controller.queueInTransfer(endpoint: 2, bytes: bytes)
                        == .queued,
                    "restart fixture did not queue endpoint two IN"
                )
            }
            completionTrace.resetRestartObservations()
            expect(
                controller.quiesceForRestart(maximumPollCount: 4),
                "restart quiesce failed"
            )
            expect(
                controller.state == .disconnected,
                "restart quiesce did not disconnect"
            )
            expect(
                words[Int(DWC2RegisterLayout.deviceControl / 4)]
                    & DWC2CoreBits.softDisconnect != 0,
                "restart quiesce did not assert soft disconnect"
            )
            expect(
                words[Int(DWC2RegisterLayout.interruptMask / 4)] == 0
                    && words[Int(
                        DWC2RegisterLayout.allEndpointInterruptMask / 4
                    )] == 0,
                "restart quiesce left interrupts enabled"
            )
            guard let endpointTwoIn =
                    DWC2RegisterLayout.inEndpointControl(2),
                  let endpointTwoOut =
                    DWC2RegisterLayout.outEndpointControl(2)
            else { fail("restart endpoint registers missing") }
            let quiesceBits = DWC2CoreBits.endpointDisable
                | DWC2CoreBits.setNAK
            expect(
                words[Int(endpointTwoIn / 4)] & quiesceBits == quiesceBits
                    && words[Int(endpointTwoOut / 4)] & quiesceBits
                        == quiesceBits,
                "restart quiesce left endpoint two active"
            )
            expect(
                words[Int(endpointTwoIn / 4)]
                    & DWC2CoreBits.endpointEnable == 0
                    && words[Int(endpointTwoOut / 4)]
                        & DWC2CoreBits.endpointEnable == 0,
                "restart quiesce did not observe endpoint disable completion"
            )
            expect(
                completionTrace.endpointDisableRequestCount >= 3,
                "restart quiesce did not command every active endpoint"
            )
            expect(
                completionTrace.firstFIFOFlushRequestCount
                    == completionTrace.endpointDisableRequestCount
                    && completionTrace.firstFIFOFlushCompletionCount
                        == completionTrace.endpointDisableCompletionCount
                    && completionTrace.endpointDisableCompletionCount
                        == completionTrace.endpointDisableRequestCount,
                "restart quiesce flushed before endpoint disable completion"
            )
        }

        let interruptTrace = DWC2TestTrace()
        interruptTrace.endpointDisableCompletion = .endpointInterrupt
        withConfiguredController(trace: interruptTrace) { controller, _ in
            expect(
                controller.armOutTransfer(endpoint: 2, byteCount: 512)
                    == .queued,
                "endpoint interrupt fixture did not arm endpoint two"
            )
            interruptTrace.resetRestartObservations()
            expect(
                controller.quiesceForRestart(maximumPollCount: 4),
                "restart quiesce ignored endpoint-disabled interrupts"
            )
            expect(
                interruptTrace.endpointDisableCompletionCount
                    == interruptTrace.endpointDisableRequestCount,
                "endpoint-disabled interrupt fixture did not complete"
            )
        }

        let endpointTimeoutTrace = DWC2TestTrace()
        withConfiguredController(trace: endpointTimeoutTrace) {
            controller, _ in
            expect(
                controller.armOutTransfer(endpoint: 2, byteCount: 512)
                    == .queued,
                "endpoint timeout fixture did not arm endpoint two"
            )
            endpointTimeoutTrace.endpointDisableCompletion = .stalled
            endpointTimeoutTrace.resetRestartObservations()
            expect(
                !controller.quiesceForRestart(maximumPollCount: 2),
                "restart quiesce ignored endpoint disable timeout"
            )
            expect(
                endpointTimeoutTrace.endpointDisableRequestCount >= 2
                    && endpointTimeoutTrace.endpointDisableCompletionCount == 0,
                "endpoint timeout fixture did not retain active endpoints"
            )
            expect(
                endpointTimeoutTrace.fifoFlushWriteCount == 0,
                "restart quiesce flushed FIFOs after endpoint timeout"
            )
        }

        withRegisters { words in
            configureCapableCore(words)
            let trace = DWC2TestTrace()
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words, trace: trace)
            )
            guard case .ready = controller.initialize(maximumPollCount: 4),
                  controller.connect()
            else { fail("AHB timeout fixture did not initialize") }
            trace.holdAHBNonIdleAfterReceiveFlush = true
            expect(
                !controller.quiesceForRestart(maximumPollCount: 2),
                "restart quiesce ignored final AHB non-idle state"
            )
        }
    }

    private static func drainsReceivePacketsAndMalformedEntries() {
        withReadyController { controller, words in
            expect(controller.connect(), "controller did not connect")
            expect(controller.handleBusReset(), "reset failed")
            let receiveStatus = 8 << 4 | 6 << 17
            words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                = DWC2CoreBits.receiveFIFOLevelInterrupt
            words[Int(DWC2RegisterLayout.receiveStatusPop / 4)]
                = UInt32(receiveStatus)
            guard let fifo = DWC2RegisterLayout.fifoData(0) else {
                fail("receive FIFO missing")
            }
            words[Int(fifo / 4)] = 0x4433_2211
            var bytes = [UInt8](repeating: 0, count: 8)
            let result = bytes.withUnsafeMutableBytes {
                controller.pollReceive(into: $0)
            }
            guard case .packet(let status, let copied, let truncated) = result else {
                fail("setup packet was not returned")
            }
            expect(status.packetStatus == .setupDataReceived, "wrong packet")
            expect(copied == 8 && !truncated, "setup packet was truncated")
            expect(
                bytes[0] == 0x11 && bytes[4] == 0x11,
                "receive FIFO bytes were not unpacked"
            )

            words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                = DWC2CoreBits.receiveFIFOLevelInterrupt
            words[Int(DWC2RegisterLayout.receiveStatusPop / 4)] = 4 << 4 | 7 << 17
            words[Int(fifo / 4)] = 0xaabb_ccdd
            let malformed = bytes.withUnsafeMutableBytes {
                controller.pollReceive(into: $0)
            }
            expect(
                malformed == .malformedStatus(
                    rawValue: UInt32(4 << 4 | 7 << 17),
                    drainedByteCount: 4
                ),
                "malformed entry did not drain deterministically"
            )
        }
    }

    private static func reportsInterruptSnapshots() {
        withConfiguredController { controller, words in
            words[Int(DWC2RegisterLayout.interruptStatus / 4)]
                = DWC2CoreBits.usbResetInterrupt
                | DWC2CoreBits.enumerationDoneInterrupt
            words[Int(DWC2RegisterLayout.allEndpointInterrupts / 4)]
                = 1 << 3 | 1 << 19
            words[Int(DWC2RegisterLayout.deviceStatus / 4)] = 1 << 1
            let snapshot = controller.interruptSnapshot()
            expect(snapshot.didReset, "reset interrupt missing")
            expect(snapshot.didEnumerate, "enumeration interrupt missing")
            expect(snapshot.busSpeed == .full, "bus speed decoded incorrectly")
            expect(snapshot.hasInEndpointInterrupt(3), "IN endpoint missing")
            expect(snapshot.hasOutEndpointInterrupt(3), "OUT endpoint missing")
            expect(!snapshot.hasInEndpointInterrupt(16), "invalid endpoint set")
        }
    }

    private static func configureCapableCore(
        _ words: UnsafeMutableBufferPointer<UInt32>
    ) {
        words[Int(DWC2RegisterLayout.coreIdentifier / 4)] = 0x4f54_280a
        words[Int(DWC2RegisterLayout.hardwareConfiguration1 / 4)] = 1 << 2
        let configuration2: UInt32 = 2 | (2 << 3) | (1 << 6)
            | (7 << 10) | (1 << 19)
        words[Int(DWC2RegisterLayout.hardwareConfiguration2 / 4)]
            = configuration2
        words[Int(DWC2RegisterLayout.hardwareConfiguration3 / 4)] = 4_080 << 16
        words[Int(DWC2RegisterLayout.hardwareConfiguration4 / 4)]
            = (7 << 26) | (1 << 25)
        words[Int(DWC2RegisterLayout.resetControl / 4)] = DWC2CoreBits.ahbIdle
        words[Int(DWC2RegisterLayout.deviceControl / 4)]
            = DWC2CoreBits.softDisconnect
        words[Int(DWC2RegisterLayout.usbConfiguration / 4)]
            = DWC2CoreBits.forceHostMode
                | DWC2CoreBits.usbPHYInterface16
                | DWC2CoreBits.usbULPIUTMISelect
                | DWC2CoreBits.usbFullSpeedPHYSelect
                | DWC2CoreBits.usbDDRSelect
                | DWC2CoreBits.usbSRPCapable
                | DWC2CoreBits.usbHNPCapable
        words[Int(DWC2RegisterLayout.endpoint0TransmitFIFOStatus / 4)]
            = 1 << 16 | 64
    }

    private static func withReadyController(
        trace: DWC2TestTrace = DWC2TestTrace(),
        _ body: (
            inout DWC2Controller<DWC2TestRegisters>,
            UnsafeMutableBufferPointer<UInt32>
        ) -> Void
    ) {
        withRegisters { words in
            configureCapableCore(words)
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words, trace: trace)
            )
            guard case .ready = controller.initialize(maximumPollCount: 4) else {
                fail("test controller initialization failed")
            }
            body(&controller, words)
        }
    }

    private static func withConfiguredController(
        trace: DWC2TestTrace = DWC2TestTrace(),
        _ body: (
            inout DWC2Controller<DWC2TestRegisters>,
            UnsafeMutableBufferPointer<UInt32>
        ) -> Void
    ) {
        withReadyController(trace: trace) { controller, words in
            expect(controller.connect(), "test controller did not connect")
            expect(controller.handleBusReset(), "test reset failed")
            words[Int(DWC2RegisterLayout.deviceStatus / 4)] = 0
            controller.handleEnumerationDone()
            expect(controller.configureCompositeEndpoints(), "test config failed")
            body(&controller, words)
        }
    }

    private static func withRegisters(
        _ body: (UnsafeMutableBufferPointer<UInt32>) -> Void
    ) {
        let words = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: 0x5_000 / 4)
        words.initialize(repeating: 0)
        defer {
            words.deinitialize()
            words.deallocate()
        }
        body(words)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("\(message)")
    }
}
