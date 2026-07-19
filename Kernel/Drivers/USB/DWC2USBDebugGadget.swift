enum USBDebugGadgetState: UInt8, Equatable {
    case attached
    case enumerated
    case configured
    case faulted
}

enum USBDebugGadgetEvent: Equatable {
    case none
    case busReset
    case enumerated(DWC2BusSpeed)
    case configured
    case deconfigured
    case frameCompleted(UInt64)
    case faulted
}

private enum DWC2USBDebugScratchLayout {
    static let controlReplyOffset = 0
    static let controlReplyByteCount = 128
    static let receiveOffset = 128
    static let receiveByteCount = 64
    static let displayPacketOffset = 256
    static let displayPacketByteCount =
        USBDebugDisplayProtocol.maximumPacketByteCount
    static let requiredByteCount = displayPacketOffset
        + displayPacketByteCount
}

/// Composite USB gadget runtime for the polled DWC2 engine. Endpoint zero is
/// driven by the controller-neutral Chapter 9 policy. The display protocol is
/// sent over CDC data IN for immediate `/dev/cu.usbmodem*` compatibility on a
/// development Mac; the dedicated vendor endpoint remains available for a
/// future native high-throughput host driver.
struct DWC2USBDebugGadget<Registers: DWC2RegisterAccess> {
    static var readyMarker: StaticString { "SWIFTOS:USB_DEBUG_ATTACHED\n" }
    static var configuredMarker: StaticString { "SWIFTOS:USB_DEBUG_CONFIGURED\n" }
    static var frameMarker: StaticString { "SWIFTOS:USB_DEBUG_FRAME\n" }

    private enum EndpointZeroTransaction: UInt8 {
        case idle
        case dataIn
        case dataOut
        case statusIn
        case statusOut
        case stalled
    }

    private var controller: DWC2Controller<Registers>
    private var controlEndpoint = USBControlEndpoint(speed: .full)
    private var displayTransmitter: USBDebugDisplayTransmitter
    private let scratchBaseAddress: UInt
    private var endpointZeroTransaction: EndpointZeroTransaction = .idle
    private var displayTransferInFlight = false
    private(set) var state: USBDebugGadgetState = .attached

    init?(
        registers: Registers,
        scratchBaseAddress: UInt64,
        scratchByteCount: UInt64,
        scanout: ScanoutBuffer,
        viewportScale: UInt16,
        sessionID: UInt64,
        maximumInitializationPollCount: Int = 100_000
    ) {
        guard scratchBaseAddress <= UInt64(UInt.max),
              scratchByteCount >= UInt64(
                  DWC2USBDebugScratchLayout.requiredByteCount
              ),
              scratchByteCount <= UInt64.max - scratchBaseAddress,
              viewportScale > 0
        else {
            return nil
        }
        var controller = DWC2Controller(registers: registers)
        guard case .ready = controller.initialize(
                  maximumPollCount: maximumInitializationPollCount
              ), controller.connect(),
              let transmitter = USBDebugDisplayTransmitter(
                  sourceBaseAddress: scanout.mapping.cpuPhysicalAddress,
                  sourceByteCount: scanout.requiredByteCount,
                  mode: scanout.mode,
                  bytesPerRow: scanout.bytesPerRow,
                  scaleNumerator: viewportScale,
                  sessionID: sessionID,
                  // Endpoint 2 has a 128-word FIFO. Header + chunk prefix +
                  // data must fit in one 512-byte high-speed bulk transfer.
                  maximumChunkDataByteCount: 456
              )
        else {
            return nil
        }
        self.controller = controller
        displayTransmitter = transmitter
        self.scratchBaseAddress = UInt(scratchBaseAddress)
    }

    var isOperational: Bool {
        state != .faulted
    }

    mutating func requestFullFrame() {
        guard state != .faulted else { return }
        displayTransmitter.requestFullFrame()
    }

    mutating func requestDamage(_ damage: DamageRectangle) {
        guard state != .faulted else { return }
        displayTransmitter.requestDamage(damage)
    }

    mutating func service() -> USBDebugGadgetEvent {
        guard state != .faulted else { return .faulted }
        let snapshot = controller.interruptSnapshot()
        var event: USBDebugGadgetEvent = .none

        if snapshot.didReset {
            guard controller.handleBusReset() else { return fail() }
            controlEndpoint.busReset()
            displayTransmitter.resetSession(requestFullFrame: true)
            endpointZeroTransaction = .idle
            displayTransferInFlight = false
            state = .attached
            event = .busReset
        }

        if snapshot.didEnumerate {
            controller.handleEnumerationDone()
            controlEndpoint = USBControlEndpoint(
                speed: controller.busSpeed == .high ? .high : .full
            )
            state = .enumerated
            event = .enumerated(controller.busSpeed)
        }

        if snapshot.hasReceiveFIFOEntry {
            let receive = receiveBuffer
            let receiveResult = controller.pollReceive(into: receive)
            switch receiveResult {
            case .noPacket:
                break
            case .malformedStatus:
                return fail()
            case .packet(let status, let copiedByteCount, let wasTruncated):
                guard !wasTruncated else { return fail() }
                if let receiveEvent = handleReceivePacket(
                    status: status,
                    copiedByteCount: copiedByteCount
                ), receiveEvent != .none {
                    event = receiveEvent
                }
            }
        }

        if snapshot.hasInEndpointInterrupt(0) {
            guard let interrupt = controller.endpointInterruptStatus(
                      endpoint: 0,
                      directionIn: true
                  )
            else { return fail() }
            controller.acknowledgeEndpointInterrupts(
                endpoint: 0,
                directionIn: true,
                mask: interrupt
            )
            if interrupt & DWC2CoreBits.endpointTransferComplete != 0,
               let completionEvent = completeEndpointZeroIn(),
               completionEvent != .none {
                event = completionEvent
            }
        }

        if snapshot.hasOutEndpointInterrupt(0) {
            guard let interrupt = controller.endpointInterruptStatus(
                      endpoint: 0,
                      directionIn: false
                  )
            else { return fail() }
            controller.acknowledgeEndpointInterrupts(
                endpoint: 0,
                directionIn: false,
                mask: interrupt
            )
            if interrupt & DWC2CoreBits.endpointTransferComplete != 0,
               endpointZeroTransaction == .statusOut {
                endpointZeroTransaction = .idle
                guard controller.armEndpoint0ForSetup() else { return fail() }
            }
        }

        if snapshot.hasInEndpointInterrupt(2) {
            guard let interrupt = controller.endpointInterruptStatus(
                      endpoint: 2,
                      directionIn: true
                  )
            else { return fail() }
            controller.acknowledgeEndpointInterrupts(
                endpoint: 2,
                directionIn: true,
                mask: interrupt
            )
            if interrupt & DWC2CoreBits.endpointTransferComplete != 0,
               displayTransferInFlight {
                let completedFrame = displayTransmitter.phase == .frameEnd
                    ? displayTransmitter.activeFrameID
                    : 0
                guard displayTransmitter.commitPreparedPacket() else {
                    return fail()
                }
                displayTransferInFlight = false
                if completedFrame != 0 {
                    event = .frameCompleted(completedFrame)
                }
            }
        }

        serviceDiscardedOutEndpoint(2, snapshot: snapshot)
        serviceDiscardedOutEndpoint(3, snapshot: snapshot)

        let acknowledged = snapshot.global & (
            DWC2CoreBits.usbResetInterrupt
                | DWC2CoreBits.enumerationDoneInterrupt
                | DWC2CoreBits.usbSuspendInterrupt
                | DWC2CoreBits.wakeupInterrupt
        )
        if acknowledged != 0 {
            controller.acknowledgeGlobalInterrupts(acknowledged)
        }

        if state == .configured && !displayTransferInFlight {
            let packet = displayPacketBuffer
            let transmitResult = displayTransmitter.prepareNextPacket(
                into: packet
            )
            switch transmitResult {
            case .idle:
                break
            case .faulted, .outputBufferTooSmall:
                return fail()
            case .packet(let byteCount):
                let bytes = UnsafeRawBufferPointer(
                    start: packet.baseAddress,
                    count: byteCount
                )
                let result = controller.queueInTransfer(
                    endpoint: 2,
                    bytes: bytes
                )
                switch result {
                case .queued:
                    displayTransferInFlight = true
                case .fifoBusy:
                    break
                case .invalidState, .invalidEndpoint,
                     .invalidBuffer, .invalidTransferSize:
                    return fail()
                }
            }
        }
        return event
    }

    private mutating func handleReceivePacket(
        status: DWC2ReceiveStatus,
        copiedByteCount: UInt16
    ) -> USBDebugGadgetEvent? {
        switch status.packetStatus {
        case .setupDataReceived:
            guard copiedByteCount == USBSetupPacket.byteCount else {
                return fail()
            }
            controller.clearEndpoint0Stall()
            let receive = receiveBuffer
            let setup = USBSetupPacket.parse(
                UnsafeRawBufferPointer(
                    start: receive.baseAddress,
                    count: USBSetupPacket.byteCount
                )
            )
            guard let setup else { return fail() }
            let reply = controlReplyBuffer
            let action = controlEndpoint.handle(setup, reply: reply)
            return performControlAction(action)

        case .outDataReceived:
            if status.endpoint == 0,
               endpointZeroTransaction == .dataOut {
                let receive = receiveBuffer
                let action = controlEndpoint.acceptDataOut(
                    UnsafeRawBufferPointer(
                        start: receive.baseAddress,
                        count: Int(copiedByteCount)
                    )
                )
                return performControlAction(action)
            }
            if status.endpoint == 2 || status.endpoint == 3 {
                _ = controller.armOutTransfer(
                    endpoint: status.endpoint,
                    byteCount: UInt32(controller.busSpeed.bulkMaximumPacketSize)
                )
            }
            return USBDebugGadgetEvent.none

        case .globalOutNAK, .outTransferComplete,
             .setupTransactionComplete, .dataToggleError:
            return USBDebugGadgetEvent.none
        }
    }

    private mutating func performControlAction(
        _ action: USBControlAction
    ) -> USBDebugGadgetEvent? {
        switch action {
        case .dataIn(let byteCount):
            let reply = controlReplyBuffer
            let result = controller.queueInTransfer(
                endpoint: 0,
                bytes: UnsafeRawBufferPointer(
                    start: reply.baseAddress,
                    count: Int(byteCount)
                )
            )
            guard result == .queued else { return fail() }
            endpointZeroTransaction = .dataIn
            return USBDebugGadgetEvent.none

        case .dataOut(let expectedByteCount):
            guard expectedByteCount <= 64,
                  controller.armEndpoint0Out(byteCount: expectedByteCount)
            else { return fail() }
            endpointZeroTransaction = .dataOut
            return USBDebugGadgetEvent.none

        case .statusIn:
            let result = controller.queueInTransfer(
                endpoint: 0,
                bytes: UnsafeRawBufferPointer(start: nil, count: 0)
            )
            guard result == .queued else { return fail() }
            endpointZeroTransaction = .statusIn
            return USBDebugGadgetEvent.none

        case .stall, .replyBufferTooSmall:
            controller.stallEndpoint0()
            guard controller.armEndpoint0ForSetup(preservingStall: true) else {
                return fail()
            }
            endpointZeroTransaction = .stalled
            return USBDebugGadgetEvent.none
        }
    }

    private mutating func completeEndpointZeroIn() -> USBDebugGadgetEvent? {
        switch endpointZeroTransaction {
        case .dataIn:
            guard controller.armEndpoint0Out(byteCount: 0) else {
                return fail()
            }
            endpointZeroTransaction = .statusOut
            return USBDebugGadgetEvent.none

        case .statusIn:
            let commit = controlEndpoint.completeStatusStage(succeeded: true)
            if case .deviceAddress(let address) = commit {
                controller.setDeviceAddress(address)
            }
            endpointZeroTransaction = .idle
            guard controller.armEndpoint0ForSetup() else { return fail() }
            guard let configurationEvent = synchronizeConfiguration() else {
                return nil
            }
            guard synchronizeEndpointHalts() else { return fail() }
            return configurationEvent

        case .idle, .dataOut, .statusOut, .stalled:
            return USBDebugGadgetEvent.none
        }
    }

    private mutating func synchronizeConfiguration() -> USBDebugGadgetEvent? {
        if controlEndpoint.state == .configured {
            if controller.state != .configured {
                guard controller.configureCompositeEndpoints(),
                      controller.armOutTransfer(
                          endpoint: 2,
                          byteCount: UInt32(
                              controller.busSpeed.bulkMaximumPacketSize
                          )
                      ) == .queued,
                      controller.armOutTransfer(
                          endpoint: 3,
                          byteCount: UInt32(
                              controller.busSpeed.bulkMaximumPacketSize
                          )
                      ) == .queued
                else { return fail() }
            }
            displayTransmitter.resetSession(requestFullFrame: true)
            displayTransferInFlight = false
            state = .configured
            return .configured
        }
        if controller.state == .configured {
            controller.deconfigureCompositeEndpoints()
            displayTransferInFlight = false
            state = .enumerated
            return .deconfigured
        }
        return USBDebugGadgetEvent.none
    }

    private mutating func synchronizeEndpointHalts() -> Bool {
        guard controlEndpoint.state == .configured else { return true }
        let endpointAddresses: (UInt8, UInt8, UInt8, UInt8, UInt8) = (
            USBDebugDeviceIdentity.cdcNotificationEndpoint,
            USBDebugDeviceIdentity.cdcDataOutEndpoint,
            USBDebugDeviceIdentity.cdcDataInEndpoint,
            USBDebugDeviceIdentity.debugDisplayOutEndpoint,
            USBDebugDeviceIdentity.debugDisplayInEndpoint
        )
        return synchronizeEndpointHalt(endpointAddresses.0)
            && synchronizeEndpointHalt(endpointAddresses.1)
            && synchronizeEndpointHalt(endpointAddresses.2)
            && synchronizeEndpointHalt(endpointAddresses.3)
            && synchronizeEndpointHalt(endpointAddresses.4)
    }

    private mutating func synchronizeEndpointHalt(_ address: UInt8) -> Bool {
        controller.setEndpointHalt(
            endpointAddress: address,
            halted: controlEndpoint.isEndpointHalted(address)
        )
    }

    private mutating func serviceDiscardedOutEndpoint(
        _ endpoint: UInt8,
        snapshot: DWC2InterruptSnapshot
    ) {
        guard snapshot.hasOutEndpointInterrupt(endpoint),
              let interrupt = controller.endpointInterruptStatus(
                  endpoint: endpoint,
                  directionIn: false
              )
        else { return }
        controller.acknowledgeEndpointInterrupts(
            endpoint: endpoint,
            directionIn: false,
            mask: interrupt
        )
    }

    private var controlReplyBuffer: UnsafeMutableRawBufferPointer {
        buffer(
            offset: DWC2USBDebugScratchLayout.controlReplyOffset,
            count: DWC2USBDebugScratchLayout.controlReplyByteCount
        )
    }

    private var receiveBuffer: UnsafeMutableRawBufferPointer {
        buffer(
            offset: DWC2USBDebugScratchLayout.receiveOffset,
            count: DWC2USBDebugScratchLayout.receiveByteCount
        )
    }

    private var displayPacketBuffer: UnsafeMutableRawBufferPointer {
        buffer(
            offset: DWC2USBDebugScratchLayout.displayPacketOffset,
            count: DWC2USBDebugScratchLayout.displayPacketByteCount
        )
    }

    private func buffer(
        offset: Int,
        count: Int
    ) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            start: UnsafeMutableRawPointer(bitPattern: scratchBaseAddress)?
                .advanced(by: offset),
            count: count
        )
    }

    private mutating func fail() -> USBDebugGadgetEvent {
        controller.disconnect()
        state = .faulted
        displayTransferInFlight = false
        return .faulted
    }
}
