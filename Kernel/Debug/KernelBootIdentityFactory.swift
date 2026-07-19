/// Allocation-free digest state for immutable kernel image bytes. This is an
/// identity primitive, not a cryptographic authenticator: updates remain
/// protected by their separate SHA-256 contract.
struct KernelArtifactIdentityDigest {
    private static let firstOffset: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let secondOffset: UInt64 = 0x8422_2325_cbf2_9ce4
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    private var first = Self.firstOffset
    private var second = Self.secondOffset
    private var byteCount: UInt64 = 0

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 0 || bytes.baseAddress != nil else { return }
        var index = 0
        while index < bytes.count {
            let byte = UInt64(bytes[index])
            first = (first ^ byte) &* Self.fnvPrime
            // Reverse both the byte position and seed evolution so the two
            // halves do not collapse to the same digest for short inputs.
            second = (second ^ (byte | UInt64(index & 0xff) << 8))
                &* Self.fnvPrime
            second = Self.rotateLeft(second, by: 17)
            index += 1
        }
        byteCount &+= UInt64(bytes.count)
        first ^= Self.mix(UInt64(bytes.count))
        second ^= Self.mix(byteCount)
    }

    var identity: KernelIdentity128 {
        let high = Self.mix(first ^ byteCount)
        let low = Self.mix(second ^ Self.rotateLeft(byteCount, by: 29))
        return KernelIdentity128(
            high: high,
            low: high == 0 && low == 0 ? 1 : low
        )!
    }

    private static func rotateLeft(_ value: UInt64, by count: UInt64) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }

    fileprivate static func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9e37_79b9_7f4a_7c15
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

/// Pure construction policy shared by host tests and the freestanding runtime.
/// Build identity is reproducible from immutable image bytes. Boot identity
/// adds the live architectural counter and machine inputs; it is suitable for
/// rejecting stale debug frames but deliberately makes no security claim.
enum KernelBootIdentityFactory {
    static let debugABIRevision: UInt16 = 1

    static func buildIdentity(
        digest: KernelIdentity128,
        flavor: KernelBuildFlavor = .development
    ) -> KernelBuildIdentity {
        KernelBuildIdentity(
            buildID: digest,
            // Source metadata is optional on bare-metal builds. The digest is
            // the canonical artifact identity when no revision was injected.
            sourceRevision: 0,
            imageDigestPrefix: digest.low,
            flavor: flavor,
            abiRevision: debugABIRevision
        )
    }

    static func bootIdentity(
        build: KernelBuildIdentity,
        startedAtTicks: UInt64,
        counterFrequency: UInt64,
        deviceTreeAddress: UInt64,
        processorAffinity: UInt64,
        stackPointer: UInt64,
        machineDiscriminator: UInt64,
        reason: KernelBootReason = .unknown
    ) -> KernelBootIdentity {
        let high = KernelArtifactIdentityDigest.mix(
            build.buildID.high
                ^ startedAtTicks
                ^ rotateLeft(deviceTreeAddress, by: 23)
                ^ machineDiscriminator
        )
        var low = KernelArtifactIdentityDigest.mix(
            build.buildID.low
                ^ counterFrequency
                ^ rotateLeft(processorAffinity, by: 11)
                ^ rotateLeft(stackPointer, by: 37)
                ^ rotateLeft(startedAtTicks, by: 7)
        )
        if high == 0 && low == 0 { low = 1 }
        return KernelBootIdentity(
            sessionID: KernelIdentity128(high: high, low: low)!,
            build: build,
            bootOrdinal: 0,
            startedAtTicks: startedAtTicks,
            reason: reason
        )
    }

    private static func rotateLeft(_ value: UInt64, by count: UInt64) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }
}

#if os(none)
enum KernelBootIdentityRuntime {
    static func create(
        deviceTreeAddress: UInt64,
        machineDiscriminator: UInt64
    ) -> KernelBootIdentity? {
        var digest = KernelArtifactIdentityDigest()
        guard append(KernelLinkerLayout.kernelText, to: &digest),
              append(KernelLinkerLayout.userText, to: &digest),
              append(KernelLinkerLayout.kernelReadOnlyData, to: &digest),
              append(KernelLinkerLayout.userReadOnlyData, to: &digest)
        else { return nil }

        let build = KernelBootIdentityFactory.buildIdentity(
            digest: digest.identity,
            flavor: .development
        )
        let startedAtTicks = AArch64.counterValue
        return KernelBootIdentityFactory.bootIdentity(
            build: build,
            startedAtTicks: startedAtTicks,
            counterFrequency: AArch64.counterFrequency,
            deviceTreeAddress: deviceTreeAddress,
            processorAffinity: UInt64(AArch64.redistributorAffinity),
            stackPointer: AArch64.stackPointer,
            machineDiscriminator: machineDiscriminator
        )
    }

    private static func append(
        _ region: LinkerRegion,
        to digest: inout KernelArtifactIdentityDigest
    ) -> Bool {
        guard region.length <= UInt64(Int.max),
              region.start <= UInt64(UInt.max),
              region.length == 0
                || UnsafeRawPointer(bitPattern: UInt(region.start)) != nil
        else { return false }
        digest.update(
            UnsafeRawBufferPointer(
                start: UnsafeRawPointer(bitPattern: UInt(region.start)),
                count: Int(region.length)
            )
        )
        return true
    }
}
#endif
