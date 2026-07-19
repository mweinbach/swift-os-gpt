struct RP1GEMDeferredActivationGateTests {
    private var failures = 0

    mutating func run() -> Int32 {
        testRejectsZeroDelay()
        testPolicyProvidesFiveSecondObservationWindow()
        testPolicyRejectsInvalidCounterFrequencies()
        testDelayBeginsOnFirstService()
        testFiresExactlyOnce()
        testCounterWrap()

        if failures == 0 {
            print("PASS: RP1 GEM deferred activation gate")
            return 0
        }
        print("FAIL: \(failures) RP1 GEM deferred activation assertion(s)")
        return 1
    }

    private mutating func testPolicyProvidesFiveSecondObservationWindow() {
        var gate = RP1GEMDeferredActivationPolicy.makeGate(
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
            RP1GEMDeferredActivationPolicy.makeGate(
                counterFrequency: 0
            ) == nil,
            "zero-frequency policy is rejected"
        )
        expect(
            RP1GEMDeferredActivationPolicy.makeGate(
                counterFrequency: UInt64.max
            ) == nil,
            "overflowing policy is rejected"
        )
    }

    private mutating func testRejectsZeroDelay() {
        expect(
            RP1GEMDeferredActivationGate(delayTicks: 0) == nil,
            "zero-delay activation is rejected"
        )
    }

    private mutating func testDelayBeginsOnFirstService() {
        var gate = RP1GEMDeferredActivationGate(delayTicks: 10)!
        expect(!gate.poll(nowTicks: 1_000), "first service only arms")
        expect(!gate.poll(nowTicks: 1_009), "partial delay remains deferred")
        expect(gate.poll(nowTicks: 1_010), "exact deadline starts activation")
    }

    private mutating func testFiresExactlyOnce() {
        var gate = RP1GEMDeferredActivationGate(delayTicks: 1)!
        expect(!gate.poll(nowTicks: 50), "one-tick gate arms")
        expect(gate.poll(nowTicks: 51), "one-tick gate fires")
        expect(!gate.poll(nowTicks: 52), "consumed gate stays quiet")
        expect(!gate.poll(nowTicks: UInt64.max), "consumed gate never wraps")
    }

    private mutating func testCounterWrap() {
        var gate = RP1GEMDeferredActivationGate(delayTicks: 5)!
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
enum RP1GEMDeferredActivationGateTestMain {
    static func main() {
        var tests = RP1GEMDeferredActivationGateTests()
        let result = tests.run()
        if result != 0 {
            fatalError("RP1 GEM deferred activation tests failed")
        }
    }
}
