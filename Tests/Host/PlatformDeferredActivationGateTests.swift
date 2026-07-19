struct PlatformDeferredActivationGateTests {
    private var failures = 0

    mutating func run() -> Int32 {
        testRejectsZeroDelay()
        testPolicyProvidesFiveSecondObservationWindow()
        testPolicyRejectsInvalidCounterFrequencies()
        testDelayBeginsOnFirstService()
        testExplicitArmIsIdempotent()
        testFiresExactlyOnce()
        testCounterWrap()

        if failures == 0 {
            print("PASS: platform deferred activation gate")
            return 0
        }
        print("FAIL: \(failures) platform deferred activation assertion(s)")
        return 1
    }

    private mutating func testPolicyProvidesFiveSecondObservationWindow() {
        var gate = PlatformLocalObservationPolicy.makeGate(
            counterFrequency: 10
        )!
        expect(!gate.poll(nowTicks: 1_000), "policy gate first arms")
        expect(
            !gate.poll(nowTicks: 1_049),
            "policy preserves the full local observation window"
        )
        expect(
            gate.poll(nowTicks: 1_050),
            "policy starts at the five-second deadline"
        )
    }

    private mutating func testPolicyRejectsInvalidCounterFrequencies() {
        expect(
            PlatformLocalObservationPolicy.makeGate(
                counterFrequency: 0
            ) == nil,
            "zero-frequency policy is rejected"
        )
        expect(
            PlatformLocalObservationPolicy.makeGate(
                counterFrequency: UInt64.max
            ) == nil,
            "overflowing policy is rejected"
        )
    }

    private mutating func testRejectsZeroDelay() {
        expect(
            PlatformDeferredActivationGate(delayTicks: 0) == nil,
            "zero-delay activation is rejected"
        )
    }

    private mutating func testDelayBeginsOnFirstService() {
        var gate = PlatformDeferredActivationGate(delayTicks: 10)!
        expect(!gate.poll(nowTicks: 1_000), "first service only arms")
        expect(!gate.poll(nowTicks: 1_009), "partial delay remains deferred")
        expect(gate.poll(nowTicks: 1_010), "exact deadline starts activation")
    }

    private mutating func testExplicitArmIsIdempotent() {
        var gate = PlatformDeferredActivationGate(delayTicks: 10)!
        gate.arm(nowTicks: 100)
        gate.arm(nowTicks: 105)
        expect(!gate.poll(nowTicks: 109), "second arm moved deadline origin")
        expect(gate.poll(nowTicks: 110), "first explicit arm was not retained")
    }

    private mutating func testFiresExactlyOnce() {
        var gate = PlatformDeferredActivationGate(delayTicks: 1)!
        expect(!gate.poll(nowTicks: 50), "one-tick gate arms")
        expect(gate.poll(nowTicks: 51), "one-tick gate fires")
        expect(!gate.poll(nowTicks: 52), "consumed gate stays quiet")
        expect(!gate.poll(nowTicks: UInt64.max), "consumed gate never wraps")
    }

    private mutating func testCounterWrap() {
        var gate = PlatformDeferredActivationGate(delayTicks: 5)!
        expect(
            !gate.poll(nowTicks: UInt64.max - 2),
            "wrapping gate arms near counter maximum"
        )
        expect(!gate.poll(nowTicks: 1), "wrapped partial delay stays deferred")
        expect(gate.poll(nowTicks: 2), "wrapped deadline starts activation")
    }

    private mutating func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            failures += 1
            print("FAIL: \(message)")
            return
        }
    }
}

@main
enum PlatformDeferredActivationGateTestMain {
    static func main() {
        var tests = PlatformDeferredActivationGateTests()
        let result = tests.run()
        if result != 0 {
            fatalError("platform deferred activation tests failed")
        }
    }
}
