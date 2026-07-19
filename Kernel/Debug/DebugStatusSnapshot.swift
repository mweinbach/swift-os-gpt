enum DebugKernelPhase: UInt8, Equatable {
    case reset = 0
    case earlyBoot = 1
    case memoryReady = 2
    case driversReady = 3
    case schedulerRunning = 4
    case userlandRunning = 5
    case updating = 6
    case failed = 255
}

enum DebugLinkState: UInt8, Equatable {
    case unavailable = 0
    case initializing = 1
    case ready = 2
    case connected = 3
    case failed = 255
}

enum DebugDisplayState: UInt8, Equatable {
    case unavailable = 0
    case discovering = 1
    case configured = 2
    case presenting = 3
    case failed = 255
}

enum DebugUpdateState: UInt8, Equatable {
    case idle = 0
    case receiving = 1
    case verifying = 2
    case committed = 3
    case activating = 4
    case rejected = 255
}

struct DebugStatusFlags: RawRepresentable, Equatable {
    let rawValue: UInt32

    static let interruptsEnabled = Self(rawValue: 1 << 0)
    static let virtualMemoryEnabled = Self(rawValue: 1 << 1)
    static let preemptionEnabled = Self(rawValue: 1 << 2)
    static let userlandIsolated = Self(rawValue: 1 << 3)
    static let degraded = Self(rawValue: 1 << 31)

    func contains(_ flag: Self) -> Bool {
        rawValue & flag.rawValue == flag.rawValue
    }
}

struct DebugStatusError: Equatable {
    /// Stable owner-defined namespace. Zero means there is no active error.
    let domain: UInt16
    let code: UInt16
    let detail: UInt32

    static let none = Self(domain: 0, code: 0, detail: 0)

    var isPresent: Bool { domain != 0 || code != 0 || detail != 0 }
}

/// Fixed-width, board-neutral kernel health record. Every field has an integer
/// representation suitable for a future SDBG encoder; no pointer or host-sized
/// integer crosses that boundary.
struct DebugStatusSnapshot: Equatable {
    static let schemaVersion: UInt16 = 1

    let snapshotSequence: UInt64
    let monotonicTicks: UInt64
    let bootSessionID: KernelIdentity128
    let phase: DebugKernelPhase
    let flags: DebugStatusFlags

    let configuredProcessorCount: UInt16
    let onlineProcessorCount: UInt16
    let runnableThreadCount: UInt32

    let managedMemoryByteCount: UInt64
    let freeMemoryByteCount: UInt64

    let displayState: DebugDisplayState
    let displayWidthPixels: UInt32
    let displayHeightPixels: UInt32
    let displayRefreshMilliHertz: UInt32

    let debugLinkState: DebugLinkState
    let updateState: DebugUpdateState

    let oldestLogSequence: UInt64
    let newestLogSequence: UInt64
    let lostLogEntryCount: UInt64
    let lastError: DebugStatusError

    init?(
        snapshotSequence: UInt64,
        monotonicTicks: UInt64,
        bootSessionID: KernelIdentity128,
        phase: DebugKernelPhase,
        flags: DebugStatusFlags,
        configuredProcessorCount: UInt16,
        onlineProcessorCount: UInt16,
        runnableThreadCount: UInt32,
        managedMemoryByteCount: UInt64,
        freeMemoryByteCount: UInt64,
        displayState: DebugDisplayState,
        displayWidthPixels: UInt32,
        displayHeightPixels: UInt32,
        displayRefreshMilliHertz: UInt32,
        debugLinkState: DebugLinkState,
        updateState: DebugUpdateState,
        oldestLogSequence: UInt64,
        newestLogSequence: UInt64,
        lostLogEntryCount: UInt64,
        lastError: DebugStatusError
    ) {
        guard snapshotSequence != 0,
              onlineProcessorCount <= configuredProcessorCount,
              freeMemoryByteCount <= managedMemoryByteCount,
              Self.validDisplay(
                  state: displayState,
                  width: displayWidthPixels,
                  height: displayHeightPixels,
                  refresh: displayRefreshMilliHertz
              ),
              Self.validLogRange(
                  oldest: oldestLogSequence,
                  newest: newestLogSequence
              )
        else { return nil }

        self.snapshotSequence = snapshotSequence
        self.monotonicTicks = monotonicTicks
        self.bootSessionID = bootSessionID
        self.phase = phase
        self.flags = flags
        self.configuredProcessorCount = configuredProcessorCount
        self.onlineProcessorCount = onlineProcessorCount
        self.runnableThreadCount = runnableThreadCount
        self.managedMemoryByteCount = managedMemoryByteCount
        self.freeMemoryByteCount = freeMemoryByteCount
        self.displayState = displayState
        self.displayWidthPixels = displayWidthPixels
        self.displayHeightPixels = displayHeightPixels
        self.displayRefreshMilliHertz = displayRefreshMilliHertz
        self.debugLinkState = debugLinkState
        self.updateState = updateState
        self.oldestLogSequence = oldestLogSequence
        self.newestLogSequence = newestLogSequence
        self.lostLogEntryCount = lostLogEntryCount
        self.lastError = lastError
    }

    var hasRetainedLogs: Bool { oldestLogSequence != 0 }

    private static func validDisplay(
        state: DebugDisplayState,
        width: UInt32,
        height: UInt32,
        refresh: UInt32
    ) -> Bool {
        let hasDimensions = width != 0 && height != 0
        let hasNoDimensions = width == 0 && height == 0
        guard hasDimensions || hasNoDimensions else { return false }
        switch state {
        case .configured, .presenting:
            // A zero refresh rate means the active mode did not report it.
            return hasDimensions
        case .unavailable, .discovering:
            return hasNoDimensions && refresh == 0
        case .failed:
            // Preserve the last known mode when failure follows presentation.
            return hasDimensions || refresh == 0
        }
    }

    private static func validLogRange(oldest: UInt64, newest: UInt64) -> Bool {
        if oldest == 0 || newest == 0 { return oldest == 0 && newest == 0 }
        return oldest <= newest
    }
}
