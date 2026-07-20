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
    /// Emitted only after the host has received the committed STATUS packet.
    /// Activation remains a separate kernel-policy operation.
    case kernelUpdateReady(USBKernelUpdateSealedArtifact)
    case faulted
}

/// Stable, compact classification for a terminal fault discovered while the
/// polled gadget services one hardware snapshot. Raw values are persisted by
/// the Pi monitor and are therefore part of the returned-card debug contract.
enum DWC2USBDebugGadgetServiceFaultReason: UInt8, Equatable {
    case internalInvariant = 1
    case busReset = 2
    case enumeration = 3
    case malformedReceiveStatus = 4
    case receiveProtocol = 5
    case endpointZero = 6
    case endpointTwo = 7
    case endpointTwoProtocol = 8
    case displayTransmit = 9
}

/// Pre-disconnect state retained when service fails. This is deliberately a
/// bounded value snapshot: no register is read after the controller has been
/// disconnected and no diagnostic path can mutate hardware.
struct DWC2USBDebugGadgetServiceFault: Equatable {
    let reason: DWC2USBDebugGadgetServiceFaultReason
    let gadgetState: USBDebugGadgetState
    let controllerState: DWC2ControllerState
    let globalInterrupts: UInt32
    let endpointInterrupts: UInt32
    let busSpeed: DWC2BusSpeed
    let receiveStatus: UInt32
}

/// Immutable, board-neutral state needed by the USB diagnostic service. Live
/// link, log, and allocator state is sampled by the gadget when it answers a
/// request; this value only anchors the exact boot and machine-wide capacities.
struct USBDebugKernelDescription: Equatable {
    let bootIdentity: KernelBootIdentity
    let configuredProcessorCount: UInt16
    let managedMemoryByteCount: UInt64

    init?(
        bootIdentity: KernelBootIdentity,
        configuredProcessorCount: UInt16,
        managedMemoryByteCount: UInt64
    ) {
        guard configuredProcessorCount > 0,
              managedMemoryByteCount > 0
        else { return nil }
        self.bootIdentity = bootIdentity
        self.configuredProcessorCount = configuredProcessorCount
        self.managedMemoryByteCount = managedMemoryByteCount
    }
}

enum DWC2USBDebugGadgetInitializationFailureReason: Equatable {
    case invalidConfiguration
    case displayTransmitterInvalid
    case updateReceiverInvalid
    case debugSessionInvalid
    case controller(DWC2InitializationResult)
    case connectionFailed
}

/// A controller failure includes the immutable identity/capability words read
/// before reset. Pure software validation failures deliberately carry no MMIO
/// snapshot because they are rejected before the controller is touched.
struct DWC2USBDebugGadgetInitializationFailure: Equatable {
    let reason: DWC2USBDebugGadgetInitializationFailureReason
    let hardwareSnapshot: DWC2HardwareRegisterSnapshot?
}

enum DWC2USBDebugGadgetInitializationOutcome<
    Registers: DWC2RegisterAccess
> {
    case ready(DWC2USBDebugGadget<Registers>)
    case failed(DWC2USBDebugGadgetInitializationFailure)
}

private enum DWC2USBDebugScratchLayout {
    static let endpointZeroMaximumPacketByteCount: UInt16 = 64
    static let controlReplyOffset = 0
    static let controlReplyByteCount = 128
    static let receiveOffset = 128
    static let receiveByteCount = 512
    static let endpointZeroReceiveStageOffset = 640
    static let endpointZeroReceiveStageByteCount = 64
    static let displayPacketOffset = 704
    static let displayPacketByteCount =
        USBDebugDisplayProtocol.maximumPacketByteCount
    static let updateStreamOffset = displayPacketOffset
        + displayPacketByteCount
    static let updateStreamByteCount =
        USBKernelUpdateStreamReceiver.minimumStorageByteCount
    static let updateStatusOffset = updateStreamOffset
        + updateStreamByteCount
    static let updateStatusByteCount =
        USBKernelUpdateProtocol.headerByteCount
            + USBKernelUpdateProtocol.statusPayloadByteCount
    static let sdbgReceiveOffset = updateStatusOffset + updateStatusByteCount
    static let sdbgReceiveByteCount = 512
    static let sdbgTransmitOffset = sdbgReceiveOffset + sdbgReceiveByteCount
    static let sdbgTransmitByteCount = 512
    static let requiredByteCount = sdbgTransmitOffset + sdbgTransmitByteCount
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

    private enum EndpointTwoInFlight: UInt8 {
        case none
        case display
        case updateStatus
        case sdbg
    }

    /// CDC is one ordered stream. A host selects SUPD or SDBG with the first
    /// valid wire magic after opening the port and reopens it to switch. This
    /// prevents one protocol's payload from being misidentified as another.
    private enum EndpointTwoInboundProtocol: UInt8 {
        case undecided
        case kernelUpdate
        case sdbg
    }

    private var controller: DWC2Controller<Registers>
    private var controlEndpoint = USBControlEndpoint(speed: .full)
    private var displayTransmitter: USBDebugDisplayTransmitter
    private var updateReceiver: USBKernelUpdateStreamReceiver?
    private var sdbgSession: SDBGTransportSession
    private let kernelDescription: USBDebugKernelDescription
    private let displayMode: DisplayMode
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
    private var endpointTwoInFlight: EndpointTwoInFlight = .none
    private var endpointTwoOutNeedsRearm = false
    private var endpointTwoProtocolResetPending = false
    private var endpointTwoInboundProtocol:
        EndpointTwoInboundProtocol = .undecided
    private var endpointTwoInboundMagic: UInt32 = 0
    private var endpointTwoInboundMagicByteCount = 0
    private var sdbgInFlightByteCount = 0
    private var sdbgSnapshotSequence: UInt64 = 1
    private var updateStatusPending = false
    private var updateStatusByteCount = 0
    private var updateStatusCommittedArtifact:
        USBKernelUpdateSealedArtifact?
    private(set) var state: USBDebugGadgetState = .attached
    private(set) var lastServiceFault:
        DWC2USBDebugGadgetServiceFault?
    private var serviceInterruptSnapshot: DWC2InterruptSnapshot?
    private var serviceFaultReason:
        DWC2USBDebugGadgetServiceFaultReason = .internalInvariant
    private var serviceReceiveStatus: UInt32 = 0

    init?(
        registers: Registers,
        scratchBaseAddress: UInt64,
        scratchByteCount: UInt64,
        scanout: ScanoutBuffer,
        viewportScale: UInt16,
        kernelDescription: USBDebugKernelDescription,
        updateTargetMachine: USBKernelUpdateTargetMachine = .raspberryPi5,
        updateStagingRegion: USBKernelUpdateRAMStagingRegion? = nil,
        maximumInitializationPollCount: Int = 100_000
    ) {
        switch Self.bringUp(
            registers: registers,
            scratchBaseAddress: scratchBaseAddress,
            scratchByteCount: scratchByteCount,
            scanout: scanout,
            viewportScale: viewportScale,
            kernelDescription: kernelDescription,
            updateTargetMachine: updateTargetMachine,
            updateStagingRegion: updateStagingRegion,
            maximumInitializationPollCount: maximumInitializationPollCount
        ) {
        case .ready(let gadget):
            self = gadget
        case .failed:
            return nil
        }
    }

    static func bringUp(
        registers: Registers,
        scratchBaseAddress: UInt64,
        scratchByteCount: UInt64,
        scanout: ScanoutBuffer,
        viewportScale: UInt16,
        kernelDescription: USBDebugKernelDescription,
        updateTargetMachine: USBKernelUpdateTargetMachine = .raspberryPi5,
        updateStagingRegion: USBKernelUpdateRAMStagingRegion? = nil,
        maximumInitializationPollCount: Int = 100_000
    ) -> DWC2USBDebugGadgetInitializationOutcome<Registers> {
        guard maximumInitializationPollCount > 0 else {
            return .failed(
                DWC2USBDebugGadgetInitializationFailure(
                    reason: .controller(.invalidPollLimit),
                    hardwareSnapshot: nil
                )
            )
        }
        guard scratchBaseAddress <= UInt64(UInt.max),
              scratchByteCount >= UInt64(
                  DWC2USBDebugScratchLayout.requiredByteCount
              ),
              scratchByteCount <= UInt64.max - scratchBaseAddress,
              viewportScale > 0
        else {
            return .failed(
                DWC2USBDebugGadgetInitializationFailure(
                    reason: .invalidConfiguration,
                    hardwareSnapshot: nil
                )
            )
        }
        let displaySessionIDCandidate =
            kernelDescription.bootIdentity.sessionID.high
                ^ kernelDescription.bootIdentity.sessionID.low
        let displaySessionID = displaySessionIDCandidate == 0
            ? 1
            : displaySessionIDCandidate
        guard let transmitter = USBDebugDisplayTransmitter(
                  sourceBaseAddress: scanout.mapping.cpuPhysicalAddress,
                  sourceByteCount: scanout.requiredByteCount,
                  mode: scanout.mode,
                  bytesPerRow: scanout.bytesPerRow,
                  scaleNumerator: viewportScale,
                  sessionID: displaySessionID,
                  // Endpoint 2 has a 128-word FIFO. Header + chunk prefix +
                  // data must fit in one 512-byte high-speed bulk transfer.
                  maximumChunkDataByteCount: 456
              )
        else {
            return .failed(
                DWC2USBDebugGadgetInitializationFailure(
                    reason: .displayTransmitterInvalid,
                    hardwareSnapshot: nil
                )
            )
        }
        let updateReceiver: USBKernelUpdateStreamReceiver?
        if let updateStagingRegion {
            guard let receiver = USBKernelUpdateStreamReceiver(
                      storageBaseAddress: scratchBaseAddress
                          + UInt64(
                              DWC2USBDebugScratchLayout.updateStreamOffset
                          ),
                      storageByteCount: UInt64(
                          DWC2USBDebugScratchLayout.updateStreamByteCount
                      ),
                      targetMachine: updateTargetMachine,
                      stagingRegion: updateStagingRegion
                  )
            else {
                return .failed(
                    DWC2USBDebugGadgetInitializationFailure(
                        reason: .updateReceiverInvalid,
                        hardwareSnapshot: nil
                    )
                )
            }
            updateReceiver = receiver
        } else {
            updateReceiver = nil
        }
        guard let limits = SDBGServiceLimits(
                  maximumRequestPayloadByteCount: 472,
                  maximumResponsePayloadByteCount: 472,
                  maximumLogEntriesPerResponse: 8
              ), let sdbgSession = SDBGTransportSession(
                  bootIdentity: kernelDescription.bootIdentity,
                  service: SDBGService(limits: limits),
                  receiveStorageBaseAddress: UInt(scratchBaseAddress)
                      + UInt(DWC2USBDebugScratchLayout.sdbgReceiveOffset),
                  receiveStorageByteCount:
                      DWC2USBDebugScratchLayout.sdbgReceiveByteCount,
                  outboundStorageBaseAddress: UInt(scratchBaseAddress)
                      + UInt(DWC2USBDebugScratchLayout.sdbgTransmitOffset),
                  outboundStorageByteCount:
                      DWC2USBDebugScratchLayout.sdbgTransmitByteCount
              )
        else {
            return .failed(
                DWC2USBDebugGadgetInitializationFailure(
                    reason: .debugSessionInvalid,
                    hardwareSnapshot: nil
                )
            )
        }

        var controller = DWC2Controller(registers: registers)
        let hardwareSnapshot = controller.hardwareRegisterSnapshot()
        let initialization = controller.initialize(
            maximumPollCount: maximumInitializationPollCount
        )
        guard case .ready = initialization else {
            return .failed(
                DWC2USBDebugGadgetInitializationFailure(
                    reason: .controller(initialization),
                    hardwareSnapshot: hardwareSnapshot
                )
            )
        }
        guard controller.connect() else {
            return .failed(
                DWC2USBDebugGadgetInitializationFailure(
                    reason: .connectionFailed,
                    hardwareSnapshot: hardwareSnapshot
                )
            )
        }

        return .ready(
            DWC2USBDebugGadget(
                activeController: controller,
                displayTransmitter: transmitter,
                updateReceiver: updateReceiver,
                sdbgSession: sdbgSession,
                kernelDescription: kernelDescription,
                displayMode: scanout.mode,
                scratchBaseAddress: UInt(scratchBaseAddress)
            )
        )
    }

    private init(
        activeController: DWC2Controller<Registers>,
        displayTransmitter: USBDebugDisplayTransmitter,
        updateReceiver: USBKernelUpdateStreamReceiver?,
        sdbgSession: SDBGTransportSession,
        kernelDescription: USBDebugKernelDescription,
        displayMode: DisplayMode,
        scratchBaseAddress: UInt
    ) {
        controller = activeController
        self.displayTransmitter = displayTransmitter
        self.updateReceiver = updateReceiver
        self.sdbgSession = sdbgSession
        self.kernelDescription = kernelDescription
        self.displayMode = displayMode
        self.scratchBaseAddress = scratchBaseAddress
    }

    var isOperational: Bool {
        state != .faulted
    }

    var isDisplaySessionOpen: Bool {
        displayEndpointOpen
    }

    mutating func requestFullFrame() {
        guard state != .faulted else { return }
        displayTransmitter.requestFullFrame()
    }

    mutating func requestDamage(_ damage: DamageRectangle) {
        guard state != .faulted else { return }
        displayTransmitter.requestDamage(damage)
    }

    /// Disconnects the USB device and drains controller FIFOs before a caller
    /// leaves the current kernel. This never activates the staged image.
    mutating func quiesceForKernelActivation(
        maximumPollCount: Int = 100_000
    ) -> Bool {
        guard state != .faulted,
              controller.quiesceForRestart(
                  maximumPollCount: maximumPollCount
              )
        else { return false }
        resetEndpointZeroTransaction()
        displayEndpointOpen = false
        displaySessionResetPending = false
        endpointTwoInFlight = .none
        endpointTwoOutNeedsRearm = false
        clearPendingUpdateStatus()
        resetEndpointTwoProtocolState()
        state = .attached
        return true
    }

    mutating func service() -> USBDebugGadgetEvent {
        guard state != .faulted else { return .faulted }
        let snapshot = controller.interruptSnapshot()
        serviceInterruptSnapshot = snapshot
        serviceFaultReason = .internalInvariant
        serviceReceiveStatus = 0
        var event: USBDebugGadgetEvent = .none

        if snapshot.didReset {
            serviceFaultReason = .busReset
            guard controller.handleBusReset() else { return fail() }
            controlEndpoint.busReset()
            displayTransmitter.resetSession(requestFullFrame: true)
            resetEndpointZeroTransaction()
            displayEndpointOpen = false
            displaySessionResetPending = false
            endpointTwoInFlight = .none
            endpointTwoOutNeedsRearm = false
            clearPendingUpdateStatus()
            resetEndpointTwoProtocolState()
            state = .attached
            controller.acknowledgeGlobalInterrupts(
                snapshot.global & (
                    DWC2CoreBits.usbResetInterrupt
                        | DWC2CoreBits.enumerationDoneInterrupt
                        | DWC2CoreBits.usbSuspendInterrupt
                        | DWC2CoreBits.wakeupInterrupt
                )
            )
            // Every other bit in this snapshot predates the reset cleanup.
            // Re-sample hardware on the next service pass.
            return .busReset
        }

        if snapshot.didEnumerate {
            serviceFaultReason = .enumeration
            controller.handleEnumerationDone()
            controlEndpoint = USBControlEndpoint(
                speed: controller.busSpeed == .high ? .high : .full
            )
            displayEndpointOpen = false
            displaySessionResetPending = false
            endpointTwoInFlight = .none
            endpointTwoOutNeedsRearm = false
            clearPendingUpdateStatus()
            resetEndpointTwoProtocolState()
            state = .enumerated
            event = .enumerated(controller.busSpeed)
        }

        if snapshot.hasReceiveFIFOEntry {
            // RXFLVL is a FIFO-not-empty indication. Drain a bounded batch so
            // host retries cannot strand SETUP state across long cooperative
            // monitor work, while preserving a deterministic service budget.
            var remainingReceiveEntryBudget = 8
            receiveLoop: while remainingReceiveEntryBudget > 0 {
                serviceFaultReason = .receiveProtocol
                let receive = receiveBuffer
                let receiveResult = controller.pollReceive(into: receive)
                switch receiveResult {
                case .noPacket:
                    break receiveLoop
                case .malformedStatus(let rawValue, _):
                    serviceFaultReason = .malformedReceiveStatus
                    serviceReceiveStatus = rawValue
                    return fail()
                case .packet(let status, let copiedByteCount, let wasTruncated):
                    remainingReceiveEntryBudget -= 1
                    serviceReceiveStatus = encodedReceiveStatus(status)
                    switch status.endpoint {
                    case 0:
                        serviceFaultReason = .endpointZero
                    case 2, 3:
                        serviceFaultReason = .endpointTwoProtocol
                    default:
                        serviceFaultReason = .receiveProtocol
                    }
                    if wasTruncated {
                        guard status.packetStatus == .outDataReceived,
                              status.endpoint == 2 || status.endpoint == 3
                        else { return fail() }
                    }
                    if let receiveEvent = handleReceivePacket(
                        status: status,
                        copiedByteCount: copiedByteCount
                    ), receiveEvent != .none {
                        if receiveEvent == .faulted { return .faulted }
                        event = receiveEvent
                    }
                }
            }
        }

        if snapshot.hasInEndpointInterrupt(0) {
            serviceFaultReason = .endpointZero
            serviceReceiveStatus = 0
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
            serviceFaultReason = .endpointZero
            serviceReceiveStatus = 0
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
            serviceFaultReason = .endpointTwo
            serviceReceiveStatus = 0
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
            if interrupt & DWC2CoreBits.endpointTransferComplete != 0 {
                switch endpointTwoInFlight {
                case .none:
                    break
                case .display:
                    let completedFrame = displayTransmitter.phase == .frameEnd
                        ? displayTransmitter.activeFrameID
                        : 0
                    guard displayTransmitter.commitPreparedPacket() else {
                        return fail()
                    }
                    endpointTwoInFlight = .none
                    if completedFrame != 0 {
                        event = .frameCompleted(completedFrame)
                    }
                case .updateStatus:
                    endpointTwoInFlight = .none
                    let committedArtifact = updateStatusCommittedArtifact
                    clearPendingUpdateStatus()
                    if let committedArtifact {
                        event = .kernelUpdateReady(committedArtifact)
                    } else {
                        guard stageNextUpdateResponse() else {
                            return fail()
                        }
                    }
                case .sdbg:
                    endpointTwoInFlight = .none
                    guard sdbgInFlightByteCount > 0 else {
                        return fail()
                    }
                    switch sdbgSession.consumeOutboundBytes(
                        sdbgInFlightByteCount
                    ) {
                    case .consumed(_, let remainingByteCount):
                        guard remainingByteCount == 0 else { return fail() }
                    case .invalidByteCount:
                        return fail()
                    }
                    sdbgInFlightByteCount = 0
                    guard stageNextSDBGResponse() else { return fail() }
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

        if displaySessionResetPending && endpointTwoInFlight != .display {
            displayTransmitter.resetSession(requestFullFrame: true)
            displaySessionResetPending = false
        }
        if endpointTwoProtocolResetPending,
           endpointTwoInFlight == .none {
            resetEndpointTwoProtocolState()
        }

        serviceFaultReason = .endpointTwoProtocol
        serviceReceiveStatus = 0
        if state == .configured,
           endpointTwoInFlight == .none,
           updateStatusPending {
            let status = updateStatusBuffer
            let result = controller.queueInTransfer(
                endpoint: 2,
                bytes: UnsafeRawBufferPointer(
                    start: status.baseAddress,
                    count: updateStatusByteCount
                )
            )
            switch result {
            case .queued:
                endpointTwoInFlight = .updateStatus
            case .fifoBusy:
                break
            case .invalidState, .invalidEndpoint,
                 .invalidBuffer, .invalidTransferSize:
                return fail()
            }
        }

        if state == .configured,
           displayEndpointOpen,
           endpointTwoInFlight == .none,
           !updateStatusPending {
            guard stageNextSDBGResponse() else { return fail() }
            let bytes = sdbgSession.outboundBytes
            if bytes.count > 0 {
                let result = controller.queueInTransfer(
                    endpoint: 2,
                    bytes: bytes
                )
                switch result {
                case .queued:
                    endpointTwoInFlight = .sdbg
                    sdbgInFlightByteCount = bytes.count
                case .fifoBusy:
                    break
                case .invalidState, .invalidEndpoint,
                     .invalidBuffer, .invalidTransferSize:
                    return fail()
                }
            }
        }

        if state == .configured,
           endpointTwoInFlight == .none,
           !updateStatusPending,
           sdbgSession.pendingOutboundByteCount == 0,
           endpointTwoOutNeedsRearm {
            guard controller.armOutTransfer(
                      endpoint: 2,
                      byteCount: UInt32(
                          controller.busSpeed.bulkMaximumPacketSize
                      )
                  ) == .queued
            else { return fail() }
            endpointTwoOutNeedsRearm = false
        }

        if state == .configured,
           displayEndpointOpen,
           endpointTwoInFlight == .none,
           !updateStatusPending,
           sdbgSession.pendingOutboundByteCount == 0 {
            serviceFaultReason = .displayTransmit
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
                    endpointTwoInFlight = .display
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

    private func encodedReceiveStatus(_ status: DWC2ReceiveStatus) -> UInt32 {
        UInt32(status.endpoint)
            | UInt32(status.byteCount) << 4
            | UInt32(status.dataPID) << 15
            | UInt32(status.packetStatus.rawValue) << 17
            | UInt32(status.frameNumber) << 25
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
            // USB control transfers are preempted by a newer SETUP packet.
            // Discard every staged action and retain only the newest request.
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
            if status.endpoint == 2, copiedByteCount > 0 {
                let receive = receiveBuffer
                let bytes = UnsafeRawBufferPointer(
                    start: receive.baseAddress,
                    count: Int(copiedByteCount)
                )
                guard routeEndpointTwoInbound(bytes) else { return fail() }
            }
            return USBDebugGadgetEvent.none

        case .outTransferComplete:
            if status.endpoint == 0 {
                switch endpointZeroReceiveStage {
                case .setup:
                    // DWC2 integrations may report SETUPRX, OUTDONE, then
                    // SETUPDONE for one control request. SETUPDONE is the
                    // stable point at which this driver parses and acts on
                    // the staged eight-byte request, so retain the payload
                    // across the optional OUTDONE indication.
                    return USBDebugGadgetEvent.none
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
                case .idle:
                    return fail()
                }
            }
            guard status.endpoint == 2 || status.endpoint == 3 else {
                return fail()
            }
            if status.endpoint == 2,
               updateStatusPending
                || endpointTwoInFlight == .updateStatus
                || sdbgSession.pendingOutboundByteCount > 0
                || endpointTwoInFlight == .sdbg {
                endpointTwoOutNeedsRearm = true
                return USBDebugGadgetEvent.none
            }
            guard controller.armOutTransfer(
                      endpoint: status.endpoint,
                      byteCount: UInt32(
                          controller.busSpeed.bulkMaximumPacketSize
                      )
                  ) == .queued
            else { return fail() }
            if status.endpoint == 2 {
                endpointTwoOutNeedsRearm = false
            }
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
            setup.value & 1 != 0
    }

    private mutating func commitDisplayOpenState(_ isOpen: Bool?) {
        guard let isOpen else { return }
        let wasOpen = displayEndpointOpen
        displayEndpointOpen = isOpen
        if isOpen != wasOpen {
            if endpointTwoInFlight == .none {
                resetEndpointTwoProtocolState()
            } else {
                endpointTwoProtocolResetPending = true
            }
            if isOpen {
                displaySessionResetPending = true
            }
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
            endpointTwoInFlight = .none
            endpointTwoOutNeedsRearm = false
            clearPendingUpdateStatus()
            resetEndpointTwoProtocolState()
            state = .configured
            return .configured
        }
        if controller.state == .configured {
            guard controller.deconfigureCompositeEndpoints() else {
                return fail()
            }
            displayEndpointOpen = false
            displaySessionResetPending = false
            endpointTwoInFlight = .none
            endpointTwoOutNeedsRearm = false
            clearPendingUpdateStatus()
            resetEndpointTwoProtocolState()
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

    private mutating func routeEndpointTwoInbound(
        _ bytes: UnsafeRawBufferPointer
    ) -> Bool {
        guard bytes.count == 0 || bytes.baseAddress != nil else { return false }
        var index = 0
        while index < bytes.count {
            switch endpointTwoInboundProtocol {
            case .kernelUpdate, .sdbg:
                guard let base = bytes.baseAddress else { return false }
                return appendEndpointTwoInbound(
                    UnsafeRawBufferPointer(
                        start: base.advanced(by: index),
                        count: bytes.count - index
                    )
                )

            case .undecided:
                endpointTwoInboundMagic |= UInt32(bytes[index])
                    << UInt32(endpointTwoInboundMagicByteCount * 8)
                endpointTwoInboundMagicByteCount += 1
                index += 1
                guard endpointTwoInboundMagicByteCount == 4 else { continue }

                if endpointTwoInboundMagic == USBKernelUpdateProtocol.magic {
                    endpointTwoInboundProtocol = .kernelUpdate
                } else if endpointTwoInboundMagic == SDBGProtocol.magic {
                    endpointTwoInboundProtocol = .sdbg
                } else {
                    // Retain the latest three bytes so magic split after
                    // arbitrary line noise is still recognized.
                    endpointTwoInboundMagic >>= 8
                    endpointTwoInboundMagicByteCount = 3
                    continue
                }

                var magic = endpointTwoInboundMagic
                endpointTwoInboundMagic = 0
                endpointTwoInboundMagicByteCount = 0
                let acceptedMagic = withUnsafeBytes(of: &magic) { wire in
                    appendEndpointTwoInbound(wire)
                }
                guard acceptedMagic else { return false }
            }
        }
        return true
    }

    private mutating func appendEndpointTwoInbound(
        _ bytes: UnsafeRawBufferPointer
    ) -> Bool {
        switch endpointTwoInboundProtocol {
        case .undecided:
            return false

        case .kernelUpdate:
            guard var receiver = updateReceiver else { return true }
            let result = receiver.append(bytes)
            updateReceiver = receiver
            switch result {
            case .appended:
                return stageNextUpdateResponse()
            case .invalidInput, .capacityExceeded:
                // Lost framing is recoverable. The sealed staging offset is
                // owned below the stream receiver and survives this reset.
                resetEndpointTwoProtocolState()
                return true
            }

        case .sdbg:
            switch sdbgSession.receive(bytes) {
            case .accepted:
                return stageNextSDBGResponse()
            case .wouldBlock, .rejected:
                resetEndpointTwoProtocolState()
                return true
            }
        }
    }

    private mutating func stageNextSDBGResponse() -> Bool {
        guard sdbgSession.pendingOutboundByteCount == 0 else { return true }
        guard let snapshot = makeSDBGServiceSnapshot() else { return false }

        // One input transfer can contain leading noise and several frames.
        // Bound recovery work per service pass while still reaching the first
        // valid request without waiting for another USB interrupt.
        var remainingSteps = 16
        while remainingSteps > 0 {
            remainingSteps -= 1
            switch sdbgSession.pump(
                snapshot: snapshot,
                lookupLogEntry: { sequence in
                    Self.retainedLogEntry(sequence: sequence)
                }
            ) {
            case .outboundReady, .outboundBackpressured,
                 .needsMoreBytes:
                return true
            case .discardedMalformedFrame, .discardedUnexpectedMessage:
                continue
            case .snapshotIdentityMismatch, .serviceRejected:
                return false
            }
        }
        return true
    }

    private mutating func makeSDBGServiceSnapshot()
        -> SDBGServiceSnapshot? {
        let statistics = Self.retainedLogStatistics
        let lostLogEntryCount = Self.saturatingAdd(
            statistics.overwrittenEntryCount,
            statistics.rejectedEntryCount
        )
        let freeMemoryByteCount = currentFreeMemoryByteCount()
        let flags = DebugStatusFlags(
            rawValue: DebugStatusFlags.virtualMemoryEnabled.rawValue
                | DebugStatusFlags.userlandIsolated.rawValue
        )
        let debugLinkState: DebugLinkState
        if state == .faulted {
            debugLinkState = .failed
        } else if displayEndpointOpen {
            debugLinkState = .connected
        } else if state == .configured {
            debugLinkState = .ready
        } else {
            debugLinkState = .initializing
        }
        let updateState: DebugUpdateState
        if updateStatusCommittedArtifact != nil {
            updateState = .committed
        } else if updateStatusPending {
            updateState = .receiving
        } else {
            updateState = .idle
        }
        guard let status = DebugStatusSnapshot(
                  snapshotSequence: sdbgSnapshotSequence,
                  monotonicTicks: Self.monotonicTicks,
                  bootSessionID: kernelDescription.bootIdentity.sessionID,
                  phase: .driversReady,
                  flags: flags,
                  configuredProcessorCount:
                      kernelDescription.configuredProcessorCount,
                  onlineProcessorCount: 1,
                  runnableThreadCount: 0,
                  managedMemoryByteCount:
                      kernelDescription.managedMemoryByteCount,
                  freeMemoryByteCount: freeMemoryByteCount,
                  displayState: .presenting,
                  displayWidthPixels: displayMode.widthInPixels,
                  displayHeightPixels: displayMode.heightInPixels,
                  displayRefreshMilliHertz:
                      displayMode.refreshRateMilliHertz ?? 0,
                  debugLinkState: debugLinkState,
                  updateState: updateState,
                  oldestLogSequence: statistics.oldestSequence ?? 0,
                  newestLogSequence: statistics.newestSequence ?? 0,
                  lostLogEntryCount: lostLogEntryCount,
                  lastError: .none
              ), let snapshot = SDBGServiceSnapshot(
                  bootIdentity: kernelDescription.bootIdentity,
                  status: status,
                  logStatistics: statistics
              )
        else { return nil }
        if sdbgSnapshotSequence != UInt64.max {
            sdbgSnapshotSequence += 1
        }
        return snapshot
    }

    private func currentFreeMemoryByteCount() -> UInt64 {
#if os(none)
        if let freePageCount = KernelMemoryRuntime.freePageCount,
           freePageCount
            <= kernelDescription.managedMemoryByteCount
                / MemoryPageGeometry.pageSize {
            return freePageCount * MemoryPageGeometry.pageSize
        }
#endif
        return kernelDescription.managedMemoryByteCount
    }

    private static var retainedLogStatistics: KernelLogStatistics {
#if os(none)
        if let statistics = KernelDebugLogRuntime.statistics {
            return statistics
        }
#endif
        return KernelLogStatistics(
            capacity: 1,
            retainedCount: 0,
            oldestSequence: nil,
            newestSequence: nil,
            nextSequence: 1,
            overwrittenEntryCount: 0,
            rejectedEntryCount: 0
        )
    }

    private static var monotonicTicks: UInt64 {
#if os(none)
        return AArch64.counterValue
#else
        return 0
#endif
    }

    private static func retainedLogEntry(
        sequence: UInt64
    ) -> KernelLogLookupResult {
#if os(none)
        if let result = KernelDebugLogRuntime.entry(sequence: sequence) {
            return result
        }
#endif
        return .notYetWritten
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }

    private mutating func stageNextUpdateResponse() -> Bool {
        guard !updateStatusPending else { return true }
        guard var receiver = updateReceiver else { return true }
        let result = receiver.pump()
        updateReceiver = receiver
        guard case .response(let response) = result else { return true }

        let output = updateStatusBuffer
        let encodeResult = USBKernelUpdatePacketEncoder.encode(
            .status(response.status),
            transferID: response.transferID,
            sequence: 0,
            into: output
        )
        guard case .encoded(let byteCount) = encodeResult,
              byteCount <= output.count
        else { return false }
        updateStatusByteCount = byteCount
        updateStatusCommittedArtifact = response.committedArtifact
        updateStatusPending = true
        return true
    }

    private mutating func clearPendingUpdateStatus() {
        updateStatusPending = false
        updateStatusByteCount = 0
        updateStatusCommittedArtifact = nil
    }

    private mutating func resetEndpointTwoProtocolState() {
        updateReceiver?.resetTransport()
        sdbgSession.resetStream()
        endpointTwoInboundProtocol = .undecided
        endpointTwoInboundMagic = 0
        endpointTwoInboundMagicByteCount = 0
        sdbgInFlightByteCount = 0
        endpointTwoProtocolResetPending = false
        clearPendingUpdateStatus()
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

    private var updateStatusBuffer: UnsafeMutableRawBufferPointer {
        buffer(
            offset: DWC2USBDebugScratchLayout.updateStatusOffset,
            count: DWC2USBDebugScratchLayout.updateStatusByteCount
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
        let snapshot = serviceInterruptSnapshot
        lastServiceFault = DWC2USBDebugGadgetServiceFault(
            reason: serviceFaultReason,
            gadgetState: state,
            controllerState: controller.state,
            globalInterrupts: snapshot?.global ?? 0,
            endpointInterrupts: snapshot?.endpoint ?? 0,
            busSpeed: snapshot?.busSpeed ?? controller.busSpeed,
            receiveStatus: serviceReceiveStatus
        )
        controller.disconnect()
        state = .faulted
        resetEndpointZeroTransaction()
        displayEndpointOpen = false
        displaySessionResetPending = false
        endpointTwoInFlight = .none
        endpointTwoOutNeedsRearm = false
        clearPendingUpdateStatus()
        resetEndpointTwoProtocolState()
        return .faulted
    }
}
