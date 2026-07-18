@main
struct VirGLCapabilityParserTests {
    static func main() {
        testBoundedDeterministicSelection()
        testSelectorRejectsMalformedObservations()
        testVirGL2CapabilityParsing()
        testLegacyVirGLCapabilityParsing()
        testFutureVirGL2PrefixNegotiation()
        testPayloadShapeAndEndianRejections()
        testShaderPrimitiveAndLimitRejections()
        testFormatRequirementsAndBaselineVertexFormats()
        print("VirGL capability parser host tests: 8 groups passed")
    }

    private static func testBoundedDeterministicSelection() {
        var forward = requireSelector(count: 4)
        expect(
            forward.observe(info(id: 1, version: 1, size: 308)) == .accepted,
            "legacy capset observation"
        )
        expect(
            forward.observe(info(id: 5, version: 0, size: 64)) == .ignored,
            "unrelated capset observation"
        )
        expect(
            forward.observe(info(id: 2, version: 2, size: 1_376)) == .accepted,
            "VIRGL2 capset observation"
        )
        expect(
            forward.observe(info(id: 3, version: 0, size: 128)) == .ignored,
            "second unrelated capset observation"
        )
        expectSelected(forward.finish(), kind: .virgl2, version: 2, size: 1_376)

        var reverse = requireSelector(count: 2)
        _ = reverse.observe(info(id: 2, version: 1, size: 1_376))
        _ = reverse.observe(info(id: 1, version: 0, size: 308))
        expectSelected(reverse.finish(), kind: .virgl2, version: 1, size: 1_376)

        var legacy = requireSelector(count: 1)
        _ = legacy.observe(info(id: 1, version: 0, size: 308))
        expectSelected(legacy.finish(), kind: .virgl, version: 0, size: 308)

        var unavailable = requireSelector(count: 1)
        _ = unavailable.observe(info(id: 4, version: 0, size: 64))
        expect(unavailable.finish() == .unavailable, "unrelated-only selection")

        let empty = requireSelector(count: 0)
        expect(empty.finish() == .unavailable, "empty capset enumeration")

        expect(
            VirGLCapsetSelector(
                advertisedCapsetCount:
                    VirGLCapsetSelector.maximumObservationCount + 1
            ) == nil,
            "unbounded capset advertisement was accepted"
        )
    }

    private static func testSelectorRejectsMalformedObservations() {
        var incomplete = requireSelector(count: 2)
        _ = incomplete.observe(info(id: 1, version: 1, size: 308))
        expect(
            incomplete.finish() == .rejected(.incompleteObservations),
            "incomplete enumeration was accepted"
        )

        var excess = requireSelector(count: 1)
        _ = excess.observe(info(id: 1, version: 1, size: 308))
        expect(
            excess.observe(info(id: 2, version: 2, size: 1_376))
                == .rejected(.tooManyObservations),
            "excess observation was accepted"
        )

        var duplicate = requireSelector(count: 2)
        _ = duplicate.observe(info(id: 2, version: 2, size: 1_376))
        expect(
            duplicate.observe(info(id: 2, version: 2, size: 1_376))
                == .rejected(.duplicateCapset),
            "duplicate capset was accepted"
        )

        var futureVersion = requireSelector(count: 1)
        expect(
            futureVersion.observe(info(id: 2, version: 3, size: 1_380))
                == .accepted,
            "append-only VIRGL2 version was rejected"
        )
        guard case .selected(let future) = futureVersion.finish() else {
            fail("future VIRGL2 selection was unavailable")
        }
        expect(future.advertisedMaximumVersion == 3, "advertised maximum")
        expect(future.requestedVersion == 2, "bounded requested version")
        expect(future.payloadByteCount == 1_380, "appended payload size")

        var futureSize = requireSelector(count: 1)
        expect(
            futureSize.observe(info(id: 2, version: 2, size: 4_100))
                == .rejected(.unknownLayout),
            "unbounded VIRGL2 layout size was accepted"
        )
    }

    private static func testVirGL2CapabilityParsing() {
        let selection = requireSelection(kind: .virgl2, version: 2)
        withValidPayload(for: selection) { bytes in
            writeLE32(0x4000_0001, word: 98, bytes: bytes)
            writeLE32(0x0000_0200, word: 172, bytes: bytes)
            let result = VirGLCapabilityParser.parse(
                capset: selection,
                payload: UnsafeRawBufferPointer(bytes)
            )
            guard case .capabilities(let capabilities) = result else {
                fail("valid VIRGL2 capabilities were rejected")
            }
            expect(capabilities.capset == selection, "capset metadata")
            expect(capabilities.shaderWireLanguage == .tgsiText, "TGSI profile")
            expect(capabilities.glslLevel == 330, "GLSL level")
            expect(capabilities.maximumRenderTargetCount == 4, "render targets")
            expect(capabilities.maximumTexture2DSize == 16_384, "texture limit")
            expect(capabilities.capabilityBits == 0x4000_0001, "capability bits")
            expect(capabilities.capabilityBitsV2 == 0x0000_0200, "v2 bits")
            expect(capabilities.supportsB8G8R8X8RenderTarget, "render format")
            expect(capabilities.supportsB8G8R8X8Scanout, "scanout format")
            expect(
                capabilities.supportsB8G8R8A8SRGBRenderTarget,
                "alpha sRGB render format"
            )
            expect(
                capabilities.supportsB8G8R8A8SRGBScanout,
                "alpha sRGB scanout format"
            )
            expect(
                capabilities.supportsB8G8R8X8SRGBRenderTarget,
                "opaque sRGB render format"
            )
            expect(
                capabilities.supportsB8G8R8X8SRGBScanout,
                "opaque sRGB scanout format"
            )
            expect(
                VirGLCapabilityWire.formatB8G8R8A8SRGB == 100,
                "alpha sRGB wire format"
            )
            expect(
                VirGLCapabilityWire.formatB8G8R8X8SRGB == 101,
                "opaque sRGB wire format"
            )
            expect(capabilities.supportsR32G32FloatVertex, "vec2 vertex format")
            expect(
                capabilities.supportsR32G32B32A32FloatVertex,
                "vec4 vertex format"
            )
            expect(capabilities.hasExplicitTexture2DLimit, "explicit texture limit")
            expect(
                capabilities.supportsTexture2D(width: 3_840, height: 2_160),
                "4K texture rejected"
            )
            expect(
                !capabilities.supportsTexture2D(width: 16_385, height: 1),
                "oversized texture accepted"
            )
        }
    }

    private static func testLegacyVirGLCapabilityParsing() {
        let selection = requireSelection(kind: .virgl, version: 1)
        withValidPayload(for: selection) { bytes in
            let result = VirGLCapabilityParser.parse(
                capset: selection,
                payload: UnsafeRawBufferPointer(bytes)
            )
            guard case .capabilities(let capabilities) = result else {
                fail("valid legacy VIRGL capabilities were rejected")
            }
            expect(capabilities.maximumTexture2DSize == nil, "invented v1 limit")
            expect(capabilities.capabilityBits == 0, "invented v1 capability bits")
            expect(capabilities.capabilityBitsV2 == 0, "invented v1 v2 bits")
            expect(!capabilities.supportsB8G8R8X8Scanout, "invented v1 scanout")
            expect(
                capabilities.supportsB8G8R8A8SRGBRenderTarget,
                "lost advertised v1 alpha sRGB render format"
            )
            expect(
                capabilities.supportsB8G8R8X8SRGBRenderTarget,
                "lost advertised v1 opaque sRGB render format"
            )
            expect(
                !capabilities.supportsB8G8R8A8SRGBScanout,
                "invented v1 alpha sRGB scanout"
            )
            expect(
                !capabilities.supportsB8G8R8X8SRGBScanout,
                "invented v1 opaque sRGB scanout"
            )
            expect(
                !capabilities.supportsTexture2D(width: 1, height: 1),
                "legacy layout claimed an absent texture limit"
            )
        }
    }

    private static func testFutureVirGL2PrefixNegotiation() {
        guard let selection = VirGLCapsetSelection(
                  kind: .virgl2,
                  version: 3,
                  payloadByteCount:
                    VirGLCapabilityWire.virgl2PayloadByteCount + 4
              )
        else {
            fail("could not negotiate an appended VIRGL2 payload")
        }
        expect(selection.advertisedMaximumVersion == 3, "future advertisement")
        expect(selection.requestedVersion == 2, "known requested version")
        withValidPayload(for: selection) { bytes in
            writeLE32(0xfeed_beef, word: 344, bytes: bytes)
            guard case .capabilities(let capabilities) = parse(selection, bytes)
            else {
                fail("known VIRGL2 prefix with bounded tail was rejected")
            }
            expect(
                capabilities.capset.advertisedMaximumVersion == 3,
                "payload maximum version"
            )
            expect(capabilities.capset.requestedVersion == 2, "request clamp")
        }
    }

    private static func testPayloadShapeAndEndianRejections() {
        let selection = requireSelection(kind: .virgl2, version: 2)
        withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity: Int(selection.payloadByteCount) - 1
        ) { storage in
            storage.initialize(repeating: 0)
            expectRejected(
                VirGLCapabilityParser.parse(
                    capset: selection,
                    payload: UnsafeRawBufferPointer(storage)
                ),
                .truncatedPayload,
                "truncated payload"
            )
        }
        withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity: Int(selection.payloadByteCount) + 4
        ) { storage in
            storage.initialize(repeating: 0)
            expectRejected(
                VirGLCapabilityParser.parse(
                    capset: selection,
                    payload: UnsafeRawBufferPointer(storage)
                ),
                .unexpectedPayloadSize,
                "oversized payload"
            )
        }
        withValidPayload(for: selection) { bytes in
            // Big-endian bytes for the value 2 decode to 0x02000000.
            write8(0, offset: 0, bytes: bytes)
            write8(0, offset: 1, bytes: bytes)
            write8(0, offset: 2, bytes: bytes)
            write8(2, offset: 3, bytes: bytes)
            expectRejected(
                VirGLCapabilityParser.parse(
                    capset: selection,
                    payload: UnsafeRawBufferPointer(bytes)
                ),
                .invalidByteOrderOrVersion,
                "big-endian capability payload"
            )
        }
    }

    private static func testShaderPrimitiveAndLimitRejections() {
        let selection = requireSelection(kind: .virgl2, version: 2)
        withValidPayload(for: selection) { bytes in
            writeLE32(119, word: 66, bytes: bytes)
            expectRejected(parse(selection, bytes), .unsupportedShaderProfile, "GLSL 119")
        }
        withValidPayload(for: selection) { bytes in
            writeLE32(0, word: 72, bytes: bytes)
            expectRejected(parse(selection, bytes), .unsupportedPrimitive, "no triangles")
        }
        withValidPayload(for: selection) { bytes in
            writeLE32(0, word: 70, bytes: bytes)
            expectRejected(
                parse(selection, bytes),
                .impossibleRenderTargetLimit,
                "zero render targets"
            )
        }
        withValidPayload(for: selection) { bytes in
            writeLE32(9, word: 70, bytes: bytes)
            expectRejected(
                parse(selection, bytes),
                .impossibleRenderTargetLimit,
                "more than Gallium render targets"
            )
        }
        withValidPayload(for: selection) { bytes in
            writeLE32(0, word: 121, bytes: bytes)
            expectRejected(parse(selection, bytes), .impossibleTextureLimit, "zero texture limit")
        }
        withValidPayload(for: selection) { bytes in
            writeLE32(UInt32.max, word: 121, bytes: bytes)
            expectRejected(
                parse(selection, bytes),
                .impossibleTextureLimit,
                "texture limit outside signed GL range"
            )
        }
    }

    private static func testFormatRequirementsAndBaselineVertexFormats() {
        let selection = requireSelection(kind: .virgl2, version: 2)
        withValidPayload(for: selection) { bytes in
            writeLE32(0, word: 17, bytes: bytes)
            expectRejected(
                parse(selection, bytes),
                .unsupportedRenderTargetFormat,
                "missing B8G8R8X8 render target"
            )
        }
        withValidPayload(for: selection) { bytes in
            // Keep opaque format 101 set to prove it cannot substitute for
            // alpha-preserving format 100 (word 17 + 100 / 32, bit 100 % 32).
            writeLE32(UInt32(1) << 5, word: 20, bytes: bytes)
            expectRejected(
                parse(selection, bytes),
                .unsupportedRenderTargetFormat,
                "missing B8G8R8A8_SRGB render target"
            )
        }
        withValidPayload(for: selection) { bytes in
            writeLE32(0, word: 156, bytes: bytes)
            expectRejected(
                parse(selection, bytes),
                .unsupportedScanoutFormat,
                "missing B8G8R8X8 scanout"
            )
        }
        withValidPayload(for: selection) { bytes in
            // The scanout mask starts at word 156, so formats 100 and 101
            // occupy bits 4 and 5 respectively in word 159.
            writeLE32(UInt32(1) << 5, word: 159, bytes: bytes)
            expectRejected(
                parse(selection, bytes),
                .unsupportedScanoutFormat,
                "missing B8G8R8A8_SRGB scanout"
            )
        }
        withValidPayload(for: selection) { bytes in
            // Opaque sRGB support is reported, but is not mandatory once the
            // alpha-preserving format is available for both uses.
            writeLE32(UInt32(1) << 4, word: 20, bytes: bytes)
            writeLE32(UInt32(1) << 4, word: 159, bytes: bytes)
            guard case .capabilities(let capabilities) = parse(selection, bytes)
            else {
                fail("alpha-only sRGB payload was rejected")
            }
            expect(
                capabilities.supportsB8G8R8A8SRGBRenderTarget,
                "alpha sRGB render bit"
            )
            expect(
                capabilities.supportsB8G8R8A8SRGBScanout,
                "alpha sRGB scanout bit"
            )
            expect(
                !capabilities.supportsB8G8R8X8SRGBRenderTarget,
                "invented opaque sRGB render bit"
            )
            expect(
                !capabilities.supportsB8G8R8X8SRGBScanout,
                "invented opaque sRGB scanout bit"
            )
        }
        withValidPayload(for: selection) { bytes in
            // Real virglrenderer hosts leave the ordinary float formats clear
            // here; this mask advertises exceptional vertex formats only.
            writeLE32(0, word: 49, bytes: bytes)
            guard case .capabilities(let capabilities) = parse(selection, bytes) else {
                fail("real-host-shaped baseline vertex payload was rejected")
            }
            expect(capabilities.supportsR32G32FloatVertex, "baseline vec2")
            expect(capabilities.supportsR32G32B32A32FloatVertex, "baseline vec4")
        }
    }

    private static func withValidPayload(
        for selection: VirGLCapsetSelection,
        _ body: (UnsafeMutableBufferPointer<UInt8>) -> Void
    ) {
        withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity: Int(selection.payloadByteCount)
        ) { bytes in
            bytes.initialize(repeating: 0)
            writeLE32(
                selection.advertisedMaximumVersion,
                word: 0,
                bytes: bytes
            )
            writeLE32(UInt32(1) << 2, word: 17, bytes: bytes)
            writeLE32(
                (UInt32(1) << 4) | (UInt32(1) << 5),
                word: 20,
                bytes: bytes
            )
            writeLE32(330, word: 66, bytes: bytes)
            writeLE32(4, word: 70, bytes: bytes)
            writeLE32(UInt32(1) << 4, word: 72, bytes: bytes)
            if selection.kind == .virgl2 {
                writeLE32(16_384, word: 121, bytes: bytes)
                writeLE32(UInt32(1) << 2, word: 156, bytes: bytes)
                writeLE32(
                    (UInt32(1) << 4) | (UInt32(1) << 5),
                    word: 159,
                    bytes: bytes
                )
            }
            body(bytes)
        }
    }

    private static func parse(
        _ selection: VirGLCapsetSelection,
        _ bytes: UnsafeMutableBufferPointer<UInt8>
    ) -> VirGLCapabilityParseResult {
        VirGLCapabilityParser.parse(
            capset: selection,
            payload: UnsafeRawBufferPointer(bytes)
        )
    }

    private static func writeLE32(
        _ value: UInt32,
        word: Int,
        bytes: UnsafeMutableBufferPointer<UInt8>
    ) {
        let offset = word * 4
        write8(UInt8(truncatingIfNeeded: value), offset: offset, bytes: bytes)
        write8(UInt8(truncatingIfNeeded: value >> 8), offset: offset + 1, bytes: bytes)
        write8(UInt8(truncatingIfNeeded: value >> 16), offset: offset + 2, bytes: bytes)
        write8(UInt8(truncatingIfNeeded: value >> 24), offset: offset + 3, bytes: bytes)
    }

    private static func write8(
        _ value: UInt8,
        offset: Int,
        bytes: UnsafeMutableBufferPointer<UInt8>
    ) {
        guard offset >= 0, offset < bytes.count else {
            fail("test fixture write out of bounds")
        }
        bytes[offset] = value
    }

    private static func requireSelector(count: UInt32) -> VirGLCapsetSelector {
        guard let selector = VirGLCapsetSelector(advertisedCapsetCount: count) else {
            fail("could not construct bounded selector")
        }
        return selector
    }

    private static func requireSelection(
        kind: VirGLCapsetKind,
        version: UInt32
    ) -> VirGLCapsetSelection {
        let size: UInt32 = kind == .virgl
            ? VirGLCapabilityWire.virglPayloadByteCount
            : VirGLCapabilityWire.virgl2PayloadByteCount
        guard let selection = VirGLCapsetSelection(
            kind: kind,
            version: version,
            payloadByteCount: size
        ) else {
            fail("could not construct known capset selection")
        }
        return selection
    }

    private static func info(
        id: UInt32,
        version: UInt32,
        size: UInt32
    ) -> VirtIOGPU3DCapsetInfo {
        VirtIOGPU3DCapsetInfo(
            id: id,
            maximumVersion: version,
            maximumByteCount: size
        )
    }

    private static func expectSelected(
        _ result: VirGLCapsetSelectionResult,
        kind: VirGLCapsetKind,
        version: UInt32,
        size: UInt32
    ) {
        guard case .selected(let selection) = result else {
            fail("expected selected capset")
        }
        expect(selection.kind == kind, "selected capset kind")
        expect(selection.version == version, "selected capset version")
        expect(selection.payloadByteCount == size, "selected capset size")
    }

    private static func expectRejected(
        _ result: VirGLCapabilityParseResult,
        _ expected: VirGLCapabilityParseRejection,
        _ context: StaticString
    ) {
        guard case .rejected(let rejection) = result else {
            fail("expected capability rejection")
        }
        expect(rejection == expected, context)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: StaticString) -> Never {
        print("FAIL:", message)
        fatalError()
    }
}
