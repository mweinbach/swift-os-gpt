enum ARPEthernetIPv4Protocol {
    static let packetByteCount = 28
    static let ethernetHardwareType: UInt16 = 1
    static let ipv4ProtocolType = EtherType.ipv4.rawValue
    static let ethernetAddressByteCount: UInt8 = 6
    static let ipv4AddressByteCount: UInt8 = 4
}

enum ARPOperation: UInt16, Equatable {
    case request = 1
    case reply = 2
}

/// The fixed ARP packet shape used to resolve IPv4 addresses on Ethernet.
struct ARPEthernetIPv4Packet: Equatable {
    let operation: ARPOperation
    let senderHardwareAddress: MACAddress
    let senderProtocolAddress: IPv4Address
    let targetHardwareAddress: MACAddress
    let targetProtocolAddress: IPv4Address
}

enum ARPEthernetIPv4EncodeRejection: Equatable {
    case outputBufferTooSmall(required: Int, available: Int)
    case invalidOutputBuffer
}

enum ARPEthernetIPv4EncodeResult: Equatable {
    case encoded(byteCount: Int)
    case rejected(ARPEthernetIPv4EncodeRejection)
}

enum ARPEthernetIPv4Encoder {
    static func encode(
        _ packet: ARPEthernetIPv4Packet,
        into output: UnsafeMutableRawBufferPointer
    ) -> ARPEthernetIPv4EncodeResult {
        let required = ARPEthernetIPv4Protocol.packetByteCount
        guard output.count >= required else {
            return .rejected(
                .outputBufferTooSmall(
                    required: required,
                    available: output.count
                )
            )
        }
        guard NetworkWire.contains(output, offset: 0, count: required) else {
            return .rejected(.invalidOutputBuffer)
        }

        guard NetworkWire.writeUInt16BE(
                  ARPEthernetIPv4Protocol.ethernetHardwareType,
                  to: output,
                  at: 0
              ),
              NetworkWire.writeUInt16BE(
                  ARPEthernetIPv4Protocol.ipv4ProtocolType,
                  to: output,
                  at: 2
              ),
              NetworkWire.writeUInt16BE(
                  packet.operation.rawValue,
                  to: output,
                  at: 6
              ),
              packet.senderHardwareAddress.encode(to: output, at: 8),
              packet.senderProtocolAddress.encode(to: output, at: 14),
              packet.targetHardwareAddress.encode(to: output, at: 18),
              packet.targetProtocolAddress.encode(to: output, at: 24)
        else {
            return .rejected(.invalidOutputBuffer)
        }
        output[4] = ARPEthernetIPv4Protocol.ethernetAddressByteCount
        output[5] = ARPEthernetIPv4Protocol.ipv4AddressByteCount
        return .encoded(byteCount: required)
    }
}

enum ARPEthernetIPv4DecodeRejection: Equatable {
    case invalidInputBuffer
    case insufficientBytes(required: Int, available: Int)
    case unsupportedHardwareType(UInt16)
    case unsupportedProtocolType(UInt16)
    case invalidHardwareAddressLength(UInt8)
    case invalidProtocolAddressLength(UInt8)
    case unsupportedOperation(UInt16)
}

enum ARPEthernetIPv4DecodeResult: Equatable {
    case decoded(ARPEthernetIPv4Packet)
    case rejected(ARPEthernetIPv4DecodeRejection)
}

enum ARPEthernetIPv4Decoder {
    /// Parses the first 28 bytes and deliberately tolerates a trailing Ethernet
    /// padding suffix.
    static func decode(
        _ input: UnsafeRawBufferPointer
    ) -> ARPEthernetIPv4DecodeResult {
        guard NetworkWire.contains(input, offset: 0, count: input.count) else {
            return .rejected(.invalidInputBuffer)
        }
        let required = ARPEthernetIPv4Protocol.packetByteCount
        guard input.count >= required else {
            return .rejected(
                .insufficientBytes(required: required, available: input.count)
            )
        }
        guard let hardwareType = NetworkWire.readUInt16BE(input, at: 0),
              let protocolType = NetworkWire.readUInt16BE(input, at: 2),
              let operationRawValue = NetworkWire.readUInt16BE(input, at: 6)
        else {
            return .rejected(.invalidInputBuffer)
        }
        guard hardwareType == ARPEthernetIPv4Protocol.ethernetHardwareType
        else {
            return .rejected(.unsupportedHardwareType(hardwareType))
        }
        guard protocolType == ARPEthernetIPv4Protocol.ipv4ProtocolType else {
            return .rejected(.unsupportedProtocolType(protocolType))
        }
        guard input[4] == ARPEthernetIPv4Protocol.ethernetAddressByteCount
        else {
            return .rejected(.invalidHardwareAddressLength(input[4]))
        }
        guard input[5] == ARPEthernetIPv4Protocol.ipv4AddressByteCount else {
            return .rejected(.invalidProtocolAddressLength(input[5]))
        }
        guard let operation = ARPOperation(rawValue: operationRawValue) else {
            return .rejected(.unsupportedOperation(operationRawValue))
        }
        guard let senderHardwareAddress = MACAddress.decode(
                  from: input,
                  at: 8
              ),
              let senderProtocolAddress = IPv4Address.decode(
                  from: input,
                  at: 14
              ),
              let targetHardwareAddress = MACAddress.decode(
                  from: input,
                  at: 18
              ),
              let targetProtocolAddress = IPv4Address.decode(
                  from: input,
                  at: 24
              )
        else {
            return .rejected(.invalidInputBuffer)
        }
        return .decoded(
            ARPEthernetIPv4Packet(
                operation: operation,
                senderHardwareAddress: senderHardwareAddress,
                senderProtocolAddress: senderProtocolAddress,
                targetHardwareAddress: targetHardwareAddress,
                targetProtocolAddress: targetProtocolAddress
            )
        )
    }
}
