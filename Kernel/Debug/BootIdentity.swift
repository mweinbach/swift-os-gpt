/// Fixed-width 128-bit identity used for builds and boot sessions. This avoids
/// heap-backed text or platform UUID facilities in the freestanding kernel.
struct KernelIdentity128: Equatable {
    let high: UInt64
    let low: UInt64

    init?(high: UInt64, low: UInt64) {
        guard high != 0 || low != 0 else { return nil }
        self.high = high
        self.low = low
    }
}

enum KernelBuildFlavor: UInt8, Equatable {
    case development = 1
    case release = 2
    case diagnostic = 3
}

/// Reproducible identity of a kernel artifact. Build tooling supplies these
/// integers; the kernel does not parse strings or depend on a host ABI.
struct KernelBuildIdentity: Equatable {
    static let schemaVersion: UInt16 = 1

    let buildID: KernelIdentity128
    /// Truncated source-control revision or another reproducible source ID.
    let sourceRevision: UInt64
    /// Prefix of the final artifact digest, independent of transport format.
    let imageDigestPrefix: UInt64
    let flavor: KernelBuildFlavor
    let abiRevision: UInt16

    init(
        buildID: KernelIdentity128,
        sourceRevision: UInt64,
        imageDigestPrefix: UInt64,
        flavor: KernelBuildFlavor,
        abiRevision: UInt16
    ) {
        self.buildID = buildID
        self.sourceRevision = sourceRevision
        self.imageDigestPrefix = imageDigestPrefix
        self.flavor = flavor
        self.abiRevision = abiRevision
    }
}

enum KernelBootReason: UInt8, Equatable {
    case cold = 1
    case warmReset = 2
    case softwareUpdate = 3
    case recovery = 4
    case unknown = 255
}

/// Unique identity for one execution of one build. `bootOrdinal` may be zero
/// when the platform has no persistent boot counter; sessionID still separates
/// live diagnostic streams.
struct KernelBootIdentity: Equatable {
    static let schemaVersion: UInt16 = 1

    let sessionID: KernelIdentity128
    let build: KernelBuildIdentity
    let bootOrdinal: UInt64
    let startedAtTicks: UInt64
    let reason: KernelBootReason

    init(
        sessionID: KernelIdentity128,
        build: KernelBuildIdentity,
        bootOrdinal: UInt64,
        startedAtTicks: UInt64,
        reason: KernelBootReason
    ) {
        // A zero start tick is valid when the counter is sampled at reset.
        self.sessionID = sessionID
        self.build = build
        self.bootOrdinal = bootOrdinal
        self.startedAtTicks = startedAtTicks
        self.reason = reason
    }
}
