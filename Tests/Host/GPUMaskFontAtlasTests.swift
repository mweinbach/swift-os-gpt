@main
struct GPUMaskFontAtlasTests {
    static func main() {
        validatesAtlasDescriptor()
        mapsPrintableASCIIToGridCells()
        preservesOnePixelGutters()
        producesDeterministicQ16Regions()
        usesDedicatedReplacementCell()
        plansTwoBoundedUploadStrips()
        coversAtlasBytesAndRowsExactlyOnce()
        rejectsInvalidIndexedAccess()
        print("GPU mask font atlas host tests: 8 groups passed")
    }

    private static func validatesAtlasDescriptor() {
        let descriptor = GPUMaskFontAtlasLayout.descriptor
        expect(descriptor.extent.width == 112, "atlas width")
        expect(descriptor.extent.height == 54, "atlas height")
        expect(descriptor.format == .r8UNorm, "atlas format")
        expect(descriptor.bytesPerTexel == 1, "R8 texel size")
        expect(descriptor.bytesPerRow == 112, "atlas row stride")
        expect(descriptor.requiredByteCount == 6_048, "atlas byte count")
        expect(GPUMaskFontAtlasLayout.glyphCount == 96, "glyph count")
        expect(GPUMaskFontAtlasLayout.columnCount == 16, "column count")
        expect(GPUMaskFontAtlasLayout.rowCount == 6, "row count")
    }

    private static func mapsPrintableASCIIToGridCells() {
        let space = GPUMaskFontAtlasLayout.glyph(for: 32)
        expect(space.atlasIndex == 0, "space index")
        expect(space.column == 0 && space.row == 0, "space cell")

        let capitalA = GPUMaskFontAtlasLayout.glyph(for: 65)
        expect(capitalA.atlasIndex == 33, "A index")
        expect(capitalA.column == 1 && capitalA.row == 2, "A cell")

        let tilde = GPUMaskFontAtlasLayout.glyph(for: 126)
        expect(tilde.atlasIndex == 94, "tilde index")
        expect(tilde.column == 14 && tilde.row == 5, "tilde cell")
        expect(!tilde.isReplacementGlyph, "tilde replaced")
    }

    private static func preservesOnePixelGutters() {
        let first = GPUMaskFontAtlasLayout.glyph(for: 32)
        expectPixelRegion(
            first.cellPixelRegion,
            x: 0,
            y: 0,
            width: 7,
            height: 9,
            "first cell"
        )
        expectPixelRegion(
            first.maskPixelRegion,
            x: 1,
            y: 1,
            width: 5,
            height: 7,
            "first mask"
        )

        let capitalA = GPUMaskFontAtlasLayout.glyph(for: 65)
        expectPixelRegion(
            capitalA.cellPixelRegion,
            x: 7,
            y: 18,
            width: 7,
            height: 9,
            "A cell pixels"
        )
        expectPixelRegion(
            capitalA.maskPixelRegion,
            x: 8,
            y: 19,
            width: 5,
            height: 7,
            "A mask pixels"
        )

        let replacement = requireGlyph(at: 95)
        expectPixelRegion(
            replacement.cellPixelRegion,
            x: 105,
            y: 45,
            width: 7,
            height: 9,
            "replacement cell pixels"
        )
        expectPixelRegion(
            replacement.maskPixelRegion,
            x: 106,
            y: 46,
            width: 5,
            height: 7,
            "replacement mask pixels"
        )
    }

    private static func producesDeterministicQ16Regions() {
        let first = GPUMaskFontAtlasLayout.glyph(for: 32)
        expect(first.cellTextureRegion.minimumU == 0, "first cell minimum U")
        expect(first.cellTextureRegion.minimumV == 0, "first cell minimum V")
        expect(first.cellTextureRegion.maximumU == 4_096, "first cell maximum U")
        expect(first.cellTextureRegion.maximumV == 10_922, "first cell maximum V")
        expect(first.maskTextureRegion.minimumU == 585, "first mask minimum U")
        expect(first.maskTextureRegion.minimumV == 1_213, "first mask minimum V")
        expect(first.maskTextureRegion.maximumU == 3_510, "first mask maximum U")
        expect(first.maskTextureRegion.maximumV == 9_709, "first mask maximum V")

        let rowOne = requireGlyph(at: 16)
        expect(
            first.cellTextureRegion.maximumV
                == rowOne.cellTextureRegion.minimumV,
            "adjacent rows have mismatched Q16 boundary"
        )

        let last = requireGlyph(at: 95)
        expect(last.cellTextureRegion.minimumU == 61_440, "last cell minimum U")
        expect(last.cellTextureRegion.maximumU == 65_536, "last cell maximum U")
        expect(last.cellTextureRegion.minimumV == 54_613, "last cell minimum V")
        expect(last.cellTextureRegion.maximumV == 65_536, "last cell maximum V")

        let repeated = GPUMaskFontAtlasLayout.glyph(for: 65)
        expect(
            repeated.maskTextureRegion
                == GPUMaskFontAtlasLayout.glyph(for: 65).maskTextureRegion,
            "repeated lookup changed UV region"
        )
    }

    private static func usesDedicatedReplacementCell() {
        let direct = GPUMaskFontAtlasLayout.glyph(for: 127)
        expect(direct.atlasIndex == 95, "direct replacement index")
        expect(direct.isReplacementGlyph, "direct replacement identity")
        expect(!direct.usedReplacementFallback, "direct replacement marked fallback")

        let belowRange = GPUMaskFontAtlasLayout.glyph(for: 31)
        let aboveRange = GPUMaskFontAtlasLayout.glyph(for: 128)
        let unicodeReplacement = GPUMaskFontAtlasLayout.glyph(for: 0xfffd)
        expect(belowRange.atlasIndex == 95, "low scalar fallback")
        expect(aboveRange.atlasIndex == 95, "high scalar fallback")
        expect(unicodeReplacement.atlasIndex == 95, "Unicode fallback")
        expect(belowRange.usedReplacementFallback, "low fallback flag")
        expect(aboveRange.usedReplacementFallback, "high fallback flag")
        expect(
            unicodeReplacement.cellPixelRegion == direct.cellPixelRegion,
            "fallback placement differs"
        )
    }

    private static func plansTwoBoundedUploadStrips() {
        let plan = GPUMaskFontAtlasLayout.uploadPlan
        expect(
            GPUMaskFontAtlasUploadPlan.uploadCount == 2,
            "upload count"
        )
        let first = requireUpload(plan, at: 0)
        let second = requireUpload(plan, at: 1)
        expect(first.sourceByteOffset == 0, "first source offset")
        expect(second.sourceByteOffset == 3_024, "second source offset")
        expect(first.sourceBytesPerRow == 112, "first source row stride")
        expect(second.sourceBytesPerRow == 112, "second source row stride")
        expect(first.byteCount == 3_024, "first upload bytes")
        expect(second.byteCount == 3_024, "second upload bytes")
        expect(
            first.byteCount <= GPUMaskFontAtlasUploadPlan.maximumUploadByteCount,
            "first upload exceeds limit"
        )
        expect(
            second.byteCount <= GPUMaskFontAtlasUploadPlan.maximumUploadByteCount,
            "second upload exceeds limit"
        )
        expectPixelRegion(
            first.destination,
            x: 0,
            y: 0,
            width: 112,
            height: 27,
            "first destination strip"
        )
        expectPixelRegion(
            second.destination,
            x: 0,
            y: 27,
            width: 112,
            height: 27,
            "second destination strip"
        )
    }

    private static func coversAtlasBytesAndRowsExactlyOnce() {
        let plan = GPUMaskFontAtlasLayout.uploadPlan
        let first = requireUpload(plan, at: 0)
        let second = requireUpload(plan, at: 1)
        expect(
            first.sourceEndByteOffset == second.sourceByteOffset,
            "source strips overlap or have a gap"
        )
        expect(
            second.sourceEndByteOffset == plan.descriptor.requiredByteCount,
            "source plan does not cover atlas"
        )
        expect(
            first.destination.endY == second.destination.y,
            "destination rows overlap or have a gap"
        )
        expect(
            second.destination.endY == plan.descriptor.extent.height,
            "destination plan does not cover atlas"
        )
        expect(
            first.destination.width == plan.descriptor.extent.width
                && second.destination.width == plan.descriptor.extent.width,
            "upload does not cover complete rows"
        )
    }

    private static func rejectsInvalidIndexedAccess() {
        expect(GPUMaskFontAtlasLayout.glyph(at: -1) == nil, "negative glyph index")
        expect(GPUMaskFontAtlasLayout.glyph(at: 96) == nil, "past-end glyph index")
        expect(
            GPUMaskFontAtlasLayout.uploadPlan.upload(at: -1) == nil,
            "negative upload index"
        )
        expect(
            GPUMaskFontAtlasLayout.uploadPlan.upload(at: 2) == nil,
            "past-end upload index"
        )

        var index = 0
        while index < GPUMaskFontAtlasLayout.glyphCount {
            let glyph = requireGlyph(at: index)
            expect(glyph.atlasIndex == index, "indexed glyph identity")
            expect(glyph.column == index % 16, "indexed glyph column")
            expect(glyph.row == index / 16, "indexed glyph row")
            expect(glyph.cellPixelRegion.endX <= 112, "cell exceeds atlas width")
            expect(glyph.cellPixelRegion.endY <= 54, "cell exceeds atlas height")
            index += 1
        }
    }

    private static func requireGlyph(at index: Int) -> GPUMaskFontGlyph {
        guard let glyph = GPUMaskFontAtlasLayout.glyph(at: index) else {
            fatalError("valid glyph index rejected")
        }
        return glyph
    }

    private static func requireUpload(
        _ plan: GPUMaskFontAtlasUploadPlan,
        at index: Int
    ) -> GPUMaskFontAtlasUpload {
        guard let upload = plan.upload(at: index) else {
            fatalError("valid upload index rejected")
        }
        return upload
    }

    private static func expectPixelRegion(
        _ region: GPUMaskAtlasPixelRegion,
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32,
        _ message: String
    ) {
        expect(
            region.x == x && region.y == y
                && region.width == width && region.height == height,
            message
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fatalError(message)
        }
    }
}
