/// Backend-neutral storage format for a one-channel glyph coverage atlas.
enum GPUMaskAtlasFormat: UInt8, Equatable {
    case r8UNorm
}

/// An integer texel rectangle inside the mask atlas.
struct GPUMaskAtlasPixelRegion: Equatable {
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32

    var endX: UInt32 { x + width }
    var endY: UInt32 { y + height }
}

/// Complete deterministic placement for one requested Unicode scalar.
///
/// `cellPixelRegion` includes the transparent one-pixel gutter. The narrower
/// `maskPixelRegion` and `maskTextureRegion` address only the future 5x7 glyph
/// artwork, while the gutter remains available to texture filtering.
struct GPUMaskFontGlyph: Equatable {
    let requestedScalar: UInt32
    let atlasScalar: UInt32
    let atlasIndex: Int
    let column: Int
    let row: Int
    let cellPixelRegion: GPUMaskAtlasPixelRegion
    let maskPixelRegion: GPUMaskAtlasPixelRegion
    let cellTextureRegion: GPUTextureRegion
    let maskTextureRegion: GPUTextureRegion

    /// True when an unsupported scalar was redirected to the replacement cell.
    var usedReplacementFallback: Bool {
        requestedScalar != atlasScalar
    }

    /// The final atlas cell is reserved for replacement-glyph artwork.
    var isReplacementGlyph: Bool {
        atlasScalar == GPUMaskFontAtlasLayout.replacementScalar
    }
}

/// Immutable format and byte-layout contract for the mask texture.
struct GPUMaskFontAtlasDescriptor: Equatable {
    let extent: GPUPixelExtent
    let format: GPUMaskAtlasFormat
    let bytesPerTexel: Int
    let bytesPerRow: Int
    let requiredByteCount: Int
}

/// One row-aligned copy from future staging storage into the R8 atlas.
struct GPUMaskFontAtlasUpload: Equatable {
    let sourceByteOffset: Int
    let sourceBytesPerRow: Int
    let destination: GPUMaskAtlasPixelRegion
    let byteCount: Int

    var sourceEndByteOffset: Int {
        sourceByteOffset + byteCount
    }
}

/// Fixed, allocation-free upload schedule. The two descriptors deliberately
/// contain no source pointer and no font artwork; a resource manager can fill
/// one 6,048-byte staging allocation and translate each strip for any backend.
struct GPUMaskFontAtlasUploadPlan {
    static let uploadCount = 2
    static let maximumUploadByteCount = 3_072

    let descriptor = GPUMaskFontAtlasLayout.descriptor

    func upload(at index: Int) -> GPUMaskFontAtlasUpload? {
        guard index >= 0, index < Self.uploadCount else {
            return nil
        }

        let destinationY = UInt32(index * GPUMaskFontAtlasLayout.uploadHeight)
        let byteOffset = index * GPUMaskFontAtlasLayout.uploadByteCount
        return GPUMaskFontAtlasUpload(
            sourceByteOffset: byteOffset,
            sourceBytesPerRow: descriptor.bytesPerRow,
            destination: GPUMaskAtlasPixelRegion(
                x: 0,
                y: destinationY,
                width: GPUMaskFontAtlasLayout.atlasWidth,
                height: UInt32(GPUMaskFontAtlasLayout.uploadHeight)
            ),
            byteCount: GPUMaskFontAtlasLayout.uploadByteCount
        )
    }
}

enum GPUMaskFontAtlasWriteResult: Equatable {
    case written(byteCount: Int)
    case invalidUploadIndex
    case insufficientCapacity(requiredByteCount: Int, availableByteCount: Int)
}

/// Builds immutable R8 coverage data for one upload strip.
///
/// This is asset preparation, not framebuffer rendering: the CPU writes each
/// 5x7 mask once, then every visible glyph is positioned, sampled, tinted,
/// blended, and presented by a GPU backend. Keeping the writer strip-oriented
/// lets a freestanding resource manager reuse one bounded DMA page.
enum GPUMaskFontAtlasWriter {
    static func writeUpload(
        at index: Int,
        into storage: UnsafeMutableRawBufferPointer
    ) -> GPUMaskFontAtlasWriteResult {
        guard let upload = GPUMaskFontAtlasLayout.uploadPlan.upload(at: index)
        else {
            return .invalidUploadIndex
        }
        guard storage.count >= upload.byteCount else {
            return .insufficientCapacity(
                requiredByteCount: upload.byteCount,
                availableByteCount: storage.count
            )
        }

        var byteIndex = 0
        while byteIndex < upload.byteCount {
            storage[byteIndex] = 0
            byteIndex += 1
        }

        var glyphIndex = 0
        while glyphIndex < GPUMaskFontAtlasLayout.glyphCount {
            guard let glyph = GPUMaskFontAtlasLayout.glyph(at: glyphIndex) else {
                return .invalidUploadIndex
            }
            let packedRows = BitmapFont.glyph(
                for: UInt8(truncatingIfNeeded: glyph.atlasScalar)
            )

            var row = 0
            while row < Int(GPUMaskFontAtlasLayout.maskHeight) {
                let atlasY = glyph.maskPixelRegion.y + UInt32(row)
                if atlasY >= upload.destination.y
                    && atlasY < upload.destination.endY {
                    let sourceY = Int(atlasY - upload.destination.y)
                    let sourceRowOffset = sourceY * upload.sourceBytesPerRow
                    let rowBits = UInt8(
                        truncatingIfNeeded: packedRows >> UInt64(row * 5)
                    )

                    var column = 0
                    while column < Int(GPUMaskFontAtlasLayout.maskWidth) {
                        let bit = UInt8(1) << UInt8(4 - column)
                        if rowBits & bit != 0 {
                            let destinationIndex = sourceRowOffset
                                + Int(glyph.maskPixelRegion.x)
                                + column
                            storage[destinationIndex] = UInt8.max
                        }
                        column += 1
                    }
                }
                row += 1
            }
            glyphIndex += 1
        }
        return .written(byteCount: upload.byteCount)
    }
}

/// Layout-only foundation for a compact boot/UI mask font.
///
/// Atlas scalar 32 is the space cell, scalars 33...126 are printable ASCII,
/// and scalar 127 names a dedicated replacement cell. Unsupported Unicode
/// scalars resolve to that final cell without requiring a lookup allocation.
enum GPUMaskFontAtlasLayout {
    static let firstAtlasScalar: UInt32 = 32
    static let replacementScalar: UInt32 = 127
    static let atlasScalarLimit: UInt32 = 128
    static let glyphCount = 96

    static let columnCount = 16
    static let rowCount = 6
    static let cellWidth: UInt32 = 7
    static let cellHeight: UInt32 = 9
    static let gutter: UInt32 = 1
    static let maskWidth: UInt32 = 5
    static let maskHeight: UInt32 = 7

    static let atlasWidth: UInt32 = 112
    static let atlasHeight: UInt32 = 54
    static let uploadHeight = 27
    static let uploadByteCount = 3_024

    static let descriptor = GPUMaskFontAtlasDescriptor(
        extent: GPUPixelExtent(width: atlasWidth, height: atlasHeight)!,
        format: .r8UNorm,
        bytesPerTexel: 1,
        bytesPerRow: Int(atlasWidth),
        requiredByteCount: Int(atlasWidth * atlasHeight)
    )

    static let uploadPlan = GPUMaskFontAtlasUploadPlan()

    /// Returns the placement for a scalar, using the dedicated final cell for
    /// values outside the atlas's printable-ASCII contract.
    static func glyph(for scalar: UInt32) -> GPUMaskFontGlyph {
        let resolvedScalar: UInt32
        if scalar >= firstAtlasScalar && scalar < replacementScalar {
            resolvedScalar = scalar
        } else {
            resolvedScalar = replacementScalar
        }
        return makeGlyph(
            requestedScalar: scalar,
            atlasScalar: resolvedScalar
        )
    }

    /// Deterministic indexed access for atlas generation. Index 95 is the
    /// replacement cell; invalid indices return nil.
    static func glyph(at index: Int) -> GPUMaskFontGlyph? {
        guard index >= 0, index < glyphCount else {
            return nil
        }
        let scalar = firstAtlasScalar + UInt32(index)
        return makeGlyph(requestedScalar: scalar, atlasScalar: scalar)
    }

    private static func makeGlyph(
        requestedScalar: UInt32,
        atlasScalar: UInt32
    ) -> GPUMaskFontGlyph {
        let index = Int(atlasScalar - firstAtlasScalar)
        let column = index % columnCount
        let row = index / columnCount
        let cellX = UInt32(column) * cellWidth
        let cellY = UInt32(row) * cellHeight
        let cell = GPUMaskAtlasPixelRegion(
            x: cellX,
            y: cellY,
            width: cellWidth,
            height: cellHeight
        )
        let mask = GPUMaskAtlasPixelRegion(
            x: cellX + gutter,
            y: cellY + gutter,
            width: maskWidth,
            height: maskHeight
        )

        return GPUMaskFontGlyph(
            requestedScalar: requestedScalar,
            atlasScalar: atlasScalar,
            atlasIndex: index,
            column: column,
            row: row,
            cellPixelRegion: cell,
            maskPixelRegion: mask,
            cellTextureRegion: textureRegion(for: cell),
            maskTextureRegion: textureRegion(for: mask)
        )
    }

    private static func textureRegion(
        for pixels: GPUMaskAtlasPixelRegion
    ) -> GPUTextureRegion {
        GPUTextureRegion(
            minimumU: normalized(pixels.x, dimension: atlasWidth),
            minimumV: normalized(pixels.y, dimension: atlasHeight),
            maximumU: normalized(pixels.endX, dimension: atlasWidth),
            maximumV: normalized(pixels.endY, dimension: atlasHeight)
        )!
    }

    /// Q16 truncation is intentional and deterministic. Shared cell boundaries
    /// are derived from the same integer texel coordinate, so adjacent regions
    /// remain exactly adjacent even when one sixth cannot be represented.
    private static func normalized(
        _ coordinate: UInt32,
        dimension: UInt32
    ) -> UInt32 {
        let numerator = UInt64(coordinate)
            * UInt64(GPUTextureRegion.unitRawValue)
        return UInt32(numerator / UInt64(dimension))
    }
}
