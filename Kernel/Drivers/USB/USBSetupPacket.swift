// Controller-neutral USB 2.0 control-transfer vocabulary. Hardware drivers
// parse the eight-byte SETUP payload here, then execute the returned EP0 action.
// No controller registers, DMA ownership, or policy leak into this layer.

enum USBControlDirection: UInt8 {
    case hostToDevice = 0
    case deviceToHost = 1
}

enum USBControlRequestKind: UInt8 {
    case standard = 0
    case `class` = 1
    case vendor = 2
}

enum USBControlRecipient: UInt8 {
    case device = 0
    case interface = 1
    case endpoint = 2
    case other = 3
}

struct USBRequestType: Equatable {
    let direction: USBControlDirection
    let kind: USBControlRequestKind
    let recipient: USBControlRecipient

    init?(rawValue: UInt8) {
        guard let direction = USBControlDirection(
            rawValue: (rawValue >> 7) & 0x01
        ), let kind = USBControlRequestKind(
            rawValue: (rawValue >> 5) & 0x03
        ), let recipient = USBControlRecipient(rawValue: rawValue & 0x1f)
        else {
            return nil
        }
        self.direction = direction
        self.kind = kind
        self.recipient = recipient
    }

    var rawValue: UInt8 {
        (direction.rawValue << 7)
            | (kind.rawValue << 5)
            | recipient.rawValue
    }
}

struct USBSetupPacket: Equatable {
    static let byteCount = 8

    let requestType: USBRequestType
    let request: UInt8
    let value: UInt16
    let index: UInt16
    let length: UInt16

    static func parse(_ bytes: UnsafeRawBufferPointer) -> USBSetupPacket? {
        guard bytes.count >= byteCount,
              let requestType = USBRequestType(rawValue: bytes[0])
        else {
            return nil
        }
        return USBSetupPacket(
            requestType: requestType,
            request: bytes[1],
            value: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8),
            index: UInt16(bytes[4]) | (UInt16(bytes[5]) << 8),
            length: UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        )
    }

    var valueLow: UInt8 { UInt8(truncatingIfNeeded: value) }
    var valueHigh: UInt8 { UInt8(truncatingIfNeeded: value >> 8) }
    var indexLow: UInt8 { UInt8(truncatingIfNeeded: index) }
    var indexHigh: UInt8 { UInt8(truncatingIfNeeded: index >> 8) }
}

enum USBStandardRequest {
    static let getStatus: UInt8 = 0
    static let clearFeature: UInt8 = 1
    static let setFeature: UInt8 = 3
    static let setAddress: UInt8 = 5
    static let getDescriptor: UInt8 = 6
    static let setDescriptor: UInt8 = 7
    static let getConfiguration: UInt8 = 8
    static let setConfiguration: UInt8 = 9
    static let getInterface: UInt8 = 10
    static let setInterface: UInt8 = 11
    static let synchronizeFrame: UInt8 = 12
}

enum USBDescriptorType {
    static let device: UInt8 = 1
    static let configuration: UInt8 = 2
    static let string: UInt8 = 3
    static let interface: UInt8 = 4
    static let endpoint: UInt8 = 5
    static let deviceQualifier: UInt8 = 6
    static let otherSpeedConfiguration: UInt8 = 7
    static let interfaceAssociation: UInt8 = 11
    static let classSpecificInterface: UInt8 = 0x24
}

enum USBFeatureSelector {
    static let endpointHalt: UInt16 = 0
    static let deviceRemoteWakeup: UInt16 = 1
}

enum USBCDCRequest {
    static let setLineCoding: UInt8 = 0x20
    static let getLineCoding: UInt8 = 0x21
    static let setControlLineState: UInt8 = 0x22
    static let sendBreak: UInt8 = 0x23
}

enum USBControlRejection: Equatable {
    case unsupportedRequestKind
    case unsupportedStandardRequest
    case unsupportedClassRequest
    case invalidDirection
    case invalidRecipient
    case invalidValue
    case invalidIndex
    case invalidLength
    case invalidState
    case unknownDescriptor
    case unknownInterface
    case unknownEndpoint
    case unsupportedFeature
    case unexpectedDataOut
    case malformedClassData
}

enum USBControlAction: Equatable {
    case dataIn(byteCount: UInt16)
    case dataOut(expectedByteCount: UInt16)
    case statusIn
    case stall(USBControlRejection)
    /// The protocol knew the exact response length but the controller did not
    /// supply enough staging space. This is an internal back-pressure result,
    /// not a request to transmit a protocol STALL.
    case replyBufferTooSmall(requiredByteCount: UInt16)
}

enum USBControlStatusCommit: Equatable {
    /// No controller register write is required. Protocol-visible state may
    /// still have committed and should be synchronized after status succeeds.
    case none
    /// Program the controller's device-address register only after returning
    /// this commit from a successfully transmitted status stage.
    case deviceAddress(UInt8)
}

enum USBDeviceState: Equatable {
    case `default`
    case addressed
    case configured
}

enum USBDeviceSpeed: Equatable {
    case full
    case high

    var bulkMaximumPacketSize: UInt16 {
        switch self {
        case .full: return 64
        case .high: return 512
        }
    }

    var opposite: USBDeviceSpeed {
        switch self {
        case .full: return .high
        case .high: return .full
        }
    }
}
