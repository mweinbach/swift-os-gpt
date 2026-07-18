@main
struct PSF2FontTests {
    static func main() {
        testValidHeaderAndGlyphLookup()
        testUnicodeTableState()
        testMalformedInputs()
        testScaledClippedRendering()
        testFallbackRenderingAndInvalidScale()
        print("PSF2 font host tests: 5 groups passed")
    }

    private static func testValidHeaderAndGlyphLookup() {
        var bytes = makeFont()
        withFont(&bytes, fallbackGlyphIndex: 2) { font in
            expect(font.metrics.width == 3, "glyph width")
            expect(font.metrics.height == 2, "glyph height")
            expect(font.metrics.bytesPerGlyph == 2, "glyph byte count")
            expect(font.metrics.glyphCount == 3, "glyph count")
            expect(font.metrics.bytesPerRow == 1, "glyph row byte count")
            expect(font.unicodeTable == .absent, "unexpected Unicode table")
            expect(font.glyphIndex(for: 1) == 1, "direct glyph lookup")
            expect(font.glyphIndex(for: 0x10_ffff) == 2, "fallback lookup")
            expect(
                font.glyphBitIsSet(glyphIndex: 1, row: 0, column: 0),
                "first glyph bit"
            )
            expect(
                !font.glyphBitIsSet(glyphIndex: 1, row: 0, column: 1),
                "unset glyph bit"
            )
            expect(
                !font.glyphBitIsSet(glyphIndex: 9, row: 0, column: 0),
                "out-of-range glyph read"
            )
        }
    }

    private static func testUnicodeTableState() {
        var bytes = makeFont(flags: 1, trailingBytes: [0x41, 0xff, 0x42])
        withFont(&bytes) { font in
            expect(
                font.unicodeTable == .presentButUnparsed(
                    byteOffset: 38,
                    byteCount: 3
                ),
                "Unicode table bounds"
            )
        }
    }

    private static func testMalformedInputs() {
        expect(
            BoundedByteSpan(baseAddress: 1, byteCount: 0) == nil,
            "empty byte span accepted"
        )
        expect(
            BoundedByteSpan(baseAddress: UInt.max, byteCount: 2) == nil,
            "overflowing byte span accepted"
        )

        var truncated = [UInt8](repeating: 0, count: 31)
        expect(parse(&truncated) == false, "truncated header accepted")

        var badMagic = makeFont()
        badMagic[0] = 0
        expect(parse(&badMagic) == false, "bad magic accepted")

        var badVersion = makeFont()
        writeLE32(1, at: 4, into: &badVersion)
        expect(parse(&badVersion) == false, "unsupported version accepted")

        var shortHeader = makeFont()
        writeLE32(24, at: 8, into: &shortHeader)
        expect(parse(&shortHeader) == false, "short header accepted")

        var oversizedHeader = makeFont()
        writeLE32(UInt32.max, at: 8, into: &oversizedHeader)
        expect(parse(&oversizedHeader) == false, "oversized header accepted")

        var unknownFlags = makeFont()
        writeLE32(2, at: 12, into: &unknownFlags)
        expect(parse(&unknownFlags) == false, "unknown flags accepted")

        var zeroGlyphs = makeFont()
        writeLE32(0, at: 16, into: &zeroGlyphs)
        expect(parse(&zeroGlyphs) == false, "empty glyph table accepted")

        var wrongGlyphSize = makeFont()
        writeLE32(1, at: 20, into: &wrongGlyphSize)
        expect(parse(&wrongGlyphSize) == false, "short glyph accepted")

        var zeroHeight = makeFont()
        writeLE32(0, at: 24, into: &zeroHeight)
        expect(parse(&zeroHeight) == false, "zero height accepted")

        var zeroWidth = makeFont()
        writeLE32(0, at: 28, into: &zeroWidth)
        expect(parse(&zeroWidth) == false, "zero width accepted")

        var overflowingTable = makeFont()
        writeLE32(UInt32.max, at: 16, into: &overflowingTable)
        writeLE32(UInt32.max, at: 20, into: &overflowingTable)
        writeLE32(UInt32.max, at: 24, into: &overflowingTable)
        writeLE32(UInt32.max, at: 28, into: &overflowingTable)
        expect(parse(&overflowingTable) == false, "overflowing table accepted")

        var truncatedGlyphs = makeFont()
        truncatedGlyphs.removeLast()
        expect(parse(&truncatedGlyphs) == false, "truncated glyph table accepted")

        var valid = makeFont()
        withFont(&valid, fallbackGlyphIndex: UInt32.max) { font in
            expect(font.fallbackGlyphIndex == 0, "invalid fallback not bounded")
        }
    }

    private static func testScaledClippedRendering() {
        var fontBytes = makeFont()
        fontBytes[34] = 0b1010_0000
        fontBytes[35] = 0b0100_0000

        var pixels = [UInt32](repeating: 0xdead_beef, count: 8 * 5)
        pixels.withUnsafeMutableBufferPointer { pixelBuffer in
            fontBytes.withUnsafeBytes { rawBytes in
                guard let byteAddress = rawBytes.baseAddress,
                      let span = BoundedByteSpan(
                        baseAddress: UInt(bitPattern: byteAddress),
                        byteCount: UInt(rawBytes.count)
                      ),
                      let font = PSF2Font(bytes: span, fallbackGlyphIndex: 2),
                      let pixelAddress = pixelBuffer.baseAddress
                else {
                    fail("render fixtures")
                }

                let framebuffer = LinearFramebuffer(
                    baseAddress: UInt(bitPattern: pixelAddress),
                    width: 6,
                    height: 5,
                    strideInPixels: 8
                )
                let result = PSF2GlyphRenderer.draw(
                    codePoint: 1,
                    from: font,
                    at: Point(x: -1, y: 1),
                    color: PixelColor(xrgb: 0x0012_3456),
                    scale: 2,
                    into: framebuffer
                )

                expect(result.glyphIndex == 1, "rendered glyph index")
                expect(result.damage?.x == 0, "damage x")
                expect(result.damage?.y == 1, "damage y")
                expect(result.damage?.width == 5, "damage width")
                expect(result.damage?.height == 4, "damage height")
            }
        }

        let ink: UInt32 = 0x0012_3456
        expect(pixels[1 * 8 + 0] == ink, "left-clipped scaled pixel")
        expect(pixels[2 * 8 + 0] == ink, "left-clipped scaled pixel row")
        expect(pixels[1 * 8 + 3] == ink, "right glyph cell")
        expect(pixels[2 * 8 + 4] == ink, "right glyph cell extent")
        expect(pixels[3 * 8 + 1] == ink, "second glyph row")
        expect(pixels[4 * 8 + 2] == ink, "second glyph row extent")
        expect(pixels[0] == 0xdead_beef, "uncovered row modified")
        expect(pixels[1 * 8 + 1] == 0xdead_beef, "unset glyph cell modified")
        expect(pixels[1 * 8 + 6] == 0xdead_beef, "stride padding modified")
        expect(pixels[4 * 8 + 7] == 0xdead_beef, "last stride padding modified")
    }

    private static func testFallbackRenderingAndInvalidScale() {
        var fontBytes = makeFont()
        fontBytes[36] = 0b1110_0000
        fontBytes[37] = 0b1110_0000
        var pixels = [UInt32](repeating: 0, count: 4 * 3)

        pixels.withUnsafeMutableBufferPointer { pixelBuffer in
            fontBytes.withUnsafeBytes { rawBytes in
                guard let byteAddress = rawBytes.baseAddress,
                      let span = BoundedByteSpan(
                        baseAddress: UInt(bitPattern: byteAddress),
                        byteCount: UInt(rawBytes.count)
                      ),
                      let font = PSF2Font(bytes: span, fallbackGlyphIndex: 2),
                      let pixelAddress = pixelBuffer.baseAddress
                else {
                    fail("fallback fixtures")
                }

                let framebuffer = LinearFramebuffer(
                    baseAddress: UInt(bitPattern: pixelAddress),
                    width: 4,
                    height: 3,
                    strideInPixels: 4
                )
                let result = PSF2GlyphRenderer.draw(
                    codePoint: 0x10_ffff,
                    from: font,
                    at: Point(x: 0, y: 0),
                    color: .white,
                    scale: 1,
                    into: framebuffer
                )
                expect(result.glyphIndex == 2, "fallback render index")
                expect(result.damage?.width == 3, "fallback damage width")

                let ignored = PSF2GlyphRenderer.draw(
                    codePoint: 1,
                    from: font,
                    at: Point(x: 0, y: 0),
                    color: .red,
                    scale: 0,
                    into: framebuffer
                )
                expect(ignored.damage == nil, "zero scale rendered")
            }
        }

        expect(pixels[0] == PixelColor.white.xrgb, "fallback glyph not drawn")
        expect(pixels[2] == PixelColor.white.xrgb, "fallback glyph extent")
        expect(pixels[3] == 0, "fallback overdraw")
    }

    private static func makeFont(
        flags: UInt32 = 0,
        trailingBytes: [UInt8] = []
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32 + 3 * 2)
        writeLE32(PSF2Font.magic, at: 0, into: &bytes)
        writeLE32(0, at: 4, into: &bytes)
        writeLE32(32, at: 8, into: &bytes)
        writeLE32(flags, at: 12, into: &bytes)
        writeLE32(3, at: 16, into: &bytes)
        writeLE32(2, at: 20, into: &bytes)
        writeLE32(2, at: 24, into: &bytes)
        writeLE32(3, at: 28, into: &bytes)
        bytes[34] = 0b1010_0000
        bytes[35] = 0b0100_0000
        bytes.append(contentsOf: trailingBytes)
        return bytes
    }

    private static func writeLE32(
        _ value: UInt32,
        at offset: Int,
        into bytes: inout [UInt8]
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func parse(_ bytes: inout [UInt8]) -> Bool {
        bytes.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress,
                  let span = BoundedByteSpan(
                    baseAddress: UInt(bitPattern: baseAddress),
                    byteCount: UInt(rawBytes.count)
                  )
            else {
                return false
            }
            return PSF2Font(bytes: span) != nil
        }
    }

    private static func withFont(
        _ bytes: inout [UInt8],
        fallbackGlyphIndex: UInt32 = 63,
        _ body: (PSF2Font) -> Void
    ) {
        bytes.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress,
                  let span = BoundedByteSpan(
                    baseAddress: UInt(bitPattern: baseAddress),
                    byteCount: UInt(rawBytes.count)
                  ),
                  let font = PSF2Font(
                    bytes: span,
                    fallbackGlyphIndex: fallbackGlyphIndex
                  )
            else {
                fail("valid font rejected")
            }
            body(font)
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: StaticString
    ) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: StaticString) -> Never {
        fatalError("PSF2 font assertion failed: \(message)")
    }
}
