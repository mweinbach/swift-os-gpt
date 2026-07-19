@main
struct KernelUpdateActivationTests {
    static func main() {
        validatesStagingGeometry()
        validatesPiImageHeader()
        rejectsMalformedPiImages()
        print("kernel update activation: 3 groups passed")
    }

    private static func validatesStagingGeometry() {
        expect(
            KernelUpdateStagingLayout(
                baseAddress: 0x03ff_f000,
                byteCount: KernelUpdateStagingLimits.allocationByteCount
            ) == nil,
            "low staging allocation accepted"
        )
        guard let layout = KernelUpdateStagingLayout(
                  baseAddress: 0x0400_0000,
                  byteCount: KernelUpdateStagingLimits.allocationByteCount
              )
        else {
            fail("valid staging allocation rejected")
        }
        expect(
            layout.image.endAddress == layout.deviceTree.baseAddress,
            "image and DTB regions are not adjacent"
        )
        expect(
            layout.deviceTree.endAddress == layout.trampoline.baseAddress,
            "DTB and trampoline regions are not adjacent"
        )
        expect(
            layout.activationStackTopAddress & 0xf == 0,
            "activation stack is not 16-byte aligned"
        )
        expect(
            layout.activationStack.endAddress <= layout.allocation.endAddress,
            "staging subregions exceed allocation"
        )
    }

    private static func validatesPiImageHeader() {
        let image = makeImage(rawByteCount: 4_096, runtimeByteCount: 0x20_0000)
        image.withUnsafeBytes { bytes in
            expect(
                RaspberryPiKernelImageValidator.validate(bytes)
                    == .accepted(
                        RaspberryPiKernelImageMetadata(
                            rawImageByteCount: 4_096,
                            runtimeImageByteCount: 0x20_0000,
                            entryOffset: 64
                        )
                    ),
                "valid Pi image rejected"
            )
        }
    }

    private static func rejectsMalformedPiImages() {
        let short = [UInt8](repeating: 0, count: 63)
        short.withUnsafeBytes { bytes in
            expect(
                RaspberryPiKernelImageValidator.validate(bytes)
                    == .rejected(.tooShort),
                "short image accepted"
            )
        }

        var image = makeImage(rawByteCount: 4_096, runtimeByteCount: 0x20_0000)
        image[56] = 0
        image.withUnsafeBytes { bytes in
            expect(
                RaspberryPiKernelImageValidator.validate(bytes)
                    == .rejected(.invalidMagic),
                "bad magic accepted"
            )
        }

        image = makeImage(rawByteCount: 4_096, runtimeByteCount: 0x20_0000)
        write64(0x1_0000, to: &image, at: 8)
        image.withUnsafeBytes { bytes in
            expect(
                RaspberryPiKernelImageValidator.validate(bytes)
                    == .rejected(.invalidTextOffset),
                "wrong load offset accepted"
            )
        }

        image = makeImage(rawByteCount: 4_096, runtimeByteCount: 4_095)
        image.withUnsafeBytes { bytes in
            expect(
                RaspberryPiKernelImageValidator.validate(bytes)
                    == .rejected(.invalidRuntimeSize),
                "undersized runtime span accepted"
            )
        }

        image = makeImage(rawByteCount: 4_096, runtimeByteCount: 0x20_0000)
        write32(0x1400_0000, to: &image, at: 0)
        image.withUnsafeBytes { bytes in
            expect(
                RaspberryPiKernelImageValidator.validate(bytes)
                    == .rejected(.invalidEntryOffset),
                "header self-branch accepted"
            )
        }

        image = makeImage(rawByteCount: 4_096, runtimeByteCount: 0x20_0000)
        write64(1, to: &image, at: 40)
        image.withUnsafeBytes { bytes in
            expect(
                RaspberryPiKernelImageValidator.validate(bytes)
                    == .rejected(.invalidReservedField),
                "nonzero reserved field accepted"
            )
        }
    }

    private static func makeImage(
        rawByteCount: Int,
        runtimeByteCount: UInt64
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: rawByteCount)
        // B +64 bytes: imm26 = 16.
        write32(0x1400_0010, to: &bytes, at: 0)
        write64(
            KernelUpdateStagingLimits.canonicalPiImageAddress,
            to: &bytes,
            at: 8
        )
        write64(runtimeByteCount, to: &bytes, at: 16)
        write64(0x2, to: &bytes, at: 24)
        write32(0x644d_5241, to: &bytes, at: 56)
        return bytes
    }

    private static func write32(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        var index = 0
        while index < 4 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt32(index * 8)
            )
            index += 1
        }
    }

    private static func write64(
        _ value: UInt64,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        var index = 0
        while index < 8 {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> UInt64(index * 8)
            )
            index += 1
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("FAIL: \(message)")
    }
}
