@main
struct BootLivenessPolicyTests {
    static func main() {
        timerProofReportsThreeInterruptsInOrder()
        timerProofUsesWrapSafeDeadlineAndBaseline()
        uartPollingIsFiniteAndRecoversBeforeItsDeadline()
        print("boot liveness policy host tests: 3 groups passed")
    }

    private static func timerProofReportsThreeInterruptsInOrder() {
        var policy = requireTimerPolicy(
            startedAtTicks: 100,
            startingInterruptCount: 40,
            timeoutTicks: 1_000
        )
        expect(
            policy.poll(
                counterTick: 100,
                deliveredInterruptCount: 40
            ) == .waiting,
            "proof did not wait at its baseline"
        )
        expect(
            policy.poll(
                counterTick: 101,
                deliveredInterruptCount: 43
            ) == .report(1),
            "first coalesced IRQ was not reported first"
        )
        expect(
            policy.poll(
                counterTick: 101,
                deliveredInterruptCount: 43
            ) == .report(2),
            "second coalesced IRQ was not reported second"
        )
        expect(
            policy.poll(
                counterTick: 101,
                deliveredInterruptCount: 43
            ) == .report(3),
            "third coalesced IRQ was not reported third"
        )
        expect(policy.isComplete, "three IRQs did not complete the proof")
        expect(
            policy.poll(
                counterTick: 101,
                deliveredInterruptCount: 43
            ) == .complete,
            "completed proof did not remain complete"
        )
    }

    private static func timerProofUsesWrapSafeDeadlineAndBaseline() {
        expect(
            CooperativeTimerProofPolicy(
                startedAtTicks: 0,
                startingInterruptCount: 0,
                timeoutTicks: 0
            ) == nil,
            "zero timer-proof timeout was accepted"
        )
        var policy = requireTimerPolicy(
            startedAtTicks: UInt64.max - 2,
            startingInterruptCount: UInt64.max,
            timeoutTicks: 5
        )
        expect(
            policy.poll(
                counterTick: 1,
                deliveredInterruptCount: UInt64.max
            ) == .waiting,
            "wrapping counter timed out early"
        )
        expect(
            policy.poll(
                counterTick: 2,
                deliveredInterruptCount: 0
            ) == .report(1),
            "wrapping interrupt delta lost delivery"
        )
        expect(
            policy.poll(
                counterTick: 3,
                deliveredInterruptCount: 0
            ) == .timedOut,
            "proof did not stop at its counter deadline"
        )
    }

    private static func uartPollingIsFiniteAndRecoversBeforeItsDeadline() {
        var ready = PL011TransmitPollingPolicy(
            maximumFullObservations: 3
        )
        expect(
            ready.observe(transmitFIFOIsFull: false) == .ready,
            "empty TX FIFO was not immediately writable"
        )
        expect(ready.fullObservationCount == 0, "ready path spent poll budget")

        var recovers = PL011TransmitPollingPolicy(
            maximumFullObservations: 3
        )
        expect(
            recovers.observe(transmitFIFOIsFull: true) == .retry,
            "first full FIFO observation did not retry"
        )
        expect(
            recovers.observe(transmitFIFOIsFull: false) == .ready,
            "FIFO readiness before deadline was rejected"
        )

        var dead = PL011TransmitPollingPolicy(
            maximumFullObservations: 3
        )
        expect(dead.observe(transmitFIFOIsFull: true) == .retry, "poll one")
        expect(dead.observe(transmitFIFOIsFull: true) == .retry, "poll two")
        expect(
            dead.observe(transmitFIFOIsFull: true) == .timedOut,
            "dead UART exceeded its full-observation budget"
        )
        expect(dead.fullObservationCount == 3, "UART poll accounting changed")

        var zero = PL011TransmitPollingPolicy(
            maximumFullObservations: 0
        )
        expect(
            zero.observe(transmitFIFOIsFull: true) == .timedOut,
            "zero UART poll budget did not fail immediately"
        )

        var deadRegisters = TestPL011TransmitRegisters(
            flags: [0x20, 0x20, 0x20]
        )
        expect(
            !transmitPL011Byte(
                0x41,
                registers: &deadRegisters,
                transmitFIFOFullMask: 0x20,
                maximumFullObservations: 3
            ),
            "dead UART transmission succeeded"
        )
        expect(deadRegisters.readCount == 3, "UART exceeded read budget")
        expect(deadRegisters.relaxCount == 2, "UART retry count changed")
        expect(deadRegisters.writtenBytes.isEmpty, "timed-out UART wrote data")

        var lastChanceRegisters = TestPL011TransmitRegisters(
            flags: [0x20, 0x20, 0]
        )
        expect(
            transmitPL011Byte(
                0x42,
                registers: &lastChanceRegisters,
                transmitFIFOFullMask: 0x20,
                maximumFullObservations: 3
            ),
            "UART readiness on final allowed observation was rejected"
        )
        expect(lastChanceRegisters.readCount == 3, "final poll was skipped")
        expect(lastChanceRegisters.writtenBytes == [0x42], "UART wrote != once")
    }

    private static func requireTimerPolicy(
        startedAtTicks: UInt64,
        startingInterruptCount: UInt64,
        timeoutTicks: UInt64
    ) -> CooperativeTimerProofPolicy {
        guard let policy = CooperativeTimerProofPolicy(
                  startedAtTicks: startedAtTicks,
                  startingInterruptCount: startingInterruptCount,
                  timeoutTicks: timeoutTicks
              )
        else { fatalError("valid timer proof policy was rejected") }
        return policy
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fatalError("boot liveness policy test failed: \(message)")
        }
    }
}

private struct TestPL011TransmitRegisters: PL011TransmitRegisterAccess {
    let flags: [UInt32]
    private(set) var readCount = 0
    private(set) var relaxCount = 0
    private(set) var writtenBytes: [UInt8] = []

    mutating func readTransmitFlags() -> UInt32 {
        let index = min(readCount, flags.count - 1)
        readCount += 1
        return flags[index]
    }

    mutating func writeTransmitData(_ byte: UInt8) {
        writtenBytes.append(byte)
    }

    mutating func relaxTransmitPoll() {
        relaxCount += 1
    }
}
