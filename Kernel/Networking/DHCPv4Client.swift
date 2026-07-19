/// Allocation-free DHCPv4 client state and wire handling.
///
/// The caller supplies a stable transaction identifier and a monotonic tick
/// source. Tick units are deliberately opaque: retry policy values and
/// `nowTicks` only need to use the same clock. The state machine owns no packet
/// storage and retains no borrowed buffer after a call returns.
enum DHCPv4MessageType: UInt8, Equatable {
    case discover = 1
    case offer = 2
    case request = 3
    case decline = 4
    case acknowledgement = 5
    case negativeAcknowledgement = 6
    case release = 7
    case inform = 8
}

enum DHCPv4ClientPhase: UInt8, Equatable {
    case stopped
    case selecting
    case requesting
    case bound
}

enum DHCPv4ClientAction: UInt8, Equatable {
    case sendDiscover
    case sendRequest
}

struct DHCPv4RetryPolicy: Equatable {
    let initialRetryTicks: UInt64
    let maximumRetryTicks: UInt64

    init(initialRetryTicks: UInt64, maximumRetryTicks: UInt64) {
        self.initialRetryTicks = initialRetryTicks == 0 ? 1 : initialRetryTicks
        self.maximumRetryTicks = maximumRetryTicks < self.initialRetryTicks
            ? self.initialRetryTicks
            : maximumRetryTicks
    }
}

struct DHCPv4Lease: Equatable {
    let address: IPv4Address
    let subnetMask: IPv4Address?
    let router: IPv4Address?
    let domainNameServer: IPv4Address?
    let serverIdentifier: IPv4Address
    let leaseDurationSeconds: UInt32?
    let acquiredAtTicks: UInt64
}

struct DHCPv4Offer: Equatable {
    let address: IPv4Address
    let subnetMask: IPv4Address?
    let router: IPv4Address?
    let domainNameServer: IPv4Address?
    let serverIdentifier: IPv4Address
    let leaseDurationSeconds: UInt32?
}

enum DHCPv4ReceiveRejection: Equatable {
    case invalidBuffer
    case packetTooShort(required: Int, available: Int)
    case notBootReply(UInt8)
    case unsupportedHardware(type: UInt8, addressLength: UInt8)
    case transactionMismatch(UInt32)
    case clientHardwareAddressMismatch
    case invalidMagicCookie
    case malformedOptions
    case missingMessageType
    case unexpectedMessageType(DHCPv4MessageType)
    case invalidOfferedAddress
    case missingServerIdentifier
    case serverIdentifierMismatch
    case acknowledgedAddressMismatch
}

enum DHCPv4ReceiveResult: Equatable {
    case ignored
    case offered(DHCPv4Offer)
    case bound(DHCPv4Lease)
    case restartedAfterNegativeAcknowledgement
    case rejected(DHCPv4ReceiveRejection)
}

enum DHCPv4EncodeRejection: Equatable {
    case actionDoesNotMatchState
    case missingOffer
    case outputBufferTooSmall(required: Int, available: Int)
    case invalidOutputBuffer
}

enum DHCPv4EncodeResult: Equatable {
    case encoded(byteCount: Int)
    case rejected(DHCPv4EncodeRejection)
}

private struct DHCPv4ParsedReply {
    let transactionIdentifier: UInt32
    let clientHardwareAddress: MACAddress
    let offeredAddress: IPv4Address
    let messageType: DHCPv4MessageType
    let subnetMask: IPv4Address?
    let router: IPv4Address?
    let domainNameServer: IPv4Address?
    let serverIdentifier: IPv4Address?
    let leaseDurationSeconds: UInt32?
}

private enum DHCPv4ReplyDecodeResult {
    case decoded(DHCPv4ParsedReply)
    case rejected(DHCPv4ReceiveRejection)
}

private enum DHCPv4Wire {
    static let bootRequest: UInt8 = 1
    static let bootReply: UInt8 = 2
    static let ethernetHardwareType: UInt8 = 1
    static let ethernetHardwareAddressLength: UInt8 = 6
    static let fixedHeaderByteCount = 236
    static let optionsOffset = 240
    static let minimumReplyByteCount = optionsOffset
    /// RFC 2131 clients accept at least 576-byte IP datagrams. A 300-byte
    /// BOOTP/DHCP payload stays compatible with legacy relays while leaving
    /// ample room in a normal Ethernet MTU.
    static let clientPacketByteCount = 300
    static let magicCookie: UInt32 = 0x6382_5363

    static let optionPad: UInt8 = 0
    static let optionSubnetMask: UInt8 = 1
    static let optionRouter: UInt8 = 3
    static let optionDomainNameServer: UInt8 = 6
    static let optionRequestedAddress: UInt8 = 50
    static let optionLeaseTime: UInt8 = 51
    static let optionMessageType: UInt8 = 53
    static let optionServerIdentifier: UInt8 = 54
    static let optionParameterRequestList: UInt8 = 55
    static let optionMaximumMessageSize: UInt8 = 57
    static let optionClientIdentifier: UInt8 = 61
    static let optionEnd: UInt8 = 255

    static func decodeReply(
        _ input: UnsafeRawBufferPointer
    ) -> DHCPv4ReplyDecodeResult {
        guard NetworkWire.contains(input, offset: 0, count: input.count) else {
            return .rejected(.invalidBuffer)
        }
        guard input.count >= minimumReplyByteCount else {
            return .rejected(
                .packetTooShort(
                    required: minimumReplyByteCount,
                    available: input.count
                )
            )
        }
        guard input[0] == bootReply else {
            return .rejected(.notBootReply(input[0]))
        }
        guard input[1] == ethernetHardwareType,
              input[2] == ethernetHardwareAddressLength
        else {
            return .rejected(
                .unsupportedHardware(type: input[1], addressLength: input[2])
            )
        }
        guard let transactionIdentifier = NetworkWire.readUInt32BE(
                  input,
                  at: 4
              ),
              let offeredAddress = IPv4Address.decode(from: input, at: 16),
              let clientHardwareAddress = MACAddress.decode(from: input, at: 28),
              let magicCookie = NetworkWire.readUInt32BE(input, at: 236)
        else {
            return .rejected(.invalidBuffer)
        }
        guard magicCookie == self.magicCookie else {
            return .rejected(.invalidMagicCookie)
        }

        var messageType: DHCPv4MessageType?
        var subnetMask: IPv4Address?
        var router: IPv4Address?
        var domainNameServer: IPv4Address?
        var serverIdentifier: IPv4Address?
        var leaseDurationSeconds: UInt32?
        var offset = optionsOffset
        var foundEnd = false

        while offset < input.count {
            let code = input[offset]
            offset += 1
            if code == optionPad { continue }
            if code == optionEnd {
                foundEnd = true
                break
            }
            guard offset < input.count else {
                return .rejected(.malformedOptions)
            }
            let length = Int(input[offset])
            offset += 1
            guard NetworkWire.contains(input, offset: offset, count: length)
            else {
                return .rejected(.malformedOptions)
            }

            switch code {
            case optionMessageType:
                guard length == 1,
                      messageType == nil,
                      let decoded = DHCPv4MessageType(rawValue: input[offset])
                else {
                    return .rejected(.malformedOptions)
                }
                messageType = decoded
            case optionSubnetMask:
                guard length == 4,
                      subnetMask == nil,
                      let decoded = IPv4Address.decode(from: input, at: offset)
                else {
                    return .rejected(.malformedOptions)
                }
                subnetMask = decoded
            case optionRouter:
                guard length >= 4,
                      length & 3 == 0,
                      router == nil,
                      let decoded = IPv4Address.decode(from: input, at: offset)
                else {
                    return .rejected(.malformedOptions)
                }
                router = decoded
            case optionDomainNameServer:
                guard length >= 4,
                      length & 3 == 0,
                      domainNameServer == nil,
                      let decoded = IPv4Address.decode(from: input, at: offset)
                else {
                    return .rejected(.malformedOptions)
                }
                domainNameServer = decoded
            case optionServerIdentifier:
                guard length == 4,
                      serverIdentifier == nil,
                      let decoded = IPv4Address.decode(from: input, at: offset)
                else {
                    return .rejected(.malformedOptions)
                }
                serverIdentifier = decoded
            case optionLeaseTime:
                guard length == 4,
                      leaseDurationSeconds == nil,
                      let decoded = NetworkWire.readUInt32BE(input, at: offset)
                else {
                    return .rejected(.malformedOptions)
                }
                leaseDurationSeconds = decoded
            default:
                break
            }
            offset += length
        }

        guard foundEnd else { return .rejected(.malformedOptions) }
        guard let messageType else {
            return .rejected(.missingMessageType)
        }
        return .decoded(
            DHCPv4ParsedReply(
                transactionIdentifier: transactionIdentifier,
                clientHardwareAddress: clientHardwareAddress,
                offeredAddress: offeredAddress,
                messageType: messageType,
                subnetMask: subnetMask,
                router: router,
                domainNameServer: domainNameServer,
                serverIdentifier: serverIdentifier,
                leaseDurationSeconds: leaseDurationSeconds
            )
        )
    }

    static func encodeClientPacket(
        action: DHCPv4ClientAction,
        transactionIdentifier: UInt32,
        hardwareAddress: MACAddress,
        offer: DHCPv4Offer?,
        into output: UnsafeMutableRawBufferPointer
    ) -> DHCPv4EncodeResult {
        let required = clientPacketByteCount
        guard output.count >= required else {
            return .rejected(
                .outputBufferTooSmall(
                    required: required,
                    available: output.count
                )
            )
        }
        guard NetworkWire.contains(output, offset: 0, count: required),
              NetworkWire.zero(output, offset: 0, count: required)
        else {
            return .rejected(.invalidOutputBuffer)
        }
        if action == .sendRequest && offer == nil {
            return .rejected(.missingOffer)
        }

        output[0] = bootRequest
        output[1] = ethernetHardwareType
        output[2] = ethernetHardwareAddressLength
        guard NetworkWire.writeUInt32BE(
                  transactionIdentifier,
                  to: output,
                  at: 4
              ),
              NetworkWire.writeUInt16BE(0x8000, to: output, at: 10),
              hardwareAddress.encode(to: output, at: 28),
              NetworkWire.writeUInt32BE(magicCookie, to: output, at: 236)
        else {
            return .rejected(.invalidOutputBuffer)
        }

        var offset = optionsOffset
        guard writeOptionByte(
                  optionMessageType,
                  value: action == .sendDiscover
                      ? DHCPv4MessageType.discover.rawValue
                      : DHCPv4MessageType.request.rawValue,
                  to: output,
                  offset: &offset
              ),
              writeClientIdentifier(
                  hardwareAddress,
                  to: output,
                  offset: &offset
              )
        else {
            return .rejected(.invalidOutputBuffer)
        }

        if let offer {
            guard writeOptionAddress(
                      optionRequestedAddress,
                      value: offer.address,
                      to: output,
                      offset: &offset
                  ),
                  writeOptionAddress(
                      optionServerIdentifier,
                      value: offer.serverIdentifier,
                      to: output,
                      offset: &offset
                  )
            else {
                return .rejected(.invalidOutputBuffer)
            }
        }

        guard writeMaximumMessageSize(to: output, offset: &offset),
              writeParameterRequestList(to: output, offset: &offset),
              offset < required
        else {
            return .rejected(.invalidOutputBuffer)
        }
        output[offset] = optionEnd
        return .encoded(byteCount: required)
    }

    private static func writeOptionByte(
        _ code: UInt8,
        value: UInt8,
        to output: UnsafeMutableRawBufferPointer,
        offset: inout Int
    ) -> Bool {
        guard NetworkWire.contains(output, offset: offset, count: 3) else {
            return false
        }
        output[offset] = code
        output[offset + 1] = 1
        output[offset + 2] = value
        offset += 3
        return true
    }

    private static func writeOptionAddress(
        _ code: UInt8,
        value: IPv4Address,
        to output: UnsafeMutableRawBufferPointer,
        offset: inout Int
    ) -> Bool {
        guard NetworkWire.contains(output, offset: offset, count: 6) else {
            return false
        }
        output[offset] = code
        output[offset + 1] = 4
        guard value.encode(to: output, at: offset + 2) else { return false }
        offset += 6
        return true
    }

    private static func writeClientIdentifier(
        _ hardwareAddress: MACAddress,
        to output: UnsafeMutableRawBufferPointer,
        offset: inout Int
    ) -> Bool {
        guard NetworkWire.contains(output, offset: offset, count: 9) else {
            return false
        }
        output[offset] = optionClientIdentifier
        output[offset + 1] = 7
        output[offset + 2] = ethernetHardwareType
        guard hardwareAddress.encode(to: output, at: offset + 3) else {
            return false
        }
        offset += 9
        return true
    }

    private static func writeMaximumMessageSize(
        to output: UnsafeMutableRawBufferPointer,
        offset: inout Int
    ) -> Bool {
        guard NetworkWire.contains(output, offset: offset, count: 4) else {
            return false
        }
        output[offset] = optionMaximumMessageSize
        output[offset + 1] = 2
        guard NetworkWire.writeUInt16BE(576, to: output, at: offset + 2) else {
            return false
        }
        offset += 4
        return true
    }

    private static func writeParameterRequestList(
        to output: UnsafeMutableRawBufferPointer,
        offset: inout Int
    ) -> Bool {
        guard NetworkWire.contains(output, offset: offset, count: 7) else {
            return false
        }
        output[offset] = optionParameterRequestList
        output[offset + 1] = 5
        output[offset + 2] = optionSubnetMask
        output[offset + 3] = optionRouter
        output[offset + 4] = optionDomainNameServer
        output[offset + 5] = optionLeaseTime
        output[offset + 6] = optionServerIdentifier
        offset += 7
        return true
    }
}

struct DHCPv4Client {
    let hardwareAddress: MACAddress
    let transactionIdentifier: UInt32
    let retryPolicy: DHCPv4RetryPolicy

    private(set) var phase: DHCPv4ClientPhase = .stopped
    private(set) var nextRetryDeadlineTicks: UInt64 = 0
    private(set) var retryAttempt: UInt8 = 0
    private(set) var selectedOffer: DHCPv4Offer?
    private(set) var lease: DHCPv4Lease?

    init(
        hardwareAddress: MACAddress,
        transactionIdentifier: UInt32,
        retryPolicy: DHCPv4RetryPolicy
    ) {
        self.hardwareAddress = hardwareAddress
        self.transactionIdentifier = transactionIdentifier
        self.retryPolicy = retryPolicy
    }

    mutating func start(nowTicks: UInt64) {
        phase = .selecting
        selectedOffer = nil
        lease = nil
        retryAttempt = 0
        nextRetryDeadlineTicks = nowTicks
    }

    mutating func stop() {
        phase = .stopped
        selectedOffer = nil
        lease = nil
        retryAttempt = 0
        nextRetryDeadlineTicks = 0
    }

    func actionDue(nowTicks: UInt64) -> DHCPv4ClientAction? {
        guard nowTicks >= nextRetryDeadlineTicks else { return nil }
        switch phase {
        case .selecting:
            return .sendDiscover
        case .requesting:
            return .sendRequest
        case .stopped, .bound:
            return nil
        }
    }

    func encode(
        action: DHCPv4ClientAction,
        into output: UnsafeMutableRawBufferPointer
    ) -> DHCPv4EncodeResult {
        switch (phase, action) {
        case (.selecting, .sendDiscover):
            break
        case (.requesting, .sendRequest):
            guard selectedOffer != nil else {
                return .rejected(.missingOffer)
            }
        default:
            return .rejected(.actionDoesNotMatchState)
        }
        return DHCPv4Wire.encodeClientPacket(
            action: action,
            transactionIdentifier: transactionIdentifier,
            hardwareAddress: hardwareAddress,
            offer: selectedOffer,
            into: output
        )
    }

    /// Advances exponential retry state only after a link accepted the frame.
    /// A transient device failure therefore remains immediately retryable.
    mutating func noteTransmitted(
        action: DHCPv4ClientAction,
        nowTicks: UInt64
    ) {
        guard (phase == .selecting && action == .sendDiscover)
                || (phase == .requesting && action == .sendRequest)
        else {
            return
        }
        let interval = retryInterval(attempt: retryAttempt)
        nextRetryDeadlineTicks = saturatingAdd(nowTicks, interval)
        if retryAttempt != UInt8.max { retryAttempt &+= 1 }
    }

    mutating func receive(
        _ input: UnsafeRawBufferPointer,
        nowTicks: UInt64
    ) -> DHCPv4ReceiveResult {
        let parsed: DHCPv4ParsedReply
        switch DHCPv4Wire.decodeReply(input) {
        case .decoded(let packet):
            parsed = packet
        case .rejected(let rejection):
            return .rejected(rejection)
        }

        guard parsed.transactionIdentifier == transactionIdentifier else {
            return .rejected(
                .transactionMismatch(parsed.transactionIdentifier)
            )
        }
        guard parsed.clientHardwareAddress == hardwareAddress else {
            return .rejected(.clientHardwareAddressMismatch)
        }

        switch parsed.messageType {
        case .offer:
            guard phase == .selecting else { return .ignored }
            guard !parsed.offeredAddress.isUnspecified,
                  !parsed.offeredAddress.isLimitedBroadcast,
                  !parsed.offeredAddress.isMulticast
            else {
                return .rejected(.invalidOfferedAddress)
            }
            guard let serverIdentifier = parsed.serverIdentifier else {
                return .rejected(.missingServerIdentifier)
            }
            let offer = DHCPv4Offer(
                address: parsed.offeredAddress,
                subnetMask: parsed.subnetMask,
                router: parsed.router,
                domainNameServer: parsed.domainNameServer,
                serverIdentifier: serverIdentifier,
                leaseDurationSeconds: parsed.leaseDurationSeconds
            )
            selectedOffer = offer
            phase = .requesting
            retryAttempt = 0
            nextRetryDeadlineTicks = nowTicks
            return .offered(offer)

        case .acknowledgement:
            guard phase == .requesting, let offer = selectedOffer else {
                return .ignored
            }
            guard let responseServer = parsed.serverIdentifier else {
                return .rejected(.missingServerIdentifier)
            }
            if responseServer != offer.serverIdentifier {
                return .rejected(.serverIdentifierMismatch)
            }
            guard parsed.offeredAddress == offer.address else {
                return .rejected(.acknowledgedAddressMismatch)
            }
            let boundLease = DHCPv4Lease(
                address: parsed.offeredAddress,
                subnetMask: parsed.subnetMask ?? offer.subnetMask,
                router: parsed.router ?? offer.router,
                domainNameServer:
                    parsed.domainNameServer ?? offer.domainNameServer,
                serverIdentifier: offer.serverIdentifier,
                leaseDurationSeconds:
                    parsed.leaseDurationSeconds ?? offer.leaseDurationSeconds,
                acquiredAtTicks: nowTicks
            )
            lease = boundLease
            phase = .bound
            retryAttempt = 0
            nextRetryDeadlineTicks = UInt64.max
            return .bound(boundLease)

        case .negativeAcknowledgement:
            guard phase == .requesting else { return .ignored }
            phase = .selecting
            selectedOffer = nil
            lease = nil
            retryAttempt = 0
            nextRetryDeadlineTicks = nowTicks
            return .restartedAfterNegativeAcknowledgement

        default:
            return .rejected(.unexpectedMessageType(parsed.messageType))
        }
    }

    private func retryInterval(attempt: UInt8) -> UInt64 {
        var interval = retryPolicy.initialRetryTicks
        var remainingDoublings = attempt
        while remainingDoublings > 0,
              interval < retryPolicy.maximumRetryTicks
        {
            if interval > retryPolicy.maximumRetryTicks / 2 {
                interval = retryPolicy.maximumRetryTicks
            } else {
                interval *= 2
            }
            remainingDoublings &-= 1
        }
        return interval > retryPolicy.maximumRetryTicks
            ? retryPolicy.maximumRetryTicks
            : interval
    }

    private func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? UInt64.max : sum
    }
}
