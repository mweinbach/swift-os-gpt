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
    static let endpointZeroMaximumPacketByteCount: UInt16 = 64
    static let controlReplyOffset = 0
    static let controlReplyByteCount = 128
    static let receiveOffset = 128
    static let receiveByteCount = 64
    static let endpointZeroReceiveStageOffset = 192
    static let endpointZeroReceiveStageByteCount = 64
    static let displayPacketOffset = 256
    static let displayPacketByteCount =
        USBDebugDisplayProtocol.maximumPacketByteCount
    static let requiredByteCount = displayPacketOffset
        + displayPacketByteCount
}

private enum EndpointZeroInQueueResult {
    case queued
    case complete
    case failed
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

    private enum EndpointZeroReceiveStage: UInt8 {
        case idle
        case setup
        case dataOut
        case statusOut
    }

    private var controller: DWC2Controller<Registers>
    private var controlEndpoint = USBControlEndpoint(speed: .full)
    private var displayTransmitter: USBDebugDisplayTransmitter
    private let scratchBaseAddress: UInt
    private var endpointZeroTransaction: EndpointZeroTransaction = .idle
    private var endpointZeroRequestedByteCount: UInt16 = 0
    private var endpointZeroInReplyByteCount: UInt16 = 0
    private var endpointZeroInQueuedByteCount: UInt16 = 0
    private var endpointZeroInNeedsZeroLengthPacket = false
    private var endpointZeroInQueuedZeroLengthPacket = false
    private var endpointZeroReceiveStage: EndpointZeroReceiveStage = .idle
    private var endpointZeroStagedByteCount: UInt16 = 0
    private var endpointZeroExpectedOutByteCount: UInt16 = 0
    private var endpointZeroPendingDisplayOpenState: Bool?
    private var displayEndpointOpen = false
    private var displaySessionResetPending = false
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
            resetEndpointZeroTransaction()
            displayEndpointOpen = false
            displaySessionResetPending = false
            displayTransferInFlight = false
            state = .attached
            event = .busReset
        }

        if snapshot.didEnumerate {
            controller.handleEnumerationDone()
            controlEndpoint = USBControlEndpoint(
                speed: controller.busSpeed == .high ? .high : .full
            )
            displayEndpointOpen = false
            displaySessionResetPending = false
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
                if wasTruncated {
                    guard status.packetStatus == .outDataReceived,
                          status.endpoint == 2 || status.endpoint == 3
                    else { return fail() }
                }
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

        if displaySessionResetPending && !displayTransferInFlight {
            displayTransmitter.resetSession(requestFullFrame: true)
            displaySessionResetPending = false
        }

        if state == .configured,
           displayEndpointOpen,
           !displayTransferInFlight {
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
            guard copiedByteCount == USBSetupPacket.byteCount,
                  endpointZeroReceiveStage != .setup
            else {
                return fail()
            }
            resetEndpointZeroTransaction()
            guard stageEndpointZeroReceiveBytes(copiedByteCount) else {
                return fail()
            }
            endpointZeroReceiveStage = .setup
            return USBDebugGadgetEvent.none

        case .setupTransactionComplete:
            guard status.endpoint == 0,
                  endpointZeroReceiveStage == .setup,
                  endpointZeroStagedByteCount == USBSetupPacket.byteCount
            else { return fail() }
            let receive = endpointZeroReceiveStageBuffer
            let setup = USBSetupPacket.parse(
                UnsafeRawBufferPointer(
                    start: receive.baseAddress,
                    count: USBSetupPacket.byteCount
                )
            )
            guard let setup else { return fail() }
            resetEndpointZeroReceiveState()
            controller.clearEndpoint0Stall()
            endpointZeroRequestedByteCount = setup.length
            let reply = controlReplyBuffer
            let action = controlEndpoint.handle(setup, reply: reply)
            stageDisplayOpenState(setup: setup, action: action)
            return performControlAction(action)

        case .outDataReceived:
            if status.endpoint == 0 {
                guard endpointZeroReceiveStage == .idle else {
                    return fail()
                }
                switch endpointZeroTransaction {
                case .dataOut:
                    guard copiedByteCount == endpointZeroExpectedOutByteCount,
                          stageEndpointZeroReceiveBytes(copiedByteCount)
                    else { return fail() }
                    endpointZeroReceiveStage = .dataOut
                case .statusOut:
                    guard copiedByteCount == 0 else { return fail() }
                    endpointZeroReceiveStage = .statusOut
                    endpointZeroStagedByteCount = 0
                case .idle, .dataIn, .statusIn, .stalled:
                    return fail()
                }
                return USBDebugGadgetEvent.none
            }
            guard status.endpoint == 2 || status.endpoint == 3 else {
                return fail()
            }
            return USBDebugGadgetEvent.none

        case .outTransferComplete:
            if status.endpoint == 0 {
                switch endpointZeroReceiveStage {
                case .dataOut:
                    guard endpointZeroTransaction == .dataOut,
                          endpointZeroStagedByteCount
                            == endpointZeroExpectedOutByteCount
                    else { return fail() }
                    let receive = endpointZeroReceiveStageBuffer
                    let action = controlEndpoint.acceptDataOut(
                        UnsafeRawBufferPointer(
                            start: receive.baseAddress,
                            count: Int(endpointZeroStagedByteCount)
                        )
                    )
                    resetEndpointZeroReceiveState()
                    endpointZeroExpectedOutByteCount = 0
                    return performControlAction(action)
                case .statusOut:
                    guard endpointZeroTransaction == .statusOut else {
                        return fail()
                    }
                    resetEndpointZeroTransaction()
                    guard controller.armEndpoint0ForSetup() else {
                        return fail()
                    }
                    return USBDebugGadgetEvent.none
                case .idle, .setup:
                    return fail()
                }
            }
            guard status.endpoint == 2 || status.endpoint == 3,
                  controller.armOutTransfer(
                      endpoint: status.endpoint,
                      byteCount: UInt32(
                          controller.busSpeed.bulkMaximumPacketSize
                      )
                  ) == .queued
            else { return fail() }
            return USBDebugGadgetEvent.none

        case .globalOutNAK, .dataToggleError:
            return USBDebugGadgetEvent.none
        }
    }

    private mutating func performControlAction(
        _ action: USBControlAction
    ) -> USBDebugGadgetEvent? {
        switch action {
        case .dataIn(let byteCount):
            guard byteCount <= endpointZeroRequestedByteCount,
                  byteCount <= UInt16(controlReplyBuffer.count)
            else { return fail() }
            endpointZeroInReplyByteCount = byteCount
            endpointZeroInQueuedByteCount = 0
            endpointZeroInNeedsZeroLengthPacket = byteCount > 0
                && byteCount < endpointZeroRequestedByteCount
                && byteCount
                    % DWC2USBDebugScratchLayout
                        .endpointZeroMaximumPacketByteCount == 0
            endpointZeroInQueuedZeroLengthPacket = false
            switch queueNextEndpointZeroInPacket() {
            case .queued:
                endpointZeroTransaction = .dataIn
                return USBDebugGadgetEvent.none
            case .complete:
                resetEndpointZeroInState()
                guard controller.armEndpoint0Out(byteCount: 0) else {
                    return fail()
                }
                endpointZeroTransaction = .statusOut
                return USBDebugGadgetEvent.none
            case .failed:
                return fail()
            }

        case .dataOut(let expectedByteCount):
            guard expectedByteCount > 0,
                  expectedByteCount <= UInt16(
                      DWC2USBDebugScratchLayout
                          .endpointZeroReceiveStageByteCount
                  ),
                  controller.armEndpoint0Out(byteCount: expectedByteCount)
            else { return fail() }
            endpointZeroExpectedOutByteCount = expectedByteCount
            endpointZeroTransaction = .dataOut
            return USBDebugGadgetEvent.none

        case .statusIn:
            resetEndpointZeroInState()
            let result = controller.queueInTransfer(
                endpoint: 0,
                bytes: UnsafeRawBufferPointer(start: nil, count: 0)
            )
            guard result == .queued else { return fail() }
            endpointZeroTransaction = .statusIn
            return USBDebugGadgetEvent.none

        case .stall, .replyBufferTooSmall:
            resetEndpointZeroTransaction()
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
            switch queueNextEndpointZeroInPacket() {
            case .queued:
                return USBDebugGadgetEvent.none
            case .complete:
                resetEndpointZeroInState()
                guard controller.armEndpoint0Out(byteCount: 0) else {
                    return fail()
                }
                endpointZeroTransaction = .statusOut
                return USBDebugGadgetEvent.none
            case .failed:
                return fail()
            }

        case .statusIn:
            let pendingDisplayOpenState =
                endpointZeroPendingDisplayOpenState
            let commit = controlEndpoint.completeStatusStage(succeeded: true)
            if case .deviceAddress(let address) = commit {
                controller.setDeviceAddress(address)
            }
            resetEndpointZeroTransaction()
            commitDisplayOpenState(pendingDisplayOpenState)
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

    private mutating func queueNextEndpointZeroInPacket()
        -> EndpointZeroInQueueResult {
        let start: UnsafeRawPointer?
        let byteCount: UInt16
        let queuesZeroLengthPacket: Bool

        if endpointZeroInQueuedByteCount < endpointZeroInReplyByteCount {
            let remaining = endpointZeroInReplyByteCount
                - endpointZeroInQueuedByteCount
            byteCount = remaining < DWC2USBDebugScratchLayout
                .endpointZeroMaximumPacketByteCount
                ? remaining
                : DWC2USBDebugScratchLayout
                    .endpointZeroMaximumPacketByteCount
            let reply = controlReplyBuffer
            guard let baseAddress = reply.baseAddress else { return .failed }
            start = UnsafeRawPointer(
                baseAddress.advanced(
                    by: Int(endpointZeroInQueuedByteCount)
                )
            )
            queuesZeroLengthPacket = false
        } else if endpointZeroInNeedsZeroLengthPacket
                    && !endpointZeroInQueuedZeroLengthPacket {
            start = nil
            byteCount = 0
            queuesZeroLengthPacket = true
        } else {
            return .complete
        }

        let result = controller.queueInTransfer(
            endpoint: 0,
            bytes: UnsafeRawBufferPointer(
                start: start,
                count: Int(byteCount)
            )
        )
        guard result == .queued else { return .failed }
        if queuesZeroLengthPacket {
            endpointZeroInQueuedZeroLengthPacket = true
        } else {
            endpointZeroInQueuedByteCount += byteCount
        }
        return .queued
    }

    private mutating func resetEndpointZeroInState() {
        endpointZeroInReplyByteCount = 0
        endpointZeroInQueuedByteCount = 0
        endpointZeroInNeedsZeroLengthPacket = false
        endpointZeroInQueuedZeroLengthPacket = false
    }

    private mutating func resetEndpointZeroTransaction() {
        endpointZeroTransaction = .idle
        endpointZeroRequestedByteCount = 0
        endpointZeroExpectedOutByteCount = 0
        endpointZeroPendingDisplayOpenState = nil
        resetEndpointZeroInState()
        resetEndpointZeroReceiveState()
    }

    private mutating func stageEndpointZeroReceiveBytes(
        _ byteCount: UInt16
    ) -> Bool {
        guard byteCount <= UInt16(
                  DWC2USBDebugScratchLayout.endpointZeroReceiveStageByteCount
              )
        else { return false }
        let source = receiveBuffer
        let destination = endpointZeroReceiveStageBuffer
        guard Int(byteCount) <= source.count,
              Int(byteCount) <= destination.count
        else { return false }
        var index = 0
        while index < Int(byteCount) {
            destination[index] = source[index]
            index += 1
        }
        endpointZeroStagedByteCount = byteCount
        return true
    }

    private mutating func resetEndpointZeroReceiveState() {
        endpointZeroReceiveStage = .idle
        endpointZeroStagedByteCount = 0
    }

    private mutating func stageDisplayOpenState(
        setup: USBSetupPacket,
        action: USBControlAction
    ) {
        guard setup.requestType.kind == .class,
              setup.requestType.direction == .hostToDevice,
              setup.requestType.recipient == .interface,
              setup.request == USBCDCRequest.setControlLineState,
              case .statusIn = action
        else { return }
        endpointZeroPendingDisplayOpenState =
            controlEndpoint.controlLineState & 1 != 0
    }

    private mutating func commitDisplayOpenState(_ isOpen: Bool?) {
        guard let isOpen else { return }
        let wasOpen = displayEndpointOpen
        displayEndpointOpen = isOpen
        if isOpen && !wasOpen {
            displaySessionResetPending = true
        }
    }

    private mutating func synchronizeConfiguration() -> USBDebugGadgetEvent? {
        if controlEndpoint.state == .configured {
            guard controller.state != .configured else {
                state = .configured
                return USBDebugGadgetEvent.none
            }
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
            displayTransmitter.resetSession(requestFullFrame: true)
            displayEndpointOpen = controlEndpoint.controlLineState & 1 != 0
            displaySessionResetPending = false
            displayTransferInFlight = false
            state = .configured
            return .configured
        }
        if controller.state == .configured {
            controller.deconfigureCompositeEndpoints()
            displayEndpointOpen = false
            displaySessionResetPending = false
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

    private var endpointZeroReceiveStageBuffer: UnsafeMutableRawBufferPointer {
        buffer(
            offset: DWC2USBDebugScratchLayout.endpointZeroReceiveStageOffset,
            count: DWC2USBDebugScratchLayout.endpointZeroReceiveStageByteCount
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
        resetEndpointZeroTransaction()
        displayEndpointOpen = false
        displaySessionResetPending = false
        displayTransferInFlight = false
        return .faulted
    }
}
