/// Valid Ethernet II type field. Values below 0x0600 are IEEE 802.3 length
/// encodings (or the reserved gap) and are deliberately not accepted here.
struct EtherType: RawRepresentable, Equatable {
    static let minimumRawValue: UInt16 = 0x0600

    static let ipv4 = EtherType(knownRawValue: 0x0800)
    static let arp = EtherType(knownRawValue: 0x0806)

    let rawValue: UInt16

    init?(rawValue: UInt16) {
        guard rawValue >= Self.minimumRawValue else { return nil }
        self.rawValue = rawValue
    }

    private init(knownRawValue: UInt16) {
        rawValue = knownRawValue
    }
}

enum EthernetIIProtocol {
    static let headerByteCount = 14
    static let minimumPayloadByteCount = 46
    static let minimumFrameByteCountWithoutFCS = 60
    static let maximumPayloadByteCount = 1_500
    static let maximumFrameByteCountWithoutFCS = headerByteCount
        + maximumPayloadByteCount
}

/// A borrowed view into a receive buffer. The link driver retains ownership of
/// the storage for the lifetime of this value. An Ethernet padding suffix, if
/// present, remains in `payload`; IPv4 and ARP codecs use their own wire lengths
/// to exclude it.
struct EthernetIIFrame {
    let destination: MACAddress
    let source: MACAddress
    let etherType: EtherType
    let payload: UnsafeRawBufferPointer
    let wireByteCount: Int
}

enum EthernetIIEncodeRejection: Equatable {
    case invalidPayloadBuffer
    case payloadTooLarge(requested: Int, maximum: Int)
    case outputBufferTooSmall(required: Int, available: Int)
    case invalidOutputBuffer
}

enum EthernetIIEncodeResult: Equatable {
    case encoded(byteCount: Int)
    case rejected(EthernetIIEncodeRejection)
}

enum EthernetIIFrameEncoder {
    /// Encodes an Ethernet II frame without an FCS. Short payloads are padded
    /// with zeroes to the 60-byte frame minimum; a device driver may then ask
    /// hardware to append the four-byte FCS.
    static func encode(
        destination: MACAddress,
        source: MACAddress,
        etherType: EtherType,
        payload: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer
    ) -> EthernetIIEncodeResult {
        guard NetworkWire.contains(payload, offset: 0, count: payload.count)
        else {
            return .rejected(.invalidPayloadBuffer)
        }
        guard payload.count <= EthernetIIProtocol.maximumPayloadByteCount else {
            return .rejected(
                .payloadTooLarge(
                    requested: payload.count,
                    maximum: EthernetIIProtocol.maximumPayloadByteCount
                )
            )
        }

        let unpaddedByteCount = EthernetIIProtocol.headerByteCount
            + payload.count
        let encodedByteCount = unpaddedByteCount
            < EthernetIIProtocol.minimumFrameByteCountWithoutFCS
            ? EthernetIIProtocol.minimumFrameByteCountWithoutFCS
            : unpaddedByteCount
        guard output.count >= encodedByteCount else {
            return .rejected(
                .outputBufferTooSmall(
                    required: encodedByteCount,
                    available: output.count
                )
            )
        }
        guard NetworkWire.contains(output, offset: 0, count: encodedByteCount)
        else {
            return .rejected(.invalidOutputBuffer)
        }

        guard destination.encode(to: output, at: 0),
              source.encode(to: output, at: 6),
              NetworkWire.writeUInt16BE(
                  etherType.rawValue,
                  to: output,
                  at: 12
              ),
              NetworkWire.copy(
                  payload,
                  into: output,
                  at: EthernetIIProtocol.headerByteCount
              ),
              NetworkWire.zero(
                  output,
                  offset: unpaddedByteCount,
                  count: encodedByteCount - unpaddedByteCount
              )
        else {
            return .rejected(.invalidOutputBuffer)
        }
        return .encoded(byteCount: encodedByteCount)
    }
}

enum EthernetIIDecodeRejection: Equatable {
    case invalidInputBuffer
    case frameTooShort(minimum: Int, available: Int)
    case frameTooLarge(maximum: Int, available: Int)
    case notEthernetII(typeOrLength: UInt16)
}

enum EthernetIIDecodeResult {
    case decoded(EthernetIIFrame)
    case rejected(EthernetIIDecodeRejection)
}

enum EthernetIIFrameDecoder {
    /// Decodes a driver-supplied frame after the hardware FCS has been removed.
    /// Undersized frames are accepted down to the 14-byte header because some
    /// virtual links omit link padding; encoders always emit the wire minimum.
    static func decode(
        _ input: UnsafeRawBufferPointer
    ) -> EthernetIIDecodeResult {
        guard NetworkWire.contains(input, offset: 0, count: input.count) else {
            return .rejected(.invalidInputBuffer)
        }
        guard input.count >= EthernetIIProtocol.headerByteCount else {
            return .rejected(
                .frameTooShort(
                    minimum: EthernetIIProtocol.headerByteCount,
                    available: input.count
                )
            )
        }
        guard input.count
                <= EthernetIIProtocol.maximumFrameByteCountWithoutFCS
        else {
            return .rejected(
                .frameTooLarge(
                    maximum:
                        EthernetIIProtocol.maximumFrameByteCountWithoutFCS,
                    available: input.count
                )
            )
        }
        guard let destination = MACAddress.decode(from: input, at: 0),
              let source = MACAddress.decode(from: input, at: 6),
              let rawEtherType = NetworkWire.readUInt16BE(input, at: 12)
        else {
            return .rejected(.invalidInputBuffer)
        }
        guard let etherType = EtherType(rawValue: rawEtherType) else {
            return .rejected(.notEthernetII(typeOrLength: rawEtherType))
        }
        let payloadByteCount = input.count - EthernetIIProtocol.headerByteCount
        guard let payload = NetworkWire.view(
                  input,
                  offset: EthernetIIProtocol.headerByteCount,
                  count: payloadByteCount
              )
        else {
            return .rejected(.invalidInputBuffer)
        }
        return .decoded(
            EthernetIIFrame(
                destination: destination,
                source: source,
                etherType: etherType,
                payload: payload,
                wireByteCount: input.count
            )
        )
    }
}
