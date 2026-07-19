enum ICMPEchoProtocol {
    static let headerByteCount = 8
    static let maximumMessageByteCount = IPv4Protocol.maximumPayloadByteCount
    static let maximumPayloadByteCount = maximumMessageByteCount
        - headerByteCount
}

enum ICMPEchoType: UInt8, Equatable {
    case reply = 0
    case request = 8
}

struct ICMPEchoMessage {
    let type: ICMPEchoType
    let identifier: UInt16
    let sequenceNumber: UInt16
    let payload: UnsafeRawBufferPointer
    let wireByteCount: Int
}

enum ICMPEchoEncodeRejection: Equatable {
    case invalidPayloadBuffer
    case payloadTooLarge(requested: Int, maximum: Int)
    case outputBufferTooSmall(required: Int, available: Int)
    case invalidOutputBuffer
}

enum ICMPEchoEncodeResult: Equatable {
    case encoded(byteCount: Int, checksum: UInt16)
    case rejected(ICMPEchoEncodeRejection)
}

enum ICMPEchoEncoder {
    static func encode(
        type: ICMPEchoType,
        identifier: UInt16,
        sequenceNumber: UInt16,
        payload: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer
    ) -> ICMPEchoEncodeResult {
        guard NetworkWire.contains(payload, offset: 0, count: payload.count)
        else {
            return .rejected(.invalidPayloadBuffer)
        }
        guard payload.count <= ICMPEchoProtocol.maximumPayloadByteCount else {
            return .rejected(
                .payloadTooLarge(
                    requested: payload.count,
                    maximum: ICMPEchoProtocol.maximumPayloadByteCount
                )
            )
        }
        let messageByteCount = ICMPEchoProtocol.headerByteCount + payload.count
        guard output.count >= messageByteCount else {
            return .rejected(
                .outputBufferTooSmall(
                    required: messageByteCount,
                    available: output.count
                )
            )
        }
        guard NetworkWire.contains(
                  output,
                  offset: 0,
                  count: messageByteCount
              )
        else {
            return .rejected(.invalidOutputBuffer)
        }

        output[0] = type.rawValue
        output[1] = 0
        guard NetworkWire.writeUInt16BE(0, to: output, at: 2),
              NetworkWire.writeUInt16BE(identifier, to: output, at: 4),
              NetworkWire.writeUInt16BE(sequenceNumber, to: output, at: 6),
              NetworkWire.copy(
                  payload,
                  into: output,
                  at: ICMPEchoProtocol.headerByteCount
              )
        else {
            return .rejected(.invalidOutputBuffer)
        }
        let message = UnsafeRawBufferPointer(
            start: output.baseAddress,
            count: messageByteCount
        )
        guard let checksum = InternetChecksum.compute(message),
              NetworkWire.writeUInt16BE(checksum, to: output, at: 2)
        else {
            return .rejected(.invalidOutputBuffer)
        }
        return .encoded(byteCount: messageByteCount, checksum: checksum)
    }
}

enum ICMPEchoDecodeRejection: Equatable {
    case invalidInputBuffer
    case insufficientBytes(required: Int, available: Int)
    case messageTooLarge(maximum: Int, available: Int)
    case unsupportedType(UInt8)
    case nonzeroCode(UInt8)
    case invalidChecksum
}

enum ICMPEchoDecodeResult {
    case decoded(ICMPEchoMessage)
    case rejected(ICMPEchoDecodeRejection)
}

enum ICMPEchoDecoder {
    static func decode(_ input: UnsafeRawBufferPointer) -> ICMPEchoDecodeResult {
        guard NetworkWire.contains(input, offset: 0, count: input.count) else {
            return .rejected(.invalidInputBuffer)
        }
        let required = ICMPEchoProtocol.headerByteCount
        guard input.count >= required else {
            return .rejected(
                .insufficientBytes(required: required, available: input.count)
            )
        }
        guard input.count <= ICMPEchoProtocol.maximumMessageByteCount else {
            return .rejected(
                .messageTooLarge(
                    maximum: ICMPEchoProtocol.maximumMessageByteCount,
                    available: input.count
                )
            )
        }
        guard let type = ICMPEchoType(rawValue: input[0]) else {
            return .rejected(.unsupportedType(input[0]))
        }
        guard input[1] == 0 else {
            return .rejected(.nonzeroCode(input[1]))
        }
        guard InternetChecksum.verifies(input) else {
            return .rejected(.invalidChecksum)
        }
        guard let identifier = NetworkWire.readUInt16BE(input, at: 4),
              let sequenceNumber = NetworkWire.readUInt16BE(input, at: 6),
              let payload = NetworkWire.view(
                  input,
                  offset: required,
                  count: input.count - required
              )
        else {
            return .rejected(.invalidInputBuffer)
        }
        return .decoded(
            ICMPEchoMessage(
                type: type,
                identifier: identifier,
                sequenceNumber: sequenceNumber,
                payload: payload,
                wireByteCount: input.count
            )
        )
    }
}
