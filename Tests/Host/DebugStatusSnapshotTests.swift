@main
struct DebugStatusSnapshotTests {
    static func main() {
        validatesResourceCounts()
        validatesDisplayContract()
        validatesLogRangesAndStatus()
        print("debug status snapshot host tests: 3 groups passed")
    }

    private static func validatesResourceCounts() {
        expect(make(snapshotSequence: 0) == nil, "zero sequence")
        expect(
            make(configuredProcessors: 0, onlineProcessors: 0) != nil,
            "early processor discovery"
        )
        expect(
            make(configuredProcessors: 2, onlineProcessors: 3) == nil,
            "too many online processors"
        )
        expect(
            make(managedMemory: 100, freeMemory: 101) == nil,
            "free memory exceeds managed"
        )
    }

    private static func validatesDisplayContract() {
        expect(
            make(displayState: .presenting, width: 0, height: 1080, refresh: 60_000) == nil,
            "active zero-width display"
        )
        expect(
            make(displayState: .configured, width: 1920, height: 1080, refresh: 0) != nil,
            "unknown active refresh"
        )
        expect(
            make(displayState: .unavailable, width: 1920, height: 1080, refresh: 60_000) == nil,
            "inactive display metadata"
        )
    }

    private static func validatesLogRangesAndStatus() {
        expect(make(oldestLog: 0, newestLog: 9) == nil, "half-empty log range")
        expect(make(oldestLog: 10, newestLog: 9) == nil, "reversed log range")

        let flags = DebugStatusFlags(
            rawValue: DebugStatusFlags.interruptsEnabled.rawValue
                | DebugStatusFlags.preemptionEnabled.rawValue
        )
        let snapshot = make(
            flags: flags,
            displayState: .presenting,
            width: 2560,
            height: 1440,
            refresh: 59_940,
            oldestLog: 20,
            newestLog: 42,
            lostLogs: 7,
            error: DebugStatusError(domain: 4, code: 9, detail: 11)
        )!
        expect(snapshot.hasRetainedLogs, "retained log flag")
        expect(snapshot.flags.contains(.interruptsEnabled), "interrupt flag")
        expect(snapshot.flags.contains(.preemptionEnabled), "preemption flag")
        expect(!snapshot.flags.contains(.degraded), "unexpected degraded flag")
        expect(snapshot.lastError.isPresent, "error presence")
        expect(!DebugStatusError.none.isPresent, "none error presence")
        expect(snapshot.displayRefreshMilliHertz == 59_940, "refresh value")
        expect(DebugStatusSnapshot.schemaVersion == 1, "snapshot schema")
    }

    private static func make(
        snapshotSequence: UInt64 = 1,
        flags: DebugStatusFlags = DebugStatusFlags(rawValue: 0),
        configuredProcessors: UInt16 = 4,
        onlineProcessors: UInt16 = 4,
        managedMemory: UInt64 = 8 * 1_024 * 1_024,
        freeMemory: UInt64 = 4 * 1_024 * 1_024,
        displayState: DebugDisplayState = .unavailable,
        width: UInt32 = 0,
        height: UInt32 = 0,
        refresh: UInt32 = 0,
        oldestLog: UInt64 = 0,
        newestLog: UInt64 = 0,
        lostLogs: UInt64 = 0,
        error: DebugStatusError = .none
    ) -> DebugStatusSnapshot? {
        DebugStatusSnapshot(
            snapshotSequence: snapshotSequence,
            monotonicTicks: 99,
            bootSessionID: KernelIdentity128(high: 10, low: 20)!,
            phase: .schedulerRunning,
            flags: flags,
            configuredProcessorCount: configuredProcessors,
            onlineProcessorCount: onlineProcessors,
            runnableThreadCount: 3,
            managedMemoryByteCount: managedMemory,
            freeMemoryByteCount: freeMemory,
            displayState: displayState,
            displayWidthPixels: width,
            displayHeightPixels: height,
            displayRefreshMilliHertz: refresh,
            debugLinkState: .ready,
            updateState: .idle,
            oldestLogSequence: oldestLog,
            newestLogSequence: newestLog,
            lostLogEntryCount: lostLogs,
            lastError: error
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fatalError("FAIL: \(message)") }
    }
}
