struct FirmwareConfigurationFile {
    let selector: UInt16
    let size: UInt32
}

struct FirmwareConfiguration {
    private static let signatureSelector: UInt16 = 0x0000
    private static let revisionSelector: UInt16 = 0x0001
    private static let directorySelector: UInt16 = 0x0019
    private static let dmaFeature: UInt32 = 1 << 1
    private static let dmaSelect: UInt32 = 1 << 3
    private static let dmaWrite: UInt32 = 1 << 4
    private static let dmaError: UInt32 = 1

    private let baseAddress: UInt

    init(baseAddress: UInt64) {
        self.baseAddress = UInt(baseAddress)
    }

    func isAvailable() -> Bool {
        select(Self.signatureSelector)
        guard readDataByte() == 0x51,
              readDataByte() == 0x45,
              readDataByte() == 0x4d,
              readDataByte() == 0x55
        else {
            return false
        }

        select(Self.revisionSelector)
        let revision = readLE32()
        return revision & Self.dmaFeature != 0
    }

    func file(named expectedName: StaticString) -> FirmwareConfigurationFile? {
        select(Self.directorySelector)
        let count = readBE32()
        guard count <= 1024 else {
            return nil
        }

        var index: UInt32 = 0
        while index < count {
            let size = readBE32()
            let selector = readBE16()
            _ = readDataByte()
            _ = readDataByte()
            let matches = readFileName(matching: expectedName)
            if matches {
                return FirmwareConfigurationFile(selector: selector, size: size)
            }
            index += 1
        }
        return nil
    }

    func write(
        file: FirmwareConfigurationFile,
        bytesAt sourceAddress: UInt64,
        count: UInt32,
        descriptorAt descriptorAddress: UInt64
    ) -> Bool {
        guard count <= file.size,
              descriptorAddress & 0xf == 0
        else {
            return false
        }

        let control = UInt32(file.selector) << 16
            | Self.dmaSelect
            | Self.dmaWrite
        PhysicalBytes.writeBE32(control, at: descriptorAddress)
        PhysicalBytes.writeBE32(count, at: descriptorAddress + 4)
        PhysicalBytes.writeBE64(sourceAddress, at: descriptorAddress + 8)
        AArch64.synchronizeData()

        MMIO.store64(
            descriptorAddress.byteSwapped,
            at: baseAddress + 0x10
        )

        var attempts = 0
        while attempts < 100_000 {
            let status = MMIO.load32(at: UInt(descriptorAddress)).byteSwapped
            if status == 0 {
                AArch64.synchronizeData()
                return true
            }
            if status & Self.dmaError != 0 {
                return false
            }
            attempts += 1
        }
        return false
    }

    private func select(_ selector: UInt16) {
        MMIO.store16(selector.byteSwapped, at: baseAddress + 8)
    }

    private func readDataByte() -> UInt8 {
        MMIO.load8(at: baseAddress)
    }

    private func readBE16() -> UInt16 {
        UInt16(readDataByte()) << 8 | UInt16(readDataByte())
    }

    private func readBE32() -> UInt32 {
        UInt32(readDataByte()) << 24
            | UInt32(readDataByte()) << 16
            | UInt32(readDataByte()) << 8
            | UInt32(readDataByte())
    }

    private func readLE32() -> UInt32 {
        let byte0 = UInt32(readDataByte())
        let byte1 = UInt32(readDataByte())
        let byte2 = UInt32(readDataByte())
        let byte3 = UInt32(readDataByte())
        return byte0 | byte1 << 8 | byte2 << 16 | byte3 << 24
    }

    private func readFileName(matching expected: StaticString) -> Bool {
        expected.withUTF8Buffer { expectedBytes in
            var matches = expectedBytes.count < 56
            var terminated = false
            var index = 0
            while index < 56 {
                let byte = readDataByte()
                if index < expectedBytes.count {
                    if byte != expectedBytes[index] {
                        matches = false
                    }
                } else if index == expectedBytes.count {
                    if byte != 0 {
                        matches = false
                    }
                    terminated = byte == 0
                }
                index += 1
            }
            return matches && terminated
        }
    }
}

