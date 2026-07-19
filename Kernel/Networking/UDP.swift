enum UDPProtocol {
    static let headerByteCount = 8
    static let maximumDatagramByteCount = Int(UInt16.max)
    static let maximumPayloadByteCount = maximumDatagramByteCount
        - headerByteCount
}

enum UDPChecksumDisposition: Equatable {
    /// IPv4 permits a zero UDP checksum to mean that the sender omitted it.
    case omitted
    case verified
}

struct UDPDatagram {
    let sourcePort: UInt16
    let destinationPort: UInt16
    let payload: UnsafeRawBufferPointer
    let checksumDisposition: UDPChecksumDisposition
    let wireByteCount: Int
}

enum UDPEncodeRejection: Equatable {
    case invalidPayloadBuffer
    case payloadTooLarge(requested: Int, maximum: Int)
    case outputBufferTooSmall(required: Int, available: Int)
    case invalidOutputBuffer
}

enum UDPEncodeResult: Equatable {
    case encoded(byteCount: Int, checksum: UInt16)
    case rejected(UDPEncodeRejection)
}

enum UDPEncoder {
    static func encode(
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: UnsafeRawBufferPointer,
        includeChecksum: Bool,
        into output: UnsafeMutableRawBufferPointer
    ) -> UDPEncodeResult {
        guard NetworkWire.contains(payload, offset: 0, count: payload.count)
        else {
            return .rejected(.invalidPayloadBuffer)
        }
        guard payload.count <= UDPProtocol.maximumPayloadByteCount else {
            return .rejected(
                .payloadTooLarge(
                    requested: payload.count,
                    maximum: UDPProtocol.maximumPayloadByteCount
                )
            )
        }
        let datagramByteCount = UDPProtocol.headerByteCount + payload.count
        guard output.count >= datagramByteCount else {
            return .rejected(
                .outputBufferTooSmall(
                    required: datagramByteCount,
                    available: output.count
                )
            )
        }
        guard NetworkWire.contains(
                  output,
                  offset: 0,
                  count: datagramByteCount
              )
        else {
            return .rejected(.invalidOutputBuffer)
        }

        guard NetworkWire.writeUInt16BE(sourcePort, to: output, at: 0),
              NetworkWire.writeUInt16BE(destinationPort, to: output, at: 2),
              NetworkWire.writeUInt16BE(
                  UInt16(datagramByteCount),
                  to: output,
                  at: 4
              ),
              NetworkWire.writeUInt16BE(0, to: output, at: 6),
              NetworkWire.copy(
                  payload,
                  into: output,
                  at: UDPProtocol.headerByteCount
              )
        else {
            return .rejected(.invalidOutputBuffer)
        }

        guard includeChecksum else {
            return .encoded(byteCount: datagramByteCount, checksum: 0)
        }
        let datagram = UnsafeRawBufferPointer(
            start: output.baseAddress,
            count: datagramByteCount
        )
        guard let rawChecksum = UDPIPv4Checksum.compute(
                  sourceAddress: sourceAddress,
                  destinationAddress: destinationAddress,
                  datagram: datagram
              )
        else {
            return .rejected(.invalidOutputBuffer)
        }
        // A computed all-zero one's-complement checksum is transmitted as all
        // ones so it cannot be confused with IPv4's "checksum omitted" value.
        let wireChecksum: UInt16 = rawChecksum == 0 ? UInt16.max : rawChecksum
        guard NetworkWire.writeUInt16BE(wireChecksum, to: output, at: 6) else {
            return .rejected(.invalidOutputBuffer)
        }
        return .encoded(
            byteCount: datagramByteCount,
            checksum: wireChecksum
        )
    }
}

enum UDPDecodeRejection: Equatable {
    case invalidInputBuffer
    case insufficientBytes(required: Int, available: Int)
    case invalidLength(UInt16)
    case truncatedDatagram(declared: Int, available: Int)
    case trailingBytes(declared: Int, available: Int)
    case invalidChecksum
}

enum UDPDecodeResult {
    case decoded(UDPDatagram)
    case rejected(UDPDecodeRejection)
}

enum UDPDecoder {
    /// Decodes one complete IPv4 payload. The UDP length must consume the
    /// payload exactly; Ethernet padding must first be removed by IPv4Decoder.
    static func decode(
        _ input: UnsafeRawBufferPointer,
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address
    ) -> UDPDecodeResult {
        guard NetworkWire.contains(input, offset: 0, count: input.count) else {
            return .rejected(.invalidInputBuffer)
        }
        let required = UDPProtocol.headerByteCount
        guard input.count >= required else {
            return .rejected(
                .insufficientBytes(required: required, available: input.count)
            )
        }
        guard let sourcePort = NetworkWire.readUInt16BE(input, at: 0),
              let destinationPort = NetworkWire.readUInt16BE(input, at: 2),
              let length = NetworkWire.readUInt16BE(input, at: 4),
              let wireChecksum = NetworkWire.readUInt16BE(input, at: 6)
        else {
            return .rejected(.invalidInputBuffer)
        }
        guard Int(length) >= required else {
            return .rejected(.invalidLength(length))
        }
        guard Int(length) <= input.count else {
            return .rejected(
                .truncatedDatagram(
                    declared: Int(length),
                    available: input.count
                )
            )
        }
        guard Int(length) == input.count else {
            return .rejected(
                .trailingBytes(
                    declared: Int(length),
                    available: input.count
                )
            )
        }

        let checksumDisposition: UDPChecksumDisposition
        if wireChecksum == 0 {
            checksumDisposition = .omitted
        } else {
            guard UDPIPv4Checksum.verifies(
                      sourceAddress: sourceAddress,
                      destinationAddress: destinationAddress,
                      datagram: input
                  )
            else {
                return .rejected(.invalidChecksum)
            }
            checksumDisposition = .verified
        }
        guard let payload = NetworkWire.view(
                  input,
                  offset: required,
                  count: input.count - required
              )
        else {
            return .rejected(.invalidInputBuffer)
        }
        return .decoded(
            UDPDatagram(
                sourcePort: sourcePort,
                destinationPort: destinationPort,
                payload: payload,
                checksumDisposition: checksumDisposition,
                wireByteCount: input.count
            )
        )
    }
}

enum UDPIPv4Checksum {
    static func compute(
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        datagram: UnsafeRawBufferPointer
    ) -> UInt16? {
        guard datagram.count >= UDPProtocol.headerByteCount,
              datagram.count <= UDPProtocol.maximumDatagramByteCount,
              NetworkWire.contains(datagram, offset: 0, count: datagram.count)
        else {
            return nil
        }
        var accumulator = InternetChecksumAccumulator()
        accumulator.updateUInt32BE(sourceAddress.rawValue)
        accumulator.updateUInt32BE(destinationAddress.rawValue)
        accumulator.update(byte: 0)
        accumulator.update(byte: IPv4Protocol.udp)
        accumulator.updateUInt16BE(UInt16(datagram.count))
        guard accumulator.update(datagram) else { return nil }
        return accumulator.value
    }

    static func verifies(
        sourceAddress: IPv4Address,
        destinationAddress: IPv4Address,
        datagram: UnsafeRawBufferPointer
    ) -> Bool {
        compute(
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            datagram: datagram
        ) == 0
    }
}
