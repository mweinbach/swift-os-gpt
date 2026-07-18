@main
struct GPUCommandIRTests {
    static func main() {
        validatesFixedGeometryAndIdentifiers()
        preservesColorAndTransformPrecision()
        validatesTextureRegionsAndScissors()
        describesClearAndLoadRenderPasses()
        describesSolidAndRoundedQuadInstances()
        describesGlyphAtlasInstances()
        enforcesRenderCommandOrderingAndScissors()
        sealsInlineCommandBuffersWithoutAliasing()
        enforcesCommandCapacityAndSealState()
        ordersAndCoalescesFenceWaits()
        validatesSubmissionMetadata()
        preservesSubmissionFIFOAndFenceOrder()
        print("GPU command IR host tests: 12 groups passed")
    }

    private static func validatesFixedGeometryAndIdentifiers() {
        expect(fixed(3).rawValue == 196_608, "whole fixed encoding")
        expect(fixed(-2).rawValue == -131_072, "negative fixed encoding")
        expect(GPUFixed16(whole: -32_768) != nil, "minimum whole rejected")
        expect(GPUFixed16(whole: 32_768) == nil, "overflowing whole accepted")
        expect(GPUFixed16(rawValue: -1) < .zero, "fixed comparison")

        expect(
            GPUFixedRectangle(
                x: .zero,
                y: .zero,
                width: .zero,
                height: .one
            ) == nil,
            "zero-width rectangle accepted"
        )
        expect(
            GPUFixedRectangle(
                x: GPUFixed16(rawValue: Int32.max - 4),
                y: .zero,
                width: GPUFixed16(rawValue: 5),
                height: .one
            ) == nil,
            "overflowing fixed rectangle accepted"
        )
        let valid = rectangle(x: -4, y: 5, width: 20, height: 10)
        expect(valid.x == fixed(-4), "rectangle x precision")
        expect(valid.width == fixed(20), "rectangle width precision")

        expect(GPUPixelExtent(width: 0, height: 1) == nil, "empty extent")
        expect(GPUPixelExtent(width: 1, height: 0) == nil, "empty extent y")
        expect(GPURenderTargetID(rawValue: 0) == nil, "zero target ID")
        expect(GPUTextureID(rawValue: 0) == nil, "zero texture ID")
        expect(GPUCommandBufferID(rawValue: 0) == nil, "zero command ID")
        expect(GPUQueueID(rawValue: 0) == nil, "zero queue ID")
        expect(target(7).rawValue == 7, "target identity")
        expect(texture(8).rawValue == 8, "texture identity")
    }

    private static func preservesColorAndTransformPrecision() {
        expect(
            GPUPremultipliedColor(red: 2, green: 0, blue: 0, alpha: 1)
                == nil,
            "non-premultiplied color accepted"
        )
        let color = requireColor(red: 100, green: 200, blue: 300, alpha: 400)
        expect(color.red == 100, "color red")
        expect(color.green == 200, "color green")
        expect(color.blue == 300, "color blue")
        expect(color.alpha == 400, "color alpha")
        expect(.transparent == requireColor(red: 0, green: 0, blue: 0, alpha: 0), "transparent color")
        expect(
            GPUPremultipliedColor.opaqueWhite.alpha == UInt16.max,
            "opaque color alpha"
        )

        expect(GPUTransform2D.identity.m11 == .one, "identity m11")
        expect(GPUTransform2D.identity.m22 == .one, "identity m22")
        expect(GPUTransform2D.identity.m12 == .zero, "identity m12")
        let translation = GPUTransform2D.translation(
            x: GPUFixed16(rawValue: 98_304),
            y: GPUFixed16(rawValue: -32_768)
        )
        expect(translation.translationX.rawValue == 98_304, "subpixel x")
        expect(translation.translationY.rawValue == -32_768, "subpixel y")
        expect(translation.m11 == .one && translation.m22 == .one, "translation basis")
    }

    private static func validatesTextureRegionsAndScissors() {
        expect(
            GPUTextureRegion(
                minimumU: 0,
                minimumV: 0,
                maximumU: 0,
                maximumV: 1
            ) == nil,
            "empty texture region accepted"
        )
        expect(
            GPUTextureRegion(
                minimumU: 0,
                minimumV: 0,
                maximumU: GPUTextureRegion.unitRawValue + 1,
                maximumV: 1
            ) == nil,
            "out-of-range texture coordinate accepted"
        )
        let region = requireTextureRegion(
            minimumU: 4_096,
            minimumV: 8_192,
            maximumU: 12_288,
            maximumV: 16_384
        )
        expect(region.minimumU == 4_096, "texture minimum u")
        expect(region.maximumV == 16_384, "texture maximum v")
        expect(GPUTextureRegion.complete.maximumU == 65_536, "full texture u")

        expect(
            GPUScissorRectangle(x: 0, y: 0, width: 0, height: 1) == nil,
            "empty scissor accepted"
        )
        expect(
            GPUScissorRectangle(
                x: UInt32.max,
                y: 0,
                width: 1,
                height: 1
            ) == nil,
            "overflowing scissor accepted"
        )
        let clip = scissor(x: 5, y: 6, width: 7, height: 8)
        expect(clip.endX == 12 && clip.endY == 14, "scissor endpoints")
    }

    private static func describesClearAndLoadRenderPasses() {
        let clearColor = requireColor(
            red: 0x0800,
            green: 0x1000,
            blue: 0x1800,
            alpha: .max
        )
        let clearPass = renderPass(
            targetID: 1,
            width: 1_920,
            height: 1_080,
            format: .bgra8UNormSRGB,
            loadAction: .clear(clearColor),
            storeAction: .store
        )
        expect(clearPass.target == target(1), "clear target")
        expect(clearPass.extent.width == 1_920, "clear width")
        expect(clearPass.format == .bgra8UNormSRGB, "clear format")
        if case .clear(let encoded) = clearPass.loadAction {
            expect(encoded == clearColor, "clear color")
        } else {
            fatalError("clear pass lost clear action")
        }

        let loadPass = renderPass(
            targetID: 2,
            width: 800,
            height: 600,
            format: .rgba16Float,
            loadAction: .load,
            storeAction: .discard
        )
        expect(loadPass.loadAction == .load, "load action")
        expect(loadPass.storeAction == .discard, "discard action")
    }

    private static func describesSolidAndRoundedQuadInstances() {
        let bounds = rectangle(x: 10, y: 20, width: 200, height: 80)
        let solid = requireQuad(bounds: bounds, radii: .zero)
        expect(!solid.isRounded, "solid quad reported rounded")
        expect(solid.blendMode == .sourceOver, "quad blend default")

        let radii = requireRadii(20)
        let rounded = requireQuad(
            bounds: bounds,
            color: .opaqueWhite,
            radii: radii,
            blendMode: .copy
        )
        expect(rounded.isRounded, "rounded quad reported solid")
        expect(rounded.cornerRadii.topLeft == fixed(20), "rounded radius")
        expect(rounded.blendMode == .copy, "quad copy blend")

        expect(GPUCornerRadii.uniform(GPUFixed16(rawValue: -1)) == nil, "negative radius")
        let tooLarge = requireRadii(41)
        expect(
            GPUQuadInstance(
                bounds: bounds,
                color: .opaqueWhite,
                cornerRadii: tooLarge
            ) == nil,
            "oversized radius accepted"
        )
    }

    private static func describesGlyphAtlasInstances() {
        let glyph = GPUGlyphAtlasInstance(
            atlas: texture(42),
            bounds: rectangle(x: 100, y: 50, width: 18, height: 24),
            textureRegion: requireTextureRegion(
                minimumU: 1_000,
                minimumV: 2_000,
                maximumU: 3_000,
                maximumV: 4_000
            ),
            color: .opaqueWhite,
            coverage: .signedDistance,
            filter: .linear,
            blendMode: .sourceOver
        )
        expect(glyph.atlas == texture(42), "glyph atlas identity")
        expect(glyph.coverage == .signedDistance, "glyph coverage")
        expect(glyph.filter == .linear, "glyph filter")
        expect(glyph.textureRegion.maximumV == 4_000, "glyph atlas UV")
        expect(glyph.bounds.height == fixed(24), "glyph bounds")
    }

    private static func enforcesRenderCommandOrderingAndScissors() {
        var recorder = requireRecorder(id: 11, capacity: 10)
        expectRejected(
            recorder.record(.setTransform(.identity)),
            .renderPassNotActive,
            "transform outside pass"
        )
        expectRejected(
            recorder.record(.drawQuad(requireQuad())),
            .renderPassNotActive,
            "quad outside pass"
        )
        expectRejected(
            recorder.record(.endRenderPass),
            .renderPassNotActive,
            "end outside pass"
        )
        expect(recorder.commandCount == 0, "rejections changed command count")

        let pass = renderPass(
            targetID: 3,
            width: 640,
            height: 480,
            loadAction: .clear(.opaqueBlack)
        )
        expectRecorded(recorder.record(.beginRenderPass(pass)), index: 0)
        expectRejected(
            recorder.record(.beginRenderPass(pass)),
            .renderPassAlreadyActive,
            "nested pass"
        )
        expectRejected(
            recorder.record(
                .setScissor(
                    .rectangle(scissor(x: 630, y: 10, width: 11, height: 20))
                )
            ),
            .scissorOutsideRenderTarget,
            "outside scissor"
        )
        expect(recorder.commandCount == 1, "bad scissor changed stream")
        expectRecorded(
            recorder.record(
                .setScissor(
                    .rectangle(scissor(x: 0, y: 0, width: 640, height: 480))
                )
            ),
            index: 1
        )
        let transform = GPUTransform2D.translation(x: fixed(2), y: fixed(3))
        expectRecorded(recorder.record(.setTransform(transform)), index: 2)
        expectRecorded(recorder.record(.drawQuad(requireQuad())), index: 3)
        expectRecorded(recorder.record(.drawGlyph(requireGlyph())), index: 4)
        expectRecorded(recorder.record(.setScissor(.disabled)), index: 5)
        expectRecorded(recorder.record(.endRenderPass), index: 6)
        expect(recorder.completedRenderPassCount == 1, "completed pass count")

        let buffer = requireSealed(recorder.seal())
        expect(buffer.commandCount == 7, "sealed command count")
        expect(buffer.renderPassCount == 1, "sealed pass count")
        expect(buffer.id == commandBufferID(11), "sealed buffer ID")
        expect(buffer.command(at: -1) == nil, "negative command index")
        expect(buffer.command(at: 7) == nil, "past-end command index")
        expect(buffer.command(at: 0) == .beginRenderPass(pass), "begin order")
        expect(buffer.command(at: 2) == .setTransform(transform), "transform order")
        expect(buffer.command(at: 6) == .endRenderPass, "end order")
    }

    private static func sealsInlineCommandBuffersWithoutAliasing() {
        var original = requireRecorder(id: 21, capacity: 8)
        let pass = renderPass(targetID: 1, width: 100, height: 100)
        _ = original.record(.beginRenderPass(pass))

        var copy = original
        _ = copy.record(.drawQuad(requireQuad()))
        _ = copy.record(.endRenderPass)
        let copiedBuffer = requireSealed(copy.seal())

        _ = original.record(.endRenderPass)
        let originalBuffer = requireSealed(original.seal())
        expect(copiedBuffer.commandCount == 3, "copied stream command count")
        expect(originalBuffer.commandCount == 2, "original stream aliased")
        expect(copiedBuffer.command(at: 1) == .drawQuad(requireQuad()), "copy draw")
        expect(originalBuffer.command(at: 1) == .endRenderPass, "original end")

        var multiPass = requireRecorder(id: 22, capacity: 5)
        _ = multiPass.record(.beginRenderPass(pass))
        _ = multiPass.record(.endRenderPass)
        _ = multiPass.record(.beginRenderPass(pass))
        _ = multiPass.record(.endRenderPass)
        let multiBuffer = requireSealed(multiPass.seal())
        expect(multiBuffer.renderPassCount == 2, "multiple pass count")
    }

    private static func enforcesCommandCapacityAndSealState() {
        expect(GPUCommandRecorder(id: commandBufferID(1), capacity: 0) == nil, "zero capacity")
        expect(
            GPUCommandRecorder(
                id: commandBufferID(1),
                capacity: GPUCommandRecorder.maximumCommandCount + 1
            ) == nil,
            "oversized capacity"
        )

        var empty = requireRecorder(id: 30, capacity: 2)
        expectSealRejected(empty.seal(), .noCompletedRenderPass, "empty seal")

        var stranded = requireRecorder(id: 31, capacity: 1)
        _ = stranded.record(
            .beginRenderPass(renderPass(targetID: 1, width: 10, height: 10))
        )
        expectRejected(
            stranded.record(.endRenderPass),
            .capacityExhausted,
            "end at capacity"
        )
        expect(stranded.isInsideRenderPass, "failed end changed state")
        expectSealRejected(
            stranded.seal(),
            .renderPassStillActive,
            "active pass seal"
        )

        var full = requireRecorder(
            id: 32,
            capacity: GPUCommandRecorder.maximumCommandCount
        )
        _ = full.record(
            .beginRenderPass(renderPass(targetID: 1, width: 10, height: 10))
        )
        var index = 0
        while index < GPUCommandRecorder.maximumCommandCount - 2 {
            expectRecorded(full.record(.setTransform(.identity)), index: index + 1)
            index += 1
        }
        expectRecorded(
            full.record(.endRenderPass),
            index: GPUCommandRecorder.maximumCommandCount - 1
        )
        expectRejected(
            full.record(
                .beginRenderPass(renderPass(targetID: 1, width: 1, height: 1))
            ),
            .capacityExhausted,
            "past maximum command count"
        )
        let fullBuffer = requireSealed(full.seal())
        expect(fullBuffer.commandCount == 32, "full inline count")
        expect(fullBuffer.command(at: 31) == .endRenderPass, "last inline slot")
        expectSealRejected(full.seal(), .alreadySealed, "double seal")
        expectRejected(
            full.record(.endRenderPass),
            .recorderSealed,
            "record after seal"
        )
    }

    private static func ordersAndCoalescesFenceWaits() {
        expect(GPUFenceWaitSet(capacity: 0) == nil, "zero wait capacity")
        var waits = requireWaitSet(capacity: 2)
        expect(waits.add(fence(queue: 3, value: 7)) == .inserted(index: 0), "first wait")
        expect(waits.add(fence(queue: 1, value: 5)) == .inserted(index: 0), "sorted wait")
        expect(waits.fence(at: 0) == fence(queue: 1, value: 5), "wait order 1")
        expect(waits.fence(at: 1) == fence(queue: 3, value: 7), "wait order 3")
        expect(waits.add(fence(queue: 1, value: 4)) == .unchanged(index: 0), "older wait")
        expect(waits.add(fence(queue: 1, value: 9)) == .advanced(index: 0), "advanced wait")
        expect(waits.fence(for: queue(1))?.value == 9, "advanced wait value")
        expect(waits.add(fence(queue: 2, value: 1)) == .capacityExhausted, "wait overflow")
        expect(waits.count == 2, "overflow changed wait count")
        expect(waits.fence(at: -1) == nil, "negative wait index")
        expect(waits.fence(at: 2) == nil, "past-end wait index")
    }

    private static func validatesSubmissionMetadata() {
        let emptyWaits = requireWaitSet()
        expect(
            GPUSubmissionMetadata(
                queue: queue(1),
                sequenceNumber: 0,
                frameID: 0,
                waits: emptyWaits,
                signal: nil
            ) == nil,
            "zero sequence accepted"
        )
        expect(
            GPUSubmissionMetadata(
                queue: queue(1),
                sequenceNumber: 1,
                frameID: 0,
                waits: emptyWaits,
                signal: fence(queue: 2, value: 1)
            ) == nil,
            "foreign signal queue accepted"
        )

        var selfWaits = requireWaitSet()
        _ = selfWaits.add(fence(queue: 1, value: 5))
        expect(
            GPUSubmissionMetadata(
                queue: queue(1),
                sequenceNumber: 1,
                frameID: 0,
                waits: selfWaits,
                signal: fence(queue: 1, value: 5)
            ) == nil,
            "self-deadlocking fence accepted"
        )
        let metadata = requireMetadata(
            queueID: 1,
            sequence: 7,
            frameID: 99,
            waits: selfWaits,
            signalValue: 6
        )
        expect(metadata.sequenceNumber == 7, "submission sequence")
        expect(metadata.frameID == 99, "submission frame ID")
        expect(metadata.signal == fence(queue: 1, value: 6), "submission signal")
        expect(GPUFencePoint(queue: queue(1), value: 0) == nil, "zero fence point")
    }

    private static func preservesSubmissionFIFOAndFenceOrder() {
        expect(
            GPUOrderedSubmissionQueue(queue: queue(1), capacity: 0) == nil,
            "zero submission capacity"
        )
        var fifo = requireSubmissionQueue(queueID: 1, capacity: 2)
        let first = submission(bufferID: 101, queueID: 1, sequence: 1, signal: 10)
        let second = submission(bufferID: 102, queueID: 1, sequence: 2, signal: nil)
        let wrongQueue = submission(bufferID: 103, queueID: 2, sequence: 1, signal: 1)

        expect(
            fifo.enqueue(wrongQueue) == .rejected(.wrongQueue),
            "wrong queue submission"
        )
        expect(fifo.enqueue(first) == .enqueued(index: 0), "first enqueue")
        expect(
            fifo.enqueue(submission(bufferID: 104, queueID: 1, sequence: 1, signal: 11))
                == .rejected(.sequenceNotIncreasing),
            "duplicate sequence"
        )
        expect(
            fifo.enqueue(submission(bufferID: 105, queueID: 1, sequence: 2, signal: 9))
                == .rejected(.signalNotIncreasing),
            "regressing signal"
        )
        expect(fifo.enqueue(second) == .enqueued(index: 1), "second enqueue")
        expect(
            fifo.enqueue(submission(bufferID: 106, queueID: 1, sequence: 3, signal: 11))
                == .rejected(.capacityExhausted),
            "submission overflow"
        )
        expect(fifo.next?.commandBuffer == commandBufferID(101), "FIFO next")

        var copy = fifo
        expect(fifo.dequeue()?.commandBuffer == commandBufferID(101), "first dequeue")
        expect(fifo.dequeue()?.commandBuffer == commandBufferID(102), "second dequeue")
        expect(fifo.dequeue() == nil, "empty dequeue")
        expect(copy.count == 2, "copied queue aliased")
        expect(copy.submission(at: 1)?.commandBuffer == commandBufferID(102), "copy slot")

        expect(
            fifo.enqueue(submission(bufferID: 107, queueID: 1, sequence: 2, signal: nil))
                == .rejected(.sequenceNotIncreasing),
            "dequeue reset sequence order"
        )
        expect(
            fifo.enqueue(submission(bufferID: 108, queueID: 1, sequence: 3, signal: 11))
                == .enqueued(index: 0),
            "enqueue after drain"
        )
        expect(fifo.lastAcceptedSignalValue == 11, "signal watermark")
        _ = copy.dequeue()
    }

    private static func fixed(_ value: Int) -> GPUFixed16 {
        guard let result = GPUFixed16(whole: value) else {
            fatalError("test fixed value does not fit")
        }
        return result
    }

    private static func rectangle(
        x: Int = 0,
        y: Int = 0,
        width: Int = 10,
        height: Int = 10
    ) -> GPUFixedRectangle {
        guard let result = GPUFixedRectangle(
            x: fixed(x),
            y: fixed(y),
            width: fixed(width),
            height: fixed(height)
        ) else {
            fatalError("invalid test rectangle")
        }
        return result
    }

    private static func target(_ value: UInt32) -> GPURenderTargetID {
        guard let result = GPURenderTargetID(rawValue: value) else {
            fatalError("invalid test render target")
        }
        return result
    }

    private static func texture(_ value: UInt32) -> GPUTextureID {
        guard let result = GPUTextureID(rawValue: value) else {
            fatalError("invalid test texture")
        }
        return result
    }

    private static func commandBufferID(_ value: UInt64) -> GPUCommandBufferID {
        guard let result = GPUCommandBufferID(rawValue: value) else {
            fatalError("invalid test command buffer ID")
        }
        return result
    }

    private static func queue(_ value: UInt16) -> GPUQueueID {
        guard let result = GPUQueueID(rawValue: value) else {
            fatalError("invalid test queue")
        }
        return result
    }

    private static func requireColor(
        red: UInt16,
        green: UInt16,
        blue: UInt16,
        alpha: UInt16
    ) -> GPUPremultipliedColor {
        guard let result = GPUPremultipliedColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        ) else {
            fatalError("invalid test color")
        }
        return result
    }

    private static func requireTextureRegion(
        minimumU: UInt32,
        minimumV: UInt32,
        maximumU: UInt32,
        maximumV: UInt32
    ) -> GPUTextureRegion {
        guard let result = GPUTextureRegion(
            minimumU: minimumU,
            minimumV: minimumV,
            maximumU: maximumU,
            maximumV: maximumV
        ) else {
            fatalError("invalid test texture region")
        }
        return result
    }

    private static func scissor(
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32
    ) -> GPUScissorRectangle {
        guard let result = GPUScissorRectangle(
            x: x,
            y: y,
            width: width,
            height: height
        ) else {
            fatalError("invalid test scissor")
        }
        return result
    }

    private static func renderPass(
        targetID: UInt32,
        width: UInt32,
        height: UInt32,
        format: GPUColorAttachmentFormat = .bgra8UNormSRGB,
        loadAction: GPURenderPassLoadAction = .load,
        storeAction: GPURenderPassStoreAction = .store
    ) -> GPURenderPassDescriptor {
        guard let extent = GPUPixelExtent(width: width, height: height) else {
            fatalError("invalid test render-pass extent")
        }
        return GPURenderPassDescriptor(
            target: target(targetID),
            extent: extent,
            format: format,
            loadAction: loadAction,
            storeAction: storeAction
        )
    }

    private static func requireRadii(_ whole: Int) -> GPUCornerRadii {
        guard let result = GPUCornerRadii.uniform(fixed(whole)) else {
            fatalError("invalid test radii")
        }
        return result
    }

    private static func requireQuad(
        bounds: GPUFixedRectangle = rectangle(),
        color: GPUPremultipliedColor = .opaqueWhite,
        radii: GPUCornerRadii = .zero,
        blendMode: GPUBlendMode = .sourceOver
    ) -> GPUQuadInstance {
        guard let result = GPUQuadInstance(
            bounds: bounds,
            color: color,
            cornerRadii: radii,
            blendMode: blendMode
        ) else {
            fatalError("invalid test quad")
        }
        return result
    }

    private static func requireGlyph() -> GPUGlyphAtlasInstance {
        GPUGlyphAtlasInstance(
            atlas: texture(1),
            bounds: rectangle(width: 8, height: 12),
            textureRegion: .complete,
            color: .opaqueWhite
        )
    }

    private static func requireRecorder(
        id: UInt64,
        capacity: Int
    ) -> GPUCommandRecorder {
        guard let recorder = GPUCommandRecorder(
            id: commandBufferID(id),
            capacity: capacity
        ) else {
            fatalError("invalid test recorder")
        }
        return recorder
    }

    private static func fence(queue queueID: UInt16, value: UInt64) -> GPUFencePoint {
        guard let result = GPUFencePoint(queue: queue(queueID), value: value) else {
            fatalError("invalid test fence")
        }
        return result
    }

    private static func requireWaitSet(
        capacity: Int = GPUFenceWaitSet.maximumFenceCount
    ) -> GPUFenceWaitSet {
        guard let result = GPUFenceWaitSet(capacity: capacity) else {
            fatalError("invalid test wait set")
        }
        return result
    }

    private static func requireMetadata(
        queueID: UInt16,
        sequence: UInt64,
        frameID: UInt64,
        waits: GPUFenceWaitSet,
        signalValue: UInt64?
    ) -> GPUSubmissionMetadata {
        let signal = signalValue.map { fence(queue: queueID, value: $0) }
        guard let result = GPUSubmissionMetadata(
            queue: queue(queueID),
            sequenceNumber: sequence,
            frameID: frameID,
            waits: waits,
            signal: signal
        ) else {
            fatalError("invalid test submission metadata")
        }
        return result
    }

    private static func submission(
        bufferID: UInt64,
        queueID: UInt16,
        sequence: UInt64,
        signal: UInt64?
    ) -> GPUCommandSubmission {
        GPUCommandSubmission(
            commandBuffer: commandBufferID(bufferID),
            metadata: requireMetadata(
                queueID: queueID,
                sequence: sequence,
                frameID: sequence,
                waits: requireWaitSet(),
                signalValue: signal
            )
        )
    }

    private static func requireSubmissionQueue(
        queueID: UInt16,
        capacity: Int
    ) -> GPUOrderedSubmissionQueue {
        guard let result = GPUOrderedSubmissionQueue(
            queue: queue(queueID),
            capacity: capacity
        ) else {
            fatalError("invalid test submission queue")
        }
        return result
    }

    private static func expectRecorded(
        _ result: GPUCommandRecordResult,
        index: Int
    ) {
        expect(result == .recorded(index: index), "recorded command index \(index)")
    }

    private static func expectRejected(
        _ result: GPUCommandRecordResult,
        _ rejection: GPUCommandRecordRejection,
        _ message: String
    ) {
        expect(result == .rejected(rejection), message)
    }

    private static func requireSealed(
        _ result: GPUCommandBufferSealResult
    ) -> GPURenderCommandBuffer {
        if case .sealed(let buffer) = result { return buffer }
        fatalError("command buffer did not seal")
    }

    private static func expectSealRejected(
        _ result: GPUCommandBufferSealResult,
        _ rejection: GPUCommandBufferSealRejection,
        _ message: String
    ) {
        if case .rejected(let actual) = result {
            expect(actual == rejection, message)
            return
        }
        fatalError(message)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
