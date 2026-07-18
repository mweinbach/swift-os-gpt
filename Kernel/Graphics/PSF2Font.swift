/// A checked, non-owning view over bytes supplied by a boot module, initramfs,
/// or another kernel-owned storage object.
///
/// The caller must keep the underlying storage alive while this value is used.
struct BoundedByteSpan {
    private let address: UInt
    let byteCount: UInt

    init?(baseAddress: UInt, byteCount: UInt) {
        guard byteCount > 0,
              UnsafeRawPointer(bitPattern: baseAddress) != nil
        else {
            return nil
        }

        let (_, overflow) = baseAddress.addingReportingOverflow(byteCount)
        guard !overflow else { return nil }

        address = baseAddress
        self.byteCount = byteCount
    }

    func read8(at offset: UInt) -> UInt8? {
        guard offset < byteCount,
              let pointer = UnsafeRawPointer(bitPattern: address + offset)
        else {
            return nil
        }
        return pointer.load(as: UInt8.self)
    }

    func readLittleEndian32(at offset: UInt) -> UInt32? {
        guard contains(offset: offset, length: 4),
              let byte0 = read8(at: offset),
              let byte1 = read8(at: offset + 1),
              let byte2 = read8(at: offset + 2),
              let byte3 = read8(at: offset + 3)
        else {
            return nil
        }

        return UInt32(byte0)
            | UInt32(byte1) << 8
            | UInt32(byte2) << 16
            | UInt32(byte3) << 24
    }

    func contains(offset: UInt, length: UInt) -> Bool {
        guard offset <= byteCount else { return false }
        return length <= byteCount - offset
    }
}

/// PSF2 can append a UTF-8 sequence table after its glyph bitmaps. Parsing that
/// table is deliberately a later layer; this state prevents callers from
/// mistaking direct glyph-index lookup for complete Unicode support.
enum PSF2UnicodeTableState: Equatable {
    case absent
    case presentButUnparsed(byteOffset: UInt, byteCount: UInt)
}

struct PSF2FontMetrics: Equatable {
    let width: UInt32
    let height: UInt32
    let bytesPerGlyph: UInt32
    let glyphCount: UInt32

    var bytesPerRow: UInt32 {
        width / 8 + (width & 7 == 0 ? 0 : 1)
    }
}

/// A validated, non-owning PSF version 2 bitmap font.
///
/// Until the optional Unicode table is decoded, scalar lookup intentionally
/// uses the scalar value as a glyph index. Out-of-range values select the
/// configured fallback glyph.
struct PSF2Font {
    static let magic: UInt32 = 0x864a_b572
    static let fixedHeaderByteCount: UInt = 32

    let metrics: PSF2FontMetrics
    let unicodeTable: PSF2UnicodeTableState
    let fallbackGlyphIndex: UInt32

    private let bytes: BoundedByteSpan
    private let glyphTableOffset: UInt
    private let rowByteCount: UInt
    private let glyphByteCount: UInt

    init?(
        bytes: BoundedByteSpan,
        fallbackGlyphIndex requestedFallback: UInt32 = 63
    ) {
        guard bytes.byteCount >= Self.fixedHeaderByteCount,
              bytes.readLittleEndian32(at: 0) == Self.magic,
              bytes.readLittleEndian32(at: 4) == 0,
              let headerSize32 = bytes.readLittleEndian32(at: 8),
              let flags = bytes.readLittleEndian32(at: 12),
              let glyphCount = bytes.readLittleEndian32(at: 16),
              let bytesPerGlyph = bytes.readLittleEndian32(at: 20),
              let height = bytes.readLittleEndian32(at: 24),
              let width = bytes.readLittleEndian32(at: 28),
              headerSize32 >= UInt32(Self.fixedHeaderByteCount),
              flags & ~UInt32(1) == 0,
              glyphCount > 0,
              bytesPerGlyph > 0,
              width > 0,
              height > 0
        else {
            return nil
        }

        let headerSize = UInt(headerSize32)
        guard headerSize <= bytes.byteCount else { return nil }

        let widthWithPadding = UInt64(width) + 7
        let rowBytes64 = widthWithPadding / 8
        let (minimumGlyphBytes64, glyphSizeOverflow) =
            rowBytes64.multipliedReportingOverflow(by: UInt64(height))
        guard !glyphSizeOverflow,
              minimumGlyphBytes64 == UInt64(bytesPerGlyph),
              minimumGlyphBytes64 <= UInt64(UInt.max)
        else {
            return nil
        }

        let glyphSize = UInt(bytesPerGlyph)
        let (allGlyphBytes, glyphTableOverflow) =
            UInt(glyphCount).multipliedReportingOverflow(by: glyphSize)
        guard !glyphTableOverflow else { return nil }

        let (glyphTableEnd, tableEndOverflow) =
            headerSize.addingReportingOverflow(allGlyphBytes)
        guard !tableEndOverflow, glyphTableEnd <= bytes.byteCount else {
            return nil
        }

        metrics = PSF2FontMetrics(
            width: width,
            height: height,
            bytesPerGlyph: bytesPerGlyph,
            glyphCount: glyphCount
        )
        if flags & 1 == 0 {
            unicodeTable = .absent
        } else {
            unicodeTable = .presentButUnparsed(
                byteOffset: glyphTableEnd,
                byteCount: bytes.byteCount - glyphTableEnd
            )
        }
        fallbackGlyphIndex = requestedFallback < glyphCount
            ? requestedFallback
            : 0
        self.bytes = bytes
        glyphTableOffset = headerSize
        rowByteCount = UInt(rowBytes64)
        glyphByteCount = glyphSize
    }

    func glyphIndex(for codePoint: UInt32) -> UInt32 {
        codePoint < metrics.glyphCount ? codePoint : fallbackGlyphIndex
    }

    func glyphBitIsSet(
        glyphIndex: UInt32,
        row: UInt32,
        column: UInt32
    ) -> Bool {
        guard glyphIndex < metrics.glyphCount,
              row < metrics.height,
              column < metrics.width
        else {
            return false
        }

        let glyphOffset = UInt(glyphIndex) * glyphByteCount
        let rowOffset = UInt(row) * rowByteCount
        let byteOffset = UInt(column) / 8
        let offset = glyphTableOffset + glyphOffset + rowOffset + byteOffset
        guard let value = bytes.read8(at: offset) else { return false }

        let bit = UInt8(7 - (column & 7))
        return value & (UInt8(1) << bit) != 0
    }
}

struct PSF2GlyphRenderResult {
    let glyphIndex: UInt32
    let damage: Rectangle?
}

/// Renderer-independent bitmap glyph rasterization for an XRGB linear buffer.
/// Scaling is integer-only so the same path is deterministic on every machine.
enum PSF2GlyphRenderer {
    static func draw(
        codePoint: UInt32,
        from font: PSF2Font,
        at origin: Point,
        color: PixelColor,
        scale: Int,
        into framebuffer: LinearFramebuffer
    ) -> PSF2GlyphRenderResult {
        let glyphIndex = font.glyphIndex(for: codePoint)
        guard scale > 0, framebuffer.width > 0, framebuffer.height > 0 else {
            return PSF2GlyphRenderResult(glyphIndex: glyphIndex, damage: nil)
        }

        var damageStartX = framebuffer.width
        var damageStartY = framebuffer.height
        var damageEndX = 0
        var damageEndY = 0
        var hasDamage = false

        var row: UInt32 = 0
        while row < font.metrics.height {
            var column: UInt32 = 0
            while column < font.metrics.width {
                if font.glyphBitIsSet(
                    glyphIndex: glyphIndex,
                    row: row,
                    column: column
                ),
                   let horizontal = clippedScaledCell(
                    origin: origin.x,
                    unitOffset: UInt(column),
                    scale: scale,
                    limit: framebuffer.width
                   ),
                   let vertical = clippedScaledCell(
                    origin: origin.y,
                    unitOffset: UInt(row),
                    scale: scale,
                    limit: framebuffer.height
                   ) {
                    framebuffer.fill(
                        Rectangle(
                            x: horizontal.start,
                            y: vertical.start,
                            width: horizontal.length,
                            height: vertical.length
                        ),
                        color: color
                    )

                    if horizontal.start < damageStartX {
                        damageStartX = horizontal.start
                    }
                    if vertical.start < damageStartY {
                        damageStartY = vertical.start
                    }
                    let horizontalEnd = horizontal.start + horizontal.length
                    let verticalEnd = vertical.start + vertical.length
                    if horizontalEnd > damageEndX { damageEndX = horizontalEnd }
                    if verticalEnd > damageEndY { damageEndY = verticalEnd }
                    hasDamage = true
                }
                column += 1
            }
            row += 1
        }

        let damage: Rectangle?
        if hasDamage {
            damage = Rectangle(
                x: damageStartX,
                y: damageStartY,
                width: damageEndX - damageStartX,
                height: damageEndY - damageStartY
            )
        } else {
            damage = nil
        }
        return PSF2GlyphRenderResult(glyphIndex: glyphIndex, damage: damage)
    }

    private static func clippedScaledCell(
        origin: Int,
        unitOffset: UInt,
        scale: Int,
        limit: Int
    ) -> (start: Int, length: Int)? {
        guard unitOffset <= UInt(Int.max) else { return nil }
        let (offset, multiplyOverflow) =
            Int(unitOffset).multipliedReportingOverflow(by: scale)
        guard !multiplyOverflow else { return nil }

        let (cellStart, startOverflow) = origin.addingReportingOverflow(offset)
        guard !startOverflow, cellStart < limit else { return nil }

        let (cellEnd, endOverflow) = cellStart.addingReportingOverflow(scale)
        guard !endOverflow, cellEnd > 0 else { return nil }

        let clippedStart = cellStart < 0 ? 0 : cellStart
        let clippedEnd = cellEnd > limit ? limit : cellEnd
        guard clippedStart < clippedEnd else { return nil }
        return (clippedStart, clippedEnd - clippedStart)
    }
}
