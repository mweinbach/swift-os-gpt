@main
struct BootIdentityTests {
    static func main() {
        validatesFixedIdentities()
        validatesBuildIdentity()
        preservesBootIdentity()
        print("boot identity host tests: 3 groups passed")
    }

    private static func validatesFixedIdentities() {
        expect(KernelIdentity128(high: 0, low: 0) == nil, "zero identity")
        expect(
            KernelIdentity128(high: 0x1020, low: 0x3040)
                == KernelIdentity128(high: 0x1020, low: 0x3040),
            "identity equality"
        )
    }

    private static func validatesBuildIdentity() {
        let id = KernelIdentity128(high: 1, low: 2)!
        let build = KernelBuildIdentity(
            buildID: id,
            sourceRevision: 0,
            imageDigestPrefix: 0,
            flavor: .development,
            abiRevision: 0
        )
        expect(build.buildID == id, "build ID")
        expect(build.sourceRevision == 0, "unknown source revision")
        expect(build.imageDigestPrefix == 0, "unknown image digest")
        expect(build.abiRevision == 0, "initial ABI")
    }

    private static func preservesBootIdentity() {
        let build = validBuild()
        let session = KernelIdentity128(high: 0xaabb, low: 0xccdd)!
        let boot = KernelBootIdentity(
            sessionID: session,
            build: build,
            bootOrdinal: 0,
            startedAtTicks: 0,
            reason: .unknown
        )
        expect(boot.sessionID == session, "session identity")
        expect(boot.build == build, "build identity")
        expect(boot.bootOrdinal == 0, "unknown boot ordinal")
        expect(boot.startedAtTicks == 0, "reset start tick")
        expect(boot.reason == .unknown, "boot reason")
        expect(KernelBuildIdentity.schemaVersion == 1, "build schema")
        expect(KernelBootIdentity.schemaVersion == 1, "boot schema")
    }

    private static func validBuild() -> KernelBuildIdentity {
        KernelBuildIdentity(
            buildID: KernelIdentity128(high: 1, low: 2)!,
            sourceRevision: 3,
            imageDigestPrefix: 4,
            flavor: .diagnostic,
            abiRevision: 1
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fatalError("FAIL: \(message)") }
    }
}
