@main
struct KernelBootIdentityFactoryTests {
    private static var failures = 0

    static func main() {
        testDigestIsDeterministicAndSensitiveToOrder()
        testBootInputsSeparateSessions()
        testUnknownSourceMetadataIsExplicit()

        if failures == 0 {
            print("Kernel boot identity factory tests passed")
        } else {
            print("Kernel boot identity factory tests failed: \(failures)")
            fatalError("test failure")
        }
    }

    private static func testDigestIsDeterministicAndSensitiveToOrder() {
        let first = digest([1, 2, 3, 4], [5, 6])
        let repeatDigest = digest([1, 2, 3, 4], [5, 6])
        let reordered = digest([5, 6], [1, 2, 3, 4])
        expect(first == repeatDigest, "artifact digest is deterministic")
        expect(first != reordered, "artifact digest retains region order")
        expect(first.high != 0 || first.low != 0, "artifact digest is nonzero")
    }

    private static func testBootInputsSeparateSessions() {
        let artifact = digest([0x53, 0x57, 0x49, 0x46, 0x54], [])
        let build = KernelBootIdentityFactory.buildIdentity(digest: artifact)
        let first = KernelBootIdentityFactory.bootIdentity(
            build: build,
            startedAtTicks: 100,
            counterFrequency: 54_000_000,
            deviceTreeAddress: 0x1000,
            processorAffinity: 0,
            stackPointer: 0x8000,
            machineDiscriminator: 5
        )
        let next = KernelBootIdentityFactory.bootIdentity(
            build: build,
            startedAtTicks: 101,
            counterFrequency: 54_000_000,
            deviceTreeAddress: 0x1000,
            processorAffinity: 0,
            stackPointer: 0x8000,
            machineDiscriminator: 5
        )
        expect(first.sessionID != next.sessionID, "counter separates boots")
        expect(first.build == next.build, "build identity stays reproducible")
        expect(first.bootOrdinal == 0, "missing persistent ordinal stays zero")
        expect(first.reason == .unknown, "unknown reset reason is honest")
    }

    private static func testUnknownSourceMetadataIsExplicit() {
        let artifact = digest([], [])
        let build = KernelBootIdentityFactory.buildIdentity(
            digest: artifact,
            flavor: .diagnostic
        )
        expect(build.sourceRevision == 0, "source revision is explicitly unknown")
        expect(build.imageDigestPrefix == artifact.low, "digest prefix is populated")
        expect(build.abiRevision == 1, "debug ABI revision is explicit")
        expect(build.flavor == .diagnostic, "build flavor is preserved")
    }

    private static func digest(_ first: [UInt8], _ second: [UInt8])
        -> KernelIdentity128 {
        var digest = KernelArtifactIdentityDigest()
        first.withUnsafeBytes { digest.update($0) }
        second.withUnsafeBytes { digest.update($0) }
        return digest.identity
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}
