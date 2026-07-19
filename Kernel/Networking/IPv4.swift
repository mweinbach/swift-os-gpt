enum IPv4Protocol {
    static let version: UInt8 = 4
    static let headerWordCount: UInt8 = 5
    static let headerByteCount = 20
    static let maximumTotalByteCount = Int(UInt16.max)
    static let maximumPayloadByteCount = maximumTotalByteCount
        - headerByteCount

    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
}

/// Semantic fields supported by the first SwiftOS IPv4 implementation.
/// Options and fragmented datagrams are intentionally absent from the model.
struct IPv4Header: Equatable {
    let differentiatedServicesAndECN: UInt8
    let identification: UInt16
    let dontFragment: Bool
    let timeToLive: UInt8
    let protocolNumber: UInt8
    let source: IPv4Address
    let destination: IPv4Address
}

struct IPv4DecodedPacket {
    let header: IPv4Header
    let payload: UnsafeRawBufferPointer
    /// Length from the IPv4 header, excluding any Ethernet padding suffix in
    /// the caller's buffer.
    let totalByteCount: Int
}

enum IPv4HeaderEncodeRejection: Equatable {
    case invalidPayloadByteCount(requested: Int, maximum: Int)
    case outputBufferTooSmall(required: Int, available: Int)
    case invalidOutputBuffer
}

enum IPv4HeaderEncodeResult: Equatable {
    case encoded(headerByteCount: Int, totalByteCount: Int)
    case rejected(IPv4HeaderEncodeRejection)
}

enum IPv4HeaderEncoder {
    /// Writes the fixed 20-byte header. The caller owns placement of the
    /// payload immediately after it; `payloadByteCount` is committed into the
    /// total-length field and checksum.
    static func encode(
        _ header: IPv4Header,
        payloadByteCount: Int,
        into output: UnsafeMutableRawBufferPointer
    ) -> IPv4HeaderEncodeResult {
        guard payloadByteCount >= 0,
              payloadByteCount <= IPv4Protocol.maximumPayloadByteCount
        else {
            return .rejected(
                .invalidPayloadByteCount(
                    requested: payloadByteCount,
                    maximum: IPv4Protocol.maximumPayloadByteCount
                )
            )
        }
        let required = IPv4Protocol.headerByteCount
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

        let totalByteCount = required + payloadByteCount
        output[0] = IPv4Protocol.version << 4
            | IPv4Protocol.headerWordCount
        output[1] = header.differentiatedServicesAndECN
        guard NetworkWire.writeUInt16BE(
                  UInt16(totalByteCount),
                  to: output,
                  at: 2
              ),
              NetworkWire.writeUInt16BE(
                  header.identification,
                  to: output,
                  at: 4
              ),
              NetworkWire.writeUInt16BE(
                  header.dontFragment ? 0x4000 : 0,
                  to: output,
                  at: 6
              ),
              NetworkWire.writeUInt16BE(0, to: output, at: 10),
              header.source.encode(to: output, at: 12),
              header.destination.encode(to: output, at: 16)
        else {
            return .rejected(.invalidOutputBuffer)
        }
        output[8] = header.timeToLive
        output[9] = header.protocolNumber

        let headerView = UnsafeRawBufferPointer(
            start: output.baseAddress,
            count: required
        )
        guard let checksum = InternetChecksum.compute(headerView),
              NetworkWire.writeUInt16BE(checksum, to: output, at: 10)
        else {
            return .rejected(.invalidOutputBuffer)
        }
        return .encoded(
            headerByteCount: required,
            totalByteCount: totalByteCount
        )
    }
}

enum IPv4DecodeRejection: Equatable {
    case invalidInputBuffer
    case insufficientBytes(required: Int, available: Int)
    case unsupportedVersion(UInt8)
    case invalidHeaderWordCount(UInt8)
    case unsupportedOptions(headerWordCount: UInt8)
    case invalidTotalLength(UInt16)
    case truncatedPacket(declared: Int, available: Int)
    case invalidHeaderChecksum
    case reservedFragmentFlag
    case fragmentedPacket
}

enum IPv4DecodeResult {
    case decoded(IPv4DecodedPacket)
    case rejected(IPv4DecodeRejection)
}

enum IPv4Decoder {
    static func decode(_ input: UnsafeRawBufferPointer) -> IPv4DecodeResult {
        guard NetworkWire.contains(input, offset: 0, count: input.count) else {
            return .rejected(.invalidInputBuffer)
        }
        let required = IPv4Protocol.headerByteCount
        guard input.count >= required else {
            return .rejected(
                .insufficientBytes(required: required, available: input.count)
            )
        }

        let version = input[0] >> 4
        let headerWordCount = input[0] & 0x0f
        guard version == IPv4Protocol.version else {
            return .rejected(.unsupportedVersion(version))
        }
        guard headerWordCount >= IPv4Protocol.headerWordCount else {
            return .rejected(.invalidHeaderWordCount(headerWordCount))
        }
        guard headerWordCount == IPv4Protocol.headerWordCount else {
            return .rejected(
                .unsupportedOptions(headerWordCount: headerWordCount)
            )
        }
        guard let totalLength = NetworkWire.readUInt16BE(input, at: 2),
              let identification = NetworkWire.readUInt16BE(input, at: 4),
              let fragmentField = NetworkWire.readUInt16BE(input, at: 6),
              let source = IPv4Address.decode(from: input, at: 12),
              let destination = IPv4Address.decode(from: input, at: 16)
        else {
            return .rejected(.invalidInputBuffer)
        }
        guard Int(totalLength) >= required else {
            return .rejected(.invalidTotalLength(totalLength))
        }
        guard Int(totalLength) <= input.count else {
            return .rejected(
                .truncatedPacket(
                    declared: Int(totalLength),
                    available: input.count
                )
            )
        }
        guard let headerBytes = NetworkWire.view(
                  input,
                  offset: 0,
                  count: required
              ),
              InternetChecksum.verifies(headerBytes)
        else {
            return .rejected(.invalidHeaderChecksum)
        }
        guard fragmentField & 0x8000 == 0 else {
            return .rejected(.reservedFragmentFlag)
        }
        guard fragmentField & 0x3fff == 0 else {
            return .rejected(.fragmentedPacket)
        }

        let payloadByteCount = Int(totalLength) - required
        guard let payload = NetworkWire.view(
                  input,
                  offset: required,
                  count: payloadByteCount
              )
        else {
            return .rejected(.invalidInputBuffer)
        }
        return .decoded(
            IPv4DecodedPacket(
                header: IPv4Header(
                    differentiatedServicesAndECN: input[1],
                    identification: identification,
                    dontFragment: fragmentField & 0x4000 != 0,
                    timeToLive: input[8],
                    protocolNumber: input[9],
                    source: source,
                    destination: destination
                ),
                payload: payload,
                totalByteCount: Int(totalLength)
            )
        )
    }
}
