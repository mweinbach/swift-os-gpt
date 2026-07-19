struct DWC2MMIORegisterAccess: DWC2RegisterAccess {
    private let baseAddress: UInt

    init?(baseAddress: UInt64, length: UInt64) {
        guard baseAddress <= UInt64(UInt.max),
              baseAddress & 0x3 == 0,
              length >= DWC2RegisterLayout.minimumApertureLength,
              length <= UInt64.max - baseAddress
        else {
            return nil
        }
        self.baseAddress = UInt(baseAddress)
    }

    @inline(__always)
    mutating func read32(at offset: UInt) -> UInt32 {
        MMIO.load32(at: baseAddress + offset)
    }

    @inline(__always)
    mutating func write32(_ value: UInt32, at offset: UInt) {
        MMIO.store32(value, at: baseAddress + offset)
    }

    /// Synopsys requires mode forcing to settle before subsequent core-mode
    /// accesses. Use the architectural counter instead of a board clock and
    /// retain a bounded spin fallback if firmware failed to initialize it.
    mutating func settleAfterModeChange() -> Bool {
        let frequency = AArch64.counterFrequency
        guard frequency >= 40 else { return false }
        let requiredTicks = frequency / 40 // 25 milliseconds.
        let start = AArch64.counterValue
        var remainingSpins = 20_000_000
        while AArch64.counterValue &- start < requiredTicks {
            guard remainingSpins > 0 else { return false }
            remainingSpins -= 1
            AArch64.spinHint()
        }
        return true
    }
}

typealias DWC2DeviceController = DWC2Controller<DWC2MMIORegisterAccess>

extension DWC2Controller where Registers == DWC2MMIORegisterAccess {
    init?(baseAddress: UInt64, length: UInt64) {
        guard let registers = DWC2MMIORegisterAccess(
                  baseAddress: baseAddress,
                  length: length
              )
        else {
            return nil
        }
        self.init(registers: registers)
    }
}
