private enum WatchdogRegisterEvent: Equatable {
    case read(offset: UInt)
    case write(offset: UInt, value: UInt32)
}

private final class WatchdogRegisterBank {
    var resetControl: UInt32 = 0
    var resetStatus: UInt32 = 0
    var events: [WatchdogRegisterEvent] = []
}

private struct TestWatchdogRegisters: BCM2712PMWatchdogRegisterAccess {
    let bank: WatchdogRegisterBank

    mutating func read32(at offset: UInt) -> UInt32 {
        bank.events.append(.read(offset: offset))
        switch offset {
        case 0x1c: return bank.resetControl
        case 0x20: return bank.resetStatus
        default: return 0
        }
    }

    mutating func write32(_ value: UInt32, at offset: UInt) {
        bank.events.append(.write(offset: offset, value: value))
        if offset == 0x1c { bank.resetControl = value }
        if offset == 0x20 { bank.resetStatus = value }
    }
}

@main
struct BCM2712PMWatchdogTests {
    static func main() {
        adoptsAndServicesBoundedTimeout()
        rejectsUnencodableTimeoutsWithoutTouchingHardware()
        resetsThroughTheDefaultSelectorPartition()
        print("BCM2712 PM watchdog: 3 groups passed")
    }

    private static func adoptsAndServicesBoundedTimeout() {
        let bank = WatchdogRegisterBank()
        bank.resetControl = 0x0000_00c3
        var watchdog = BCM2712PMWatchdog(
            registers: TestWatchdogRegisters(bank: bank)
        )
        expect(
            watchdog.adoptAndService(timeoutSeconds: 15) == .adopted,
            "valid 15-second watchdog timeout was rejected"
        )
        expect(
            bank.events == [
                .write(offset: 0x24, value: 0x5a0f_0000),
                .read(offset: 0x1c),
                .write(offset: 0x1c, value: 0x5a00_00e3),
            ],
            "watchdog adoption did not program deadline then full reset"
        )
        bank.events.removeAll(keepingCapacity: true)
        expect(watchdog.service(), "adopted watchdog refused a service kick")
        expect(
            bank.events == [
                .write(offset: 0x24, value: 0x5a0f_0000),
            ],
            "watchdog service changed reset policy"
        )
    }

    private static func rejectsUnencodableTimeoutsWithoutTouchingHardware() {
        for timeout in [UInt32(0), 16, UInt32.max] {
            let bank = WatchdogRegisterBank()
            var watchdog = BCM2712PMWatchdog(
                registers: TestWatchdogRegisters(bank: bank)
            )
            expect(
                watchdog.adoptAndService(timeoutSeconds: timeout)
                    == .invalidTimeout,
                "unencodable watchdog timeout was accepted"
            )
            expect(bank.events.isEmpty, "invalid timeout touched watchdog MMIO")
            expect(!watchdog.service(), "unadopted watchdog accepted a kick")
        }
    }

    private static func resetsThroughTheDefaultSelectorPartition() {
        let bank = WatchdogRegisterBank()
        bank.resetStatus = 0x0000_5555
        bank.resetControl = 0x0000_00df
        var watchdog = BCM2712PMWatchdog(
            registers: TestWatchdogRegisters(bank: bank)
        )
        watchdog.programResetToDefault()
        expect(
            bank.events == [
                .read(offset: 0x20),
                .write(offset: 0x20, value: 0x5a00_5000),
                .write(offset: 0x24, value: 0x5a00_000a),
                .read(offset: 0x1c),
                .write(offset: 0x1c, value: 0x5a00_00ef),
            ],
            "reset did not clear partition bits before arming full reset"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() { fatalError(message) }
    }
}
