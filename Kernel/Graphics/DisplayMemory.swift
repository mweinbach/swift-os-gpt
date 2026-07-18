struct DMAAddressWidth: Equatable {
    let bitCount: UInt8

    private init(validatedBitCount: UInt8) {
        self.bitCount = validatedBitCount
    }

    init?(bitCount: UInt8) {
        guard bitCount > 0, bitCount <= 64 else {
            return nil
        }
        self.bitCount = bitCount
    }

    static var bits32: DMAAddressWidth {
        DMAAddressWidth(validatedBitCount: 32)
    }

    static var bits40: DMAAddressWidth {
        DMAAddressWidth(validatedBitCount: 40)
    }

    static var bits48: DMAAddressWidth {
        DMAAddressWidth(validatedBitCount: 48)
    }

    static var bits64: DMAAddressWidth {
        DMAAddressWidth(validatedBitCount: 64)
    }

    var highestAddress: UInt64 {
        if bitCount == 64 {
            return UInt64.max
        }
        return (UInt64(1) << UInt64(bitCount)) - 1
    }

    func contains(address: UInt64, byteCount: UInt64) -> Bool {
        guard byteCount > 0 else {
            return false
        }
        let (lastAddress, overflow) = address.addingReportingOverflow(byteCount - 1)
        return !overflow && lastAddress <= highestAddress
    }
}

enum DMACoherency: UInt8, Equatable {
    case hardwareCoherent
    case softwareManaged

    var requiresCPUCacheMaintenance: Bool {
        self == .softwareManaged
    }
}

struct DMAMapping: Equatable {
    let cpuPhysicalAddress: UInt64
    let deviceAddress: UInt64
    let byteCount: UInt64
    let deviceAddressWidth: DMAAddressWidth
    let coherency: DMACoherency

    init?(
        cpuPhysicalAddress: UInt64,
        deviceAddress: UInt64,
        byteCount: UInt64,
        deviceAddressWidth: DMAAddressWidth,
        coherency: DMACoherency
    ) {
        guard byteCount > 0,
              !cpuPhysicalAddress.addingReportingOverflow(byteCount - 1).overflow,
              deviceAddressWidth.contains(
                address: deviceAddress,
                byteCount: byteCount
              )
        else {
            return nil
        }

        self.cpuPhysicalAddress = cpuPhysicalAddress
        self.deviceAddress = deviceAddress
        self.byteCount = byteCount
        self.deviceAddressWidth = deviceAddressWidth
        self.coherency = coherency
    }

    var isIdentityMapped: Bool {
        cpuPhysicalAddress == deviceAddress
    }
}

struct ScanoutBuffer: Equatable {
    let mode: DisplayMode
    let bytesPerRow: UInt64
    let mapping: DMAMapping

    init?(
        mode: DisplayMode,
        bytesPerRow: UInt64,
        mapping: DMAMapping
    ) {
        let bytesPerPixel = mode.pixelFormat.bytesPerPixel
        guard bytesPerRow >= mode.minimumBytesPerRow,
              bytesPerRow % bytesPerPixel == 0,
              UInt64(mode.heightInPixels) <= UInt64.max / bytesPerRow
        else {
            return nil
        }

        let requiredByteCount = bytesPerRow * UInt64(mode.heightInPixels)
        guard requiredByteCount <= mapping.byteCount else {
            return nil
        }

        self.mode = mode
        self.bytesPerRow = bytesPerRow
        self.mapping = mapping
    }

    var requiredByteCount: UInt64 {
        bytesPerRow * UInt64(mode.heightInPixels)
    }
}
