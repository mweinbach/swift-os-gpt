private struct DWC2TestRegisters: DWC2RegisterAccess {
    let words: UnsafeMutableBufferPointer<UInt32>
    var emulateHardwareCompletion = true

    mutating func read32(at offset: UInt) -> UInt32 {
        words[Int(offset / 4)]
    }

    mutating func write32(_ value: UInt32, at offset: UInt) {
        let index = Int(offset / 4)
        if offset == DWC2RegisterLayout.resetControl,
           emulateHardwareCompletion,
           value & (
               DWC2CoreBits.coreSoftReset
                   | DWC2CoreBits.transmitFIFOFlush
                   | DWC2CoreBits.receiveFIFOFlush
           ) != 0 {
            words[index] = DWC2CoreBits.ahbIdle
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

    private func isEndpointInterrupt(_ offset: UInt) -> Bool {
        guard offset >= 0x908, offset <= 0xcf8 else { return false }
        let member = offset & 0x1f
        let block = offset & 0xf00
        return member == 0x08 && (block == 0x900 || block == 0xb00)
    }
}

@main
struct DWC2DeviceControllerTests {
    static func main() {
        initializesADeviceCapableCore()
        rejectsInvalidAndTimedOutCores()
        handlesResetEnumerationAndConfiguration()
        queuesBoundedInAndOutTransfers()
        drainsReceivePacketsAndMalformedEntries()
        reportsInterruptSnapshots()
        print("DWC2 device controller: 6 groups passed")
    }

    private static func initializesADeviceCapableCore() {
        withRegisters { words in
            configureCapableCore(words)
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words)
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
                words[Int(DWC2RegisterLayout.usbConfiguration / 4)]
                    & DWC2CoreBits.forceDeviceMode != 0,
                "device mode was not forced"
            )
            expect(
                words[Int(DWC2RegisterLayout.ahbConfiguration / 4)]
                    & DWC2CoreBits.ahbGlobalInterruptEnable == 0,
                "polled driver enabled unowned IRQ delivery"
            )
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
                controller.armEndpoint0Out(byteCount: 0),
                "endpoint-zero OUT status was not armed"
            )
            guard let outSize = DWC2RegisterLayout.outEndpointTransferSize(0)
            else { fail("endpoint-zero OUT size missing") }
            expect(
                words[Int(outSize / 4)] == 1 << 19,
                "endpoint-zero OUT status size is wrong"
            )
            controller.deconfigureCompositeEndpoints()
            expect(controller.state == .connected, "deconfigure state is wrong")
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
        words[Int(DWC2RegisterLayout.hardwareConfiguration2 / 4)]
            = 2 | (2 << 3) | (7 << 10) | (1 << 19)
        words[Int(DWC2RegisterLayout.hardwareConfiguration3 / 4)] = 4_080 << 16
        words[Int(DWC2RegisterLayout.hardwareConfiguration4 / 4)]
            = (7 << 26) | (1 << 25)
        words[Int(DWC2RegisterLayout.resetControl / 4)] = DWC2CoreBits.ahbIdle
        words[Int(DWC2RegisterLayout.deviceControl / 4)]
            = DWC2CoreBits.softDisconnect
    }

    private static func withReadyController(
        _ body: (
            inout DWC2Controller<DWC2TestRegisters>,
            UnsafeMutableBufferPointer<UInt32>
        ) -> Void
    ) {
        withRegisters { words in
            configureCapableCore(words)
            var controller = DWC2Controller(
                registers: DWC2TestRegisters(words: words)
            )
            guard case .ready = controller.initialize(maximumPollCount: 4) else {
                fail("test controller initialization failed")
            }
            body(&controller, words)
        }
    }

    private static func withConfiguredController(
        _ body: (
            inout DWC2Controller<DWC2TestRegisters>,
            UnsafeMutableBufferPointer<UInt32>
        ) -> Void
    ) {
        withReadyController { controller, words in
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
