// Allocation-free Chapter 9 and CDC ACM EP0 policy. A future DWC2 or other
// USB-device controller owns packet movement and endpoint configuration; this
// state machine owns only validated protocol state and bounded replies.

struct USBLineCoding: Equatable {
    let dataRate: UInt32
    let stopBits: UInt8
    let parity: UInt8
    let dataBits: UInt8

    static let consoleDefault = USBLineCoding(
        dataRate: 115_200,
        stopBits: 0,
        parity: 0,
        dataBits: 8
    )

    static func parse(_ bytes: UnsafeRawBufferPointer) -> USBLineCoding? {
        guard bytes.count == 7 else { return nil }
        let dataRate = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let stopBits = bytes[4]
        let parity = bytes[5]
        let dataBits = bytes[6]
        let validDataBits = dataBits >= 5 && dataBits <= 8 || dataBits == 16
        guard dataRate > 0,
              stopBits <= 2,
              parity <= 4,
              validDataBits
        else {
            return nil
        }
        return USBLineCoding(
            dataRate: dataRate,
            stopBits: stopBits,
            parity: parity,
            dataBits: dataBits
        )
    }

    func write(to output: UnsafeMutableRawBufferPointer) -> Bool {
        guard output.count >= 7 else { return false }
        output[0] = UInt8(truncatingIfNeeded: dataRate)
        output[1] = UInt8(truncatingIfNeeded: dataRate >> 8)
        output[2] = UInt8(truncatingIfNeeded: dataRate >> 16)
        output[3] = UInt8(truncatingIfNeeded: dataRate >> 24)
        output[4] = stopBits
        output[5] = parity
        output[6] = dataBits
        return true
    }
}

struct USBControlEndpoint {
    /// At most one host-to-device mutation may be in flight. A new SETUP token,
    /// a failed status stage, or a bus reset discards it without changing the
    /// externally visible Chapter 9 / CDC state.
    private enum PendingMutation {
        case none
        case deviceAddress(UInt8)
        case configuration(UInt8)
        case endpointHalt(bit: UInt8, enabled: Bool)
        case interfaceEndpointHaltClear(mask: UInt8)
        case awaitingCDCLineCoding
        case lineCoding(USBLineCoding)
        case controlLineState(UInt16)
        case breakDuration(UInt16)
    }

    let speed: USBDeviceSpeed
    private(set) var state: USBDeviceState = .default
    private(set) var address: UInt8 = 0
    private(set) var configurationValue: UInt8 = 0
    private(set) var remoteWakeupEnabled = false
    private(set) var lineCoding = USBLineCoding.consoleDefault
    private(set) var controlLineState: UInt16 = 0
    private(set) var breakDuration: UInt16 = 0

    private var endpointHaltMask: UInt8 = 0
    private var pendingMutation: PendingMutation = .none

    init(speed: USBDeviceSpeed) {
        self.speed = speed
    }

    mutating func busReset() {
        state = .default
        address = 0
        configurationValue = 0
        remoteWakeupEnabled = false
        endpointHaltMask = 0
        pendingMutation = .none
        lineCoding = .consoleDefault
        controlLineState = 0
        breakDuration = 0
    }

    mutating func handle(
        _ setup: USBSetupPacket,
        reply: UnsafeMutableRawBufferPointer
    ) -> USBControlAction {
        // A new SETUP token aborts any older control transfer.
        pendingMutation = .none

        switch setup.requestType.kind {
        case .standard:
            return handleStandard(setup, reply: reply)
        case .class:
            return handleClass(setup, reply: reply)
        case .vendor:
            return .stall(.unsupportedRequestKind)
        }
    }

    mutating func acceptDataOut(
        _ bytes: UnsafeRawBufferPointer
    ) -> USBControlAction {
        switch pendingMutation {
        case .none:
            return .stall(.unexpectedDataOut)
        case .awaitingCDCLineCoding:
            guard let coding = USBLineCoding.parse(bytes) else {
                pendingMutation = .none
                return .stall(.malformedClassData)
            }
            pendingMutation = .lineCoding(coding)
            return .statusIn
        case .deviceAddress, .configuration, .endpointHalt,
             .interfaceEndpointHaltClear, .lineCoding,
             .controlLineState, .breakDuration:
            pendingMutation = .none
            return .stall(.unexpectedDataOut)
        }
    }

    mutating func completeStatusStage(
        succeeded: Bool
    ) -> USBControlStatusCommit {
        let mutation = pendingMutation
        pendingMutation = .none
        guard succeeded else { return .none }

        switch mutation {
        case .none, .awaitingCDCLineCoding:
            return .none

        case .deviceAddress(let address):
            self.address = address
            configurationValue = 0
            endpointHaltMask = 0
            state = address == 0 ? .default : .addressed
            return .deviceAddress(address)

        case .configuration(let value):
            configurationValue = value
            endpointHaltMask = 0
            state = value == 0 ? .addressed : .configured

        case .endpointHalt(let bit, let enabled):
            if enabled {
                endpointHaltMask |= bit
            } else {
                endpointHaltMask &= ~bit
            }

        case .interfaceEndpointHaltClear(let mask):
            endpointHaltMask &= ~mask

        case .lineCoding(let coding):
            lineCoding = coding

        case .controlLineState(let value):
            controlLineState = value

        case .breakDuration(let duration):
            breakDuration = duration
        }
        return .none
    }

    func isEndpointHalted(_ endpointAddress: UInt8) -> Bool {
        guard let bit = USBDebugDeviceIdentity.endpointHaltBit(endpointAddress)
        else {
            return false
        }
        return endpointHaltMask & bit != 0
    }

    private mutating func handleStandard(
        _ setup: USBSetupPacket,
        reply: UnsafeMutableRawBufferPointer
    ) -> USBControlAction {
        switch setup.request {
        case USBStandardRequest.getStatus:
            return getStatus(setup, reply: reply)
        case USBStandardRequest.clearFeature:
            return setFeature(setup, enabled: false)
        case USBStandardRequest.setFeature:
            return setFeature(setup, enabled: true)
        case USBStandardRequest.setAddress:
            return setAddress(setup)
        case USBStandardRequest.getDescriptor:
            return getDescriptor(setup, reply: reply)
        case USBStandardRequest.getConfiguration:
            return getConfiguration(setup, reply: reply)
        case USBStandardRequest.setConfiguration:
            return setConfiguration(setup)
        case USBStandardRequest.getInterface:
            return getInterface(setup, reply: reply)
        case USBStandardRequest.setInterface:
            return setInterface(setup)
        case USBStandardRequest.setDescriptor,
             USBStandardRequest.synchronizeFrame:
            return .stall(.unsupportedStandardRequest)
        default:
            return .stall(.unsupportedStandardRequest)
        }
    }

    private mutating func handleClass(
        _ setup: USBSetupPacket,
        reply: UnsafeMutableRawBufferPointer
    ) -> USBControlAction {
        guard state == .configured else { return .stall(.invalidState) }
        guard setup.requestType.recipient == .interface else {
            return .stall(.invalidRecipient)
        }
        guard setup.indexHigh == 0,
              setup.indexLow == USBDebugDeviceIdentity.cdcControlInterface
        else {
            return .stall(.invalidIndex)
        }

        switch setup.request {
        case USBCDCRequest.setLineCoding:
            guard setup.requestType.direction == .hostToDevice else {
                return .stall(.invalidDirection)
            }
            guard setup.value == 0 else { return .stall(.invalidValue) }
            guard setup.length == 7 else { return .stall(.invalidLength) }
            pendingMutation = .awaitingCDCLineCoding
            return .dataOut(expectedByteCount: 7)

        case USBCDCRequest.getLineCoding:
            guard setup.requestType.direction == .deviceToHost else {
                return .stall(.invalidDirection)
            }
            guard setup.value == 0 else { return .stall(.invalidValue) }
            guard setup.length == 7 else { return .stall(.invalidLength) }
            guard reply.count >= 7 else {
                return .replyBufferTooSmall(requiredByteCount: 7)
            }
            _ = lineCoding.write(to: reply)
            return .dataIn(byteCount: 7)

        case USBCDCRequest.setControlLineState:
            guard setup.requestType.direction == .hostToDevice else {
                return .stall(.invalidDirection)
            }
            guard setup.value & ~UInt16(0x0003) == 0 else {
                return .stall(.invalidValue)
            }
            guard setup.length == 0 else { return .stall(.invalidLength) }
            pendingMutation = .controlLineState(setup.value)
            return .statusIn

        case USBCDCRequest.sendBreak:
            guard setup.requestType.direction == .hostToDevice else {
                return .stall(.invalidDirection)
            }
            guard setup.length == 0 else { return .stall(.invalidLength) }
            pendingMutation = .breakDuration(setup.value)
            return .statusIn

        default:
            return .stall(.unsupportedClassRequest)
        }
    }

    private func getStatus(
        _ setup: USBSetupPacket,
        reply: UnsafeMutableRawBufferPointer
    ) -> USBControlAction {
        guard setup.requestType.direction == .deviceToHost else {
            return .stall(.invalidDirection)
        }
        guard setup.value == 0 else { return .stall(.invalidValue) }
        guard setup.length == 2 else { return .stall(.invalidLength) }
        guard state != .default else { return .stall(.invalidState) }

        var status: UInt16 = 0
        switch setup.requestType.recipient {
        case .device:
            guard setup.index == 0 else { return .stall(.invalidIndex) }
            if remoteWakeupEnabled { status |= 1 << 1 }

        case .interface:
            guard state == .configured else { return .stall(.invalidState) }
            guard setup.indexHigh == 0 else { return .stall(.invalidIndex) }
            guard USBDebugDeviceIdentity.isKnownInterface(setup.indexLow) else {
                return .stall(.unknownInterface)
            }

        case .endpoint:
            guard setup.indexHigh == 0 else { return .stall(.invalidIndex) }
            let endpoint = setup.indexLow
            if endpoint != 0 && endpoint != 0x80 {
                guard state == .configured else {
                    return .stall(.invalidState)
                }
                guard let bit = USBDebugDeviceIdentity.endpointHaltBit(endpoint)
                else {
                    return .stall(.unknownEndpoint)
                }
                if endpointHaltMask & bit != 0 { status = 1 }
            }

        case .other:
            return .stall(.invalidRecipient)
        }

        guard reply.count >= 2 else {
            return .replyBufferTooSmall(requiredByteCount: 2)
        }
        reply[0] = UInt8(truncatingIfNeeded: status)
        reply[1] = UInt8(truncatingIfNeeded: status >> 8)
        return .dataIn(byteCount: 2)
    }

    private mutating func setFeature(
        _ setup: USBSetupPacket,
        enabled: Bool
    ) -> USBControlAction {
        guard setup.requestType.direction == .hostToDevice else {
            return .stall(.invalidDirection)
        }
        guard setup.length == 0 else { return .stall(.invalidLength) }
        switch setup.requestType.recipient {
        case .device:
            guard state != .default else { return .stall(.invalidState) }
            guard setup.index == 0 else { return .stall(.invalidIndex) }
            guard setup.value == USBFeatureSelector.deviceRemoteWakeup else {
                return .stall(.unsupportedFeature)
            }
            // The configuration descriptor intentionally does not advertise
            // remote wakeup until a controller backend can signal resume.
            return .stall(.unsupportedFeature)

        case .endpoint:
            guard state == .configured else { return .stall(.invalidState) }
            guard setup.value == USBFeatureSelector.endpointHalt else {
                return .stall(.unsupportedFeature)
            }
            guard setup.indexHigh == 0 else { return .stall(.invalidIndex) }
            guard let bit = USBDebugDeviceIdentity.endpointHaltBit(setup.indexLow)
            else {
                return .stall(.unknownEndpoint)
            }
            pendingMutation = .endpointHalt(bit: bit, enabled: enabled)
            return .statusIn

        case .interface:
            guard state == .configured else { return .stall(.invalidState) }
            return .stall(.invalidRecipient)

        case .other:
            return .stall(.invalidRecipient)
        }
    }

    private mutating func setAddress(
        _ setup: USBSetupPacket
    ) -> USBControlAction {
        guard setup.requestType.direction == .hostToDevice else {
            return .stall(.invalidDirection)
        }
        guard setup.requestType.recipient == .device else {
            return .stall(.invalidRecipient)
        }
        guard setup.index == 0 else { return .stall(.invalidIndex) }
        guard setup.length == 0 else { return .stall(.invalidLength) }
        guard setup.value <= 127 else { return .stall(.invalidValue) }
        guard state != .configured else { return .stall(.invalidState) }
        pendingMutation = .deviceAddress(UInt8(setup.value))
        return .statusIn
    }

    private func getDescriptor(
        _ setup: USBSetupPacket,
        reply: UnsafeMutableRawBufferPointer
    ) -> USBControlAction {
        guard setup.requestType.direction == .deviceToHost else {
            return .stall(.invalidDirection)
        }
        guard setup.requestType.recipient == .device else {
            return .stall(.invalidRecipient)
        }
        let languageID = setup.valueHigh == USBDescriptorType.string
            ? setup.index
            : 0
        if setup.valueHigh != USBDescriptorType.string && setup.index != 0 {
            return .stall(.invalidIndex)
        }
        switch USBDebugDescriptorSet.write(
            descriptorType: setup.valueHigh,
            descriptorIndex: setup.valueLow,
            languageID: languageID,
            speed: speed,
            requestedLength: setup.length,
            to: reply
        ) {
        case let .written(byteCount): return .dataIn(byteCount: byteCount)
        case .unsupported: return .stall(.unknownDescriptor)
        case let .bufferTooSmall(requiredByteCount):
            return .replyBufferTooSmall(requiredByteCount: requiredByteCount)
        }
    }

    private func getConfiguration(
        _ setup: USBSetupPacket,
        reply: UnsafeMutableRawBufferPointer
    ) -> USBControlAction {
        guard setup.requestType.direction == .deviceToHost else {
            return .stall(.invalidDirection)
        }
        guard setup.requestType.recipient == .device else {
            return .stall(.invalidRecipient)
        }
        guard setup.value == 0 else { return .stall(.invalidValue) }
        guard setup.index == 0 else { return .stall(.invalidIndex) }
        guard setup.length == 1 else { return .stall(.invalidLength) }
        guard state != .default else { return .stall(.invalidState) }
        guard reply.count >= 1 else {
            return .replyBufferTooSmall(requiredByteCount: 1)
        }
        reply[0] = configurationValue
        return .dataIn(byteCount: 1)
    }

    private mutating func setConfiguration(
        _ setup: USBSetupPacket
    ) -> USBControlAction {
        guard setup.requestType.direction == .hostToDevice else {
            return .stall(.invalidDirection)
        }
        guard setup.requestType.recipient == .device else {
            return .stall(.invalidRecipient)
        }
        guard setup.index == 0 else { return .stall(.invalidIndex) }
        guard setup.length == 0 else { return .stall(.invalidLength) }
        guard setup.valueHigh == 0,
              setup.valueLow <= USBDebugDeviceIdentity.configurationValue
        else {
            return .stall(.invalidValue)
        }
        guard state == .addressed || state == .configured else {
            return .stall(.invalidState)
        }

        pendingMutation = .configuration(setup.valueLow)
        return .statusIn
    }

    private func getInterface(
        _ setup: USBSetupPacket,
        reply: UnsafeMutableRawBufferPointer
    ) -> USBControlAction {
        guard setup.requestType.direction == .deviceToHost else {
            return .stall(.invalidDirection)
        }
        guard setup.requestType.recipient == .interface else {
            return .stall(.invalidRecipient)
        }
        guard setup.value == 0 else { return .stall(.invalidValue) }
        guard setup.length == 1 else { return .stall(.invalidLength) }
        guard state == .configured else { return .stall(.invalidState) }
        guard setup.indexHigh == 0 else { return .stall(.invalidIndex) }
        guard USBDebugDeviceIdentity.isKnownInterface(setup.indexLow) else {
            return .stall(.unknownInterface)
        }
        guard reply.count >= 1 else {
            return .replyBufferTooSmall(requiredByteCount: 1)
        }
        reply[0] = 0
        return .dataIn(byteCount: 1)
    }

    private mutating func setInterface(
        _ setup: USBSetupPacket
    ) -> USBControlAction {
        guard setup.requestType.direction == .hostToDevice else {
            return .stall(.invalidDirection)
        }
        guard setup.requestType.recipient == .interface else {
            return .stall(.invalidRecipient)
        }
        guard setup.length == 0 else { return .stall(.invalidLength) }
        guard state == .configured else { return .stall(.invalidState) }
        guard setup.indexHigh == 0 else { return .stall(.invalidIndex) }
        guard USBDebugDeviceIdentity.isKnownInterface(setup.indexLow) else {
            return .stall(.unknownInterface)
        }
        guard setup.value == 0 else { return .stall(.invalidValue) }
        guard let interfaceMask = USBDebugDeviceIdentity.endpointHaltMask(
            interface: setup.indexLow
        ) else {
            return .stall(.unknownInterface)
        }
        pendingMutation = .interfaceEndpointHaltClear(mask: interfaceMask)
        return .statusIn
    }
}
