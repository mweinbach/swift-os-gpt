protocol BCM2712PMWatchdogRegisterAccess {
    mutating func read32(at offset: UInt) -> UInt32
    mutating func write32(_ value: UInt32, at offset: UInt)
}

enum BCM2712PMWatchdogAdoptionResult: Equatable {
    case adopted
    case invalidTimeout
}

/// BCM2712 retains the passworded Raspberry Pi PM watchdog register ABI. The
/// policy is injected over register access so timeout and reset-partition
/// behavior can be proven without host MMIO.
struct BCM2712PMWatchdog<Registers: BCM2712PMWatchdogRegisterAccess> {
    static var resetControlOffset: UInt { 0x1c }
    static var resetStatusOffset: UInt { 0x20 }
    static var watchdogOffset: UInt { 0x24 }

    static var password: UInt32 { 0x5a00_0000 }
    static var timeMask: UInt32 { 0x000f_ffff }
    static var configClearMask: UInt32 { 0xffff_ffcf }
    static var fullReset: UInt32 { 0x20 }
    static var partitionClearMask: UInt32 { 0xffff_faaa }
    static var immediateResetTicks: UInt32 { 10 }

    private var registers: Registers
    private var serviceTicks: UInt32 = 0

    init(registers: Registers) {
        self.registers = registers
    }

    /// Takes over a firmware-started watchdog and gives the kernel a fresh
    /// deadline. Integral seconds are encoded in the PM watchdog's fixed-point
    /// time field by placing seconds in bits 19:16; only 1...15 fits.
    mutating func adoptAndService(
        timeoutSeconds: UInt32
    ) -> BCM2712PMWatchdogAdoptionResult {
        guard timeoutSeconds >= 1, timeoutSeconds <= 15 else {
            return .invalidTimeout
        }
        serviceTicks = timeoutSeconds << 16
        registers.write32(
            Self.password | serviceTicks,
            at: Self.watchdogOffset
        )
        let currentControl = registers.read32(at: Self.resetControlOffset)
        registers.write32(
            Self.password
                | (currentControl & Self.configClearMask)
                | Self.fullReset,
            at: Self.resetControlOffset
        )
        return .adopted
    }

    mutating func service() -> Bool {
        guard serviceTicks != 0,
              serviceTicks & ~Self.timeMask == 0
        else { return false }
        registers.write32(
            Self.password | serviceTicks,
            at: Self.watchdogOffset
        )
        return true
    }

    /// Programs the next reset to return through partition zero, which means
    /// re-evaluate the invariant selector. The caller must issue a data barrier
    /// and stop execution immediately after this succeeds.
    mutating func programResetToDefault() {
        let currentStatus = registers.read32(at: Self.resetStatusOffset)
        registers.write32(
            Self.password | (currentStatus & Self.partitionClearMask),
            at: Self.resetStatusOffset
        )
        registers.write32(
            Self.password | Self.immediateResetTicks,
            at: Self.watchdogOffset
        )
        let currentControl = registers.read32(at: Self.resetControlOffset)
        registers.write32(
            Self.password
                | (currentControl & Self.configClearMask)
                | Self.fullReset,
            at: Self.resetControlOffset
        )
    }
}
