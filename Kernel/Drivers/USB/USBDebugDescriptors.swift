// SwiftOS's development USB identity and descriptor graph. The descriptors
// expose a standards-based CDC ACM console plus a separate, vendor-specific
// bidirectional bulk channel for framed debug-display traffic.

enum USBDebugDeviceIdentity {
    /// Development identity only. Reserve a product ID before distribution.
    static let vendorID: UInt16 = 0x1209
    static let productID: UInt16 = 0x5a17
    static let deviceRelease: UInt16 = 0x0001

    static let configurationValue: UInt8 = 1
    static let interfaceCount: UInt8 = 3
    static let cdcControlInterface: UInt8 = 0
    static let cdcDataInterface: UInt8 = 1
    static let debugDisplayInterface: UInt8 = 2

    static let cdcNotificationEndpoint: UInt8 = 0x81
    static let cdcDataOutEndpoint: UInt8 = 0x02
    static let cdcDataInEndpoint: UInt8 = 0x82
    static let debugDisplayOutEndpoint: UInt8 = 0x03
    static let debugDisplayInEndpoint: UInt8 = 0x83

    static let configurationByteCount: UInt16 = 98

    static func isKnownInterface(_ value: UInt8) -> Bool {
        value < interfaceCount
    }

    static func isKnownDataEndpoint(_ value: UInt8) -> Bool {
        value == cdcNotificationEndpoint
            || value == cdcDataOutEndpoint
            || value == cdcDataInEndpoint
            || value == debugDisplayOutEndpoint
            || value == debugDisplayInEndpoint
    }

    static func endpointHaltBit(_ value: UInt8) -> UInt8? {
        switch value {
        case cdcNotificationEndpoint: return 1 << 0
        case cdcDataOutEndpoint: return 1 << 1
        case cdcDataInEndpoint: return 1 << 2
        case debugDisplayOutEndpoint: return 1 << 3
        case debugDisplayInEndpoint: return 1 << 4
        default: return nil
        }
    }

    static func endpointHaltMask(interface value: UInt8) -> UInt8? {
        switch value {
        case cdcControlInterface: return 1 << 0
        case cdcDataInterface: return (1 << 1) | (1 << 2)
        case debugDisplayInterface: return (1 << 3) | (1 << 4)
        default: return nil
        }
    }
}

enum USBDescriptorWriteResult: Equatable {
    case written(UInt16)
    case unsupported
    case bufferTooSmall(requiredByteCount: UInt16)
}

enum USBDebugDescriptorSet {
    private static let usbRelease: UInt16 = 0x0200
    private static let cdcRelease: UInt16 = 0x0120
    private static let englishUnitedStates: UInt16 = 0x0409

    static func write(
        descriptorType: UInt8,
        descriptorIndex: UInt8,
        languageID: UInt16,
        speed: USBDeviceSpeed,
        requestedLength: UInt16,
        to output: UnsafeMutableRawBufferPointer
    ) -> USBDescriptorWriteResult {
        switch descriptorType {
        case USBDescriptorType.device:
            guard descriptorIndex == 0, languageID == 0 else {
                return .unsupported
            }
            return writeDevice(requestedLength: requestedLength, to: output)
        case USBDescriptorType.configuration:
            guard descriptorIndex == 0, languageID == 0 else {
                return .unsupported
            }
            return writeConfiguration(
                descriptorType: USBDescriptorType.configuration,
                speed: speed,
                requestedLength: requestedLength,
                to: output
            )
        case USBDescriptorType.deviceQualifier:
            guard descriptorIndex == 0, languageID == 0 else {
                return .unsupported
            }
            return writeQualifier(requestedLength: requestedLength, to: output)
        case USBDescriptorType.otherSpeedConfiguration:
            guard descriptorIndex == 0, languageID == 0 else {
                return .unsupported
            }
            return writeConfiguration(
                descriptorType: USBDescriptorType.otherSpeedConfiguration,
                speed: speed.opposite,
                requestedLength: requestedLength,
                to: output
            )
        case USBDescriptorType.string:
            return writeString(
                index: descriptorIndex,
                languageID: languageID,
                requestedLength: requestedLength,
                to: output
            )
        default:
            return .unsupported
        }
    }

    private static func writeDevice(
        requestedLength: UInt16,
        to output: UnsafeMutableRawBufferPointer
    ) -> USBDescriptorWriteResult {
        let total: UInt16 = 18
        guard let length = prepare(
            totalByteCount: total,
            requestedLength: requestedLength,
            output: output
        ) else {
            return .bufferTooSmall(
                requiredByteCount: minimum(total, requestedLength)
            )
        }
        var writer = USBDescriptorWriter(output: output, limit: Int(length))
        writer.byte(18)
        writer.byte(USBDescriptorType.device)
        writer.littleEndian16(usbRelease)
        // Miscellaneous/Common/IAD identifies a composite device whose CDC
        // interfaces are grouped by an Interface Association Descriptor.
        writer.byte(0xef)
        writer.byte(0x02)
        writer.byte(0x01)
        writer.byte(64)
        writer.littleEndian16(USBDebugDeviceIdentity.vendorID)
        writer.littleEndian16(USBDebugDeviceIdentity.productID)
        writer.littleEndian16(USBDebugDeviceIdentity.deviceRelease)
        writer.byte(1)
        writer.byte(2)
        writer.byte(3)
        writer.byte(1)
        return .written(length)
    }

    private static func writeQualifier(
        requestedLength: UInt16,
        to output: UnsafeMutableRawBufferPointer
    ) -> USBDescriptorWriteResult {
        let total: UInt16 = 10
        guard let length = prepare(
            totalByteCount: total,
            requestedLength: requestedLength,
            output: output
        ) else {
            return .bufferTooSmall(
                requiredByteCount: minimum(total, requestedLength)
            )
        }
        var writer = USBDescriptorWriter(output: output, limit: Int(length))
        writer.byte(10)
        writer.byte(USBDescriptorType.deviceQualifier)
        writer.littleEndian16(usbRelease)
        writer.byte(0xef)
        writer.byte(0x02)
        writer.byte(0x01)
        writer.byte(64)
        writer.byte(1)
        writer.byte(0)
        return .written(length)
    }

    private static func writeConfiguration(
        descriptorType: UInt8,
        speed: USBDeviceSpeed,
        requestedLength: UInt16,
        to output: UnsafeMutableRawBufferPointer
    ) -> USBDescriptorWriteResult {
        let total = USBDebugDeviceIdentity.configurationByteCount
        guard let length = prepare(
            totalByteCount: total,
            requestedLength: requestedLength,
            output: output
        ) else {
            return .bufferTooSmall(
                requiredByteCount: minimum(total, requestedLength)
            )
        }

        var writer = USBDescriptorWriter(output: output, limit: Int(length))
        writer.byte(9)
        writer.byte(descriptorType)
        writer.littleEndian16(total)
        writer.byte(USBDebugDeviceIdentity.interfaceCount)
        writer.byte(USBDebugDeviceIdentity.configurationValue)
        writer.byte(0)
        // Bus powered, no remote-wakeup claim, 500 mA maximum at USB 2.0.
        // The DWC2 runtime must implement resume signaling before bit 5 may
        // be advertised here.
        writer.byte(0x80)
        writer.byte(250)

        // CDC function association: control interface 0 and data interface 1.
        writer.bytes(8, USBDescriptorType.interfaceAssociation, 0, 2)
        writer.bytes(0x02, 0x02, 0x01, 4)

        writer.bytes(9, USBDescriptorType.interface, 0, 0)
        writer.bytes(1, 0x02, 0x02, 0x01)
        writer.byte(4)

        // CDC Header, Call Management, ACM, and Union functional descriptors.
        writer.bytes(5, USBDescriptorType.classSpecificInterface, 0x00)
        writer.littleEndian16(cdcRelease)
        writer.bytes(5, USBDescriptorType.classSpecificInterface, 0x01, 0x00)
        writer.byte(USBDebugDeviceIdentity.cdcDataInterface)
        // Line coding/control-line state/serial-state plus SEND_BREAK.
        writer.bytes(4, USBDescriptorType.classSpecificInterface, 0x02, 0x06)
        writer.bytes(5, USBDescriptorType.classSpecificInterface, 0x06)
        writer.bytes(
            USBDebugDeviceIdentity.cdcControlInterface,
            USBDebugDeviceIdentity.cdcDataInterface
        )

        writeEndpoint(
            address: USBDebugDeviceIdentity.cdcNotificationEndpoint,
            attributes: 0x03,
            maximumPacketSize: 16,
            // High-speed interrupt intervals are powers of two in 125 us
            // microframes; 8 therefore matches the 16 ms full-speed cadence.
            interval: speed == .high ? 8 : 16,
            writer: &writer
        )

        writer.bytes(9, USBDescriptorType.interface, 1, 0)
        writer.bytes(2, 0x0a, 0x00, 0x00)
        writer.byte(4)
        writeEndpoint(
            address: USBDebugDeviceIdentity.cdcDataOutEndpoint,
            attributes: 0x02,
            maximumPacketSize: speed.bulkMaximumPacketSize,
            interval: 0,
            writer: &writer
        )
        writeEndpoint(
            address: USBDebugDeviceIdentity.cdcDataInEndpoint,
            attributes: 0x02,
            maximumPacketSize: speed.bulkMaximumPacketSize,
            interval: 0,
            writer: &writer
        )

        // The display channel is intentionally not a USB video-class claim.
        // It carries bounded SwiftOS debug frames over a private bulk protocol.
        writer.bytes(9, USBDescriptorType.interface, 2, 0)
        writer.bytes(2, 0xff, 0x42, 0x01)
        writer.byte(5)
        writeEndpoint(
            address: USBDebugDeviceIdentity.debugDisplayOutEndpoint,
            attributes: 0x02,
            maximumPacketSize: speed.bulkMaximumPacketSize,
            interval: 0,
            writer: &writer
        )
        writeEndpoint(
            address: USBDebugDeviceIdentity.debugDisplayInEndpoint,
            attributes: 0x02,
            maximumPacketSize: speed.bulkMaximumPacketSize,
            interval: 0,
            writer: &writer
        )
        return .written(length)
    }

    private static func writeEndpoint(
        address: UInt8,
        attributes: UInt8,
        maximumPacketSize: UInt16,
        interval: UInt8,
        writer: inout USBDescriptorWriter
    ) {
        writer.byte(7)
        writer.byte(USBDescriptorType.endpoint)
        writer.byte(address)
        writer.byte(attributes)
        writer.littleEndian16(maximumPacketSize)
        writer.byte(interval)
    }

    private static func writeString(
        index: UInt8,
        languageID: UInt16,
        requestedLength: UInt16,
        to output: UnsafeMutableRawBufferPointer
    ) -> USBDescriptorWriteResult {
        if index == 0 {
            guard languageID == 0 else { return .unsupported }
            let total: UInt16 = 4
            guard let length = prepare(
                totalByteCount: total,
                requestedLength: requestedLength,
                output: output
            ) else {
                return .bufferTooSmall(
                    requiredByteCount: minimum(total, requestedLength)
                )
            }
            var writer = USBDescriptorWriter(output: output, limit: Int(length))
            writer.byte(4)
            writer.byte(USBDescriptorType.string)
            writer.littleEndian16(englishUnitedStates)
            return .written(length)
        }

        guard languageID == englishUnitedStates,
              let string = stringValue(index: index)
        else {
            return .unsupported
        }
        let scalarCount = string.utf8CodeUnitCount
        guard scalarCount <= 126 else { return .unsupported }
        let total = UInt16(2 + scalarCount * 2)
        guard let length = prepare(
            totalByteCount: total,
            requestedLength: requestedLength,
            output: output
        ) else {
            return .bufferTooSmall(
                requiredByteCount: minimum(total, requestedLength)
            )
        }
        var writer = USBDescriptorWriter(output: output, limit: Int(length))
        writer.byte(UInt8(total))
        writer.byte(USBDescriptorType.string)
        var index = 0
        while index < scalarCount {
            writer.byte(string.utf8Start[index])
            writer.byte(0)
            index += 1
        }
        return .written(length)
    }

    private static func stringValue(index: UInt8) -> StaticString? {
        switch index {
        case 1: return "SwiftOS"
        case 2: return "SwiftOS USB Debug"
        case 3: return "SWIFTOS-0001"
        case 4: return "SwiftOS Console"
        case 5: return "SwiftOS Debug Display Interface"
        default: return nil
        }
    }

    private static func prepare(
        totalByteCount: UInt16,
        requestedLength: UInt16,
        output: UnsafeMutableRawBufferPointer
    ) -> UInt16? {
        let length = minimum(totalByteCount, requestedLength)
        guard output.count >= Int(length) else { return nil }
        return length
    }

    private static func minimum(_ first: UInt16, _ second: UInt16) -> UInt16 {
        first < second ? first : second
    }
}

private struct USBDescriptorWriter {
    private var output: UnsafeMutableRawBufferPointer
    private let limit: Int
    private var offset = 0

    init(output: UnsafeMutableRawBufferPointer, limit: Int) {
        self.output = output
        self.limit = limit
    }

    mutating func byte(_ value: UInt8) {
        if offset < limit { output[offset] = value }
        offset += 1
    }

    mutating func littleEndian16(_ value: UInt16) {
        byte(UInt8(truncatingIfNeeded: value))
        byte(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func bytes(_ first: UInt8, _ second: UInt8) {
        byte(first)
        byte(second)
    }

    mutating func bytes(_ first: UInt8, _ second: UInt8, _ third: UInt8) {
        byte(first)
        byte(second)
        byte(third)
    }

    mutating func bytes(
        _ first: UInt8,
        _ second: UInt8,
        _ third: UInt8,
        _ fourth: UInt8
    ) {
        byte(first)
        byte(second)
        byte(third)
        byte(fourth)
    }
}
