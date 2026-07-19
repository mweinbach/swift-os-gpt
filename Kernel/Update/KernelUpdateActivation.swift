enum KernelUpdateStagingLimits {
    static let canonicalPiImageAddress: UInt64 = 0x0008_0000
    static let minimumStagingAddress: UInt64 = 0x0400_0000
    static let maximumRawImageByteCount: UInt64 = 16 * 1_024 * 1_024
    static let maximumRuntimeImageByteCount: UInt64 = 32 * 1_024 * 1_024
    static let maximumDeviceTreeByteCount: UInt64 = 2 * 1_024 * 1_024
    static let trampolineByteCount: UInt64 = 4_096
    static let activationStackByteCount: UInt64 = 64 * 1_024
    static let allocationByteCount: UInt64 = 20 * 1_024 * 1_024
}

struct KernelUpdateDestinationWindow: Equatable {
    let baseAddress: UInt64
    let byteCount: UInt64

    init?(baseAddress: UInt64, byteCount: UInt64) {
        guard MemoryPageGeometry.isPageAligned(baseAddress),
              MemoryPageGeometry.isPageAligned(byteCount),
              byteCount > 0,
              byteCount <= UInt64.max - baseAddress
        else { return nil }
        self.baseAddress = baseAddress
        self.byteCount = byteCount
    }

    var endAddress: UInt64 { baseAddress + byteCount }
}

/// Board-specific image placement remains outside the transport and receiver.
/// Future machines can provide another contract without duplicating SUPD.
enum RaspberryPiKernelUpdateContract {
    static var destinationWindow: KernelUpdateDestinationWindow {
        KernelUpdateDestinationWindow(
            baseAddress: KernelUpdateStagingLimits.canonicalPiImageAddress,
            byteCount: KernelUpdateStagingLimits.maximumRuntimeImageByteCount
        )!
    }
}

struct KernelUpdateBufferRegion: Equatable {
    let baseAddress: UInt64
    let byteCount: UInt64

    var endAddress: UInt64 { baseAddress + byteCount }
}

/// One high-memory allocation owns every byte needed after the live kernel is
/// quiesced. Fixed subregions make overlap proofs independent of allocator or
/// board policy while the allocation itself can come from any compatible RAM
/// domain.
struct KernelUpdateStagingLayout: Equatable {
    let allocation: KernelUpdateBufferRegion
    let image: KernelUpdateBufferRegion
    let deviceTree: KernelUpdateBufferRegion
    let trampoline: KernelUpdateBufferRegion
    let activationStack: KernelUpdateBufferRegion

    init?(baseAddress: UInt64, byteCount: UInt64) {
        let limits = KernelUpdateStagingLimits.self
        guard MemoryPageGeometry.isPageAligned(baseAddress),
              MemoryPageGeometry.isPageAligned(byteCount),
              baseAddress >= limits.minimumStagingAddress,
              byteCount >= limits.allocationByteCount,
              byteCount <= UInt64.max - baseAddress,
              limits.canonicalPiImageAddress
                + limits.maximumRuntimeImageByteCount <= baseAddress
        else {
            return nil
        }

        let deviceTreeBase = baseAddress
            + limits.maximumRawImageByteCount
        let trampolineBase = deviceTreeBase
            + limits.maximumDeviceTreeByteCount
        let stackBase = trampolineBase + limits.trampolineByteCount
        let requiredEnd = stackBase + limits.activationStackByteCount
        guard requiredEnd <= baseAddress + byteCount else { return nil }

        allocation = KernelUpdateBufferRegion(
            baseAddress: baseAddress,
            byteCount: byteCount
        )
        image = KernelUpdateBufferRegion(
            baseAddress: baseAddress,
            byteCount: limits.maximumRawImageByteCount
        )
        deviceTree = KernelUpdateBufferRegion(
            baseAddress: deviceTreeBase,
            byteCount: limits.maximumDeviceTreeByteCount
        )
        trampoline = KernelUpdateBufferRegion(
            baseAddress: trampolineBase,
            byteCount: limits.trampolineByteCount
        )
        activationStack = KernelUpdateBufferRegion(
            baseAddress: stackBase,
            byteCount: limits.activationStackByteCount
        )
    }

    var activationStackTopAddress: UInt64 {
        activationStack.endAddress
    }
}

struct RaspberryPiKernelImageMetadata: Equatable {
    let rawImageByteCount: UInt64
    let runtimeImageByteCount: UInt64
    let entryOffset: UInt64
}

enum RaspberryPiKernelImageRejection: Equatable {
    case tooShort
    case tooLarge
    case invalidMagic
    case invalidEntryInstruction
    case invalidEntryOffset
    case invalidTextOffset
    case invalidRuntimeSize
    case invalidFlags
    case invalidReservedField
}

enum RaspberryPiKernelImageValidationResult: Equatable {
    case accepted(RaspberryPiKernelImageMetadata)
    case rejected(RaspberryPiKernelImageRejection)
}

/// Strict validator for the public 64-byte arm64 Image header used by the Pi
/// package. Cryptographic transfer verification happens before this structural
/// gate; both must pass before activation is permitted.
enum RaspberryPiKernelImageValidator {
    static let headerByteCount = 64
    private static let branchImmediateOpcode: UInt32 = 0x1400_0000
    private static let branchImmediateMask: UInt32 = 0xfc00_0000
    private static let arm64Magic: UInt32 = 0x644d_5241
    private static let requiredFlags: UInt64 = 0x2

    static func validate(
        _ bytes: UnsafeRawBufferPointer
    ) -> RaspberryPiKernelImageValidationResult {
        guard bytes.count >= headerByteCount else {
            return .rejected(.tooShort)
        }
        guard UInt64(bytes.count)
                <= KernelUpdateStagingLimits.maximumRawImageByteCount
        else {
            return .rejected(.tooLarge)
        }
        guard read32(bytes, at: 56) == arm64Magic else {
            return .rejected(.invalidMagic)
        }
        guard let instruction = read32(bytes, at: 0),
              instruction & branchImmediateMask == branchImmediateOpcode
        else {
            return .rejected(.invalidEntryInstruction)
        }

        let rawImmediate = Int64(instruction & 0x03ff_ffff)
        let signedImmediate = rawImmediate & (1 << 25) == 0
            ? rawImmediate
            : rawImmediate - (1 << 26)
        let signedEntryOffset = signedImmediate * 4
        guard signedEntryOffset >= Int64(headerByteCount),
              UInt64(signedEntryOffset) < UInt64(bytes.count)
        else {
            return .rejected(.invalidEntryOffset)
        }
        guard read64(bytes, at: 8)
                == KernelUpdateStagingLimits.canonicalPiImageAddress
        else {
            return .rejected(.invalidTextOffset)
        }
        guard let runtimeByteCount = read64(bytes, at: 16),
              runtimeByteCount >= UInt64(bytes.count),
              runtimeByteCount
                <= KernelUpdateStagingLimits.maximumRuntimeImageByteCount,
              MemoryPageGeometry.isPageAligned(runtimeByteCount)
        else {
            return .rejected(.invalidRuntimeSize)
        }
        guard read64(bytes, at: 24) == requiredFlags else {
            return .rejected(.invalidFlags)
        }
        guard read64(bytes, at: 32) == 0,
              read64(bytes, at: 40) == 0,
              read64(bytes, at: 48) == 0,
              read32(bytes, at: 60) == 0
        else {
            return .rejected(.invalidReservedField)
        }
        return .accepted(
            RaspberryPiKernelImageMetadata(
                rawImageByteCount: UInt64(bytes.count),
                runtimeImageByteCount: runtimeByteCount,
                entryOffset: UInt64(signedEntryOffset)
            )
        )
    }

    private static func read32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func read64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64? {
        guard offset >= 0, offset <= bytes.count - 8 else { return nil }
        var value: UInt64 = 0
        var index = 0
        while index < 8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
            index += 1
        }
        return value
    }
}
