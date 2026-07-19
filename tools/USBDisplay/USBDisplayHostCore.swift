/// Host-side stream recovery and framebuffer assembly for the SwiftOS USB
/// diagnostic display. This file deliberately has no AppKit or device-I/O
/// dependency so the complete receive path can be exercised headlessly.

enum USBDisplayHostLimits {
    /// Enough for an 8K 32-bit framebuffer while remaining a hard allocation
    /// bound if a damaged or malicious peer advertises impossible metadata.
    static let maximumFrameByteCount = 512 * 1_024 * 1_024

    /// The wire packet limit is just over 1 KiB. Keeping up to 64 packets lets
    /// reads arrive in large batches without permitting unbounded buffering.
    static let maximumStreamByteCount =
        USBDebugDisplayProtocol.maximumPacketByteCount * 64

    /// Large caller buffers are admitted incrementally so valid packets are
    /// decoded before later garbage can exert buffer pressure.
    static let ingestionSliceByteCount = 16 * 1_024
}

struct USBDisplayCompletedFrame: Equatable {
    let frameID: UInt64
    let mode: USBDebugDisplayMode
    let pixels: [UInt8]
    /// Nil identifies a full-frame replacement.
    let updatedRectangle: USBDebugDisplayDamageRectangle?
}

enum USBDisplayFrameAssemblyRejection: Error, Equatable {
    case missingMode
    case frameTooLarge(requested: UInt64, maximum: Int)
    case frameAlreadyActive
    case noActiveFrame
    case frameIDMismatch(expected: UInt64, actual: UInt64)
    case byteCountMismatch(expected: UInt64, actual: UInt64)
    case chunkOffsetMismatch(expected: UInt64, actual: UInt64)
    case chunkExceedsFrame
    case invalidDamageRectangle
}

enum USBDisplayHostEvent: Equatable {
    case modeChanged(USBDebugDisplayMode)
    case frameCompleted(USBDisplayCompletedFrame)
    case protocolReset(generation: UInt32)
    case framingRejected(USBDebugDisplayDecodeRejection)
    case semanticRejected(USBDebugDisplayReceiverRejection)
    case assemblyRejected(USBDisplayFrameAssemblyRejection)
    case streamBytesDiscarded(count: Int)
}

private enum USBDisplayPendingUpdateKind {
    case fullFrame
    case damage(USBDebugDisplayDamageRectangle)
}

private struct USBDisplayPendingUpdate {
    let frameID: UInt64
    let kind: USBDisplayPendingUpdateKind
    let expectedByteCount: UInt64
    var nextOffset: UInt64
    var bytes: [UInt8]
}

/// Applies semantically validated wire updates to a persistent framebuffer.
/// Damage payloads are tightly packed on the wire and are expanded back into
/// the scanout stride only after their complete frame CRC has been accepted.
private struct USBDisplayFrameAssembler {
    private let maximumFrameByteCount: Int
    private(set) var mode: USBDebugDisplayMode?
    private var framebuffer: [UInt8] = []
    private var pending: USBDisplayPendingUpdate?

    init(maximumFrameByteCount: Int) {
        self.maximumFrameByteCount = maximumFrameByteCount
    }

    mutating func configure(
        _ displayMode: USBDebugDisplayMode
    ) -> USBDisplayFrameAssemblyRejection? {
        guard let byteCount = boundedByteCount(displayMode.fullFrameByteCount)
        else {
            return .frameTooLarge(
                requested: displayMode.fullFrameByteCount,
                maximum: maximumFrameByteCount
            )
        }
        mode = displayMode
        framebuffer = [UInt8](repeating: 0, count: byteCount)
        pending = nil
        return nil
    }

    mutating func beginFullFrame(
        frameID: UInt64,
        byteCount: UInt64
    ) -> USBDisplayFrameAssemblyRejection? {
        guard mode != nil else { return .missingMode }
        guard pending == nil else { return .frameAlreadyActive }
        guard let count = boundedByteCount(byteCount) else {
            return .frameTooLarge(
                requested: byteCount,
                maximum: maximumFrameByteCount
            )
        }
        pending = USBDisplayPendingUpdate(
            frameID: frameID,
            kind: .fullFrame,
            expectedByteCount: byteCount,
            nextOffset: 0,
            bytes: [UInt8](repeating: 0, count: count)
        )
        return nil
    }

    mutating func beginDamage(
        frameID: UInt64,
        rectangle: USBDebugDisplayDamageRectangle,
        byteCount: UInt64
    ) -> USBDisplayFrameAssemblyRejection? {
        guard let displayMode = mode else { return .missingMode }
        guard pending == nil else { return .frameAlreadyActive }
        guard rectangle.fits(displayMode),
              rectangle.packedByteCount(format: displayMode.pixelFormat)
                == byteCount
        else {
            return .invalidDamageRectangle
        }
        guard let count = boundedByteCount(byteCount) else {
            return .frameTooLarge(
                requested: byteCount,
                maximum: maximumFrameByteCount
            )
        }
        pending = USBDisplayPendingUpdate(
            frameID: frameID,
            kind: .damage(rectangle),
            expectedByteCount: byteCount,
            nextOffset: 0,
            bytes: [UInt8](repeating: 0, count: count)
        )
        return nil
    }

    mutating func append(
        frameID: UInt64,
        offset: UInt64,
        bytes: UnsafeRawBufferPointer
    ) -> USBDisplayFrameAssemblyRejection? {
        guard var active = pending else { return .noActiveFrame }
        guard active.frameID == frameID else {
            return .frameIDMismatch(
                expected: active.frameID,
                actual: frameID
            )
        }
        guard active.nextOffset == offset else {
            return .chunkOffsetMismatch(
                expected: active.nextOffset,
                actual: offset
            )
        }
        let end = offset.addingReportingOverflow(UInt64(bytes.count))
        guard !end.overflow, end.partialValue <= active.expectedByteCount,
              let destinationOffset = Int(exactly: offset)
        else {
            return .chunkExceedsFrame
        }
        active.bytes.withUnsafeMutableBytes { destination in
            guard bytes.count != 0,
                  let destinationBase = destination.baseAddress,
                  let sourceBase = bytes.baseAddress
            else { return }
            destinationBase.advanced(by: destinationOffset).copyMemory(
                from: sourceBase,
                byteCount: bytes.count
            )
        }
        active.nextOffset = end.partialValue
        pending = active
        return nil
    }

    mutating func complete(
        frameID: UInt64,
        byteCount: UInt64
    ) -> Result<USBDisplayCompletedFrame, USBDisplayFrameAssemblyRejection> {
        guard let active = pending else { return .failure(.noActiveFrame) }
        guard active.frameID == frameID else {
            return .failure(
                .frameIDMismatch(
                    expected: active.frameID,
                    actual: frameID
                )
            )
        }
        guard active.expectedByteCount == byteCount,
              active.nextOffset == byteCount
        else {
            return .failure(
                .byteCountMismatch(
                    expected: active.expectedByteCount,
                    actual: active.nextOffset
                )
            )
        }
        guard let displayMode = mode else { return .failure(.missingMode) }

        let updatedRectangle: USBDebugDisplayDamageRectangle?
        switch active.kind {
        case .fullFrame:
            framebuffer = active.bytes
            updatedRectangle = nil

        case .damage(let rectangle):
            let sourceRowByteCount = Int(
                UInt64(rectangle.width)
                    * UInt64(displayMode.pixelFormat.bytesPerPixel)
            )
            let destinationRowByteCount = Int(displayMode.bytesPerRow)
            let destinationX = Int(
                UInt64(rectangle.x)
                    * UInt64(displayMode.pixelFormat.bytesPerPixel)
            )
            var row = 0
            while row < Int(rectangle.height) {
                let sourceOffset = row * sourceRowByteCount
                let destinationOffset =
                    (Int(rectangle.y) + row) * destinationRowByteCount
                    + destinationX
                active.bytes.withUnsafeBytes { source in
                    framebuffer.withUnsafeMutableBytes { destination in
                        guard let sourceBase = source.baseAddress,
                              let destinationBase = destination.baseAddress
                        else { return }
                        destinationBase.advanced(by: destinationOffset)
                            .copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: sourceRowByteCount
                            )
                    }
                }
                row += 1
            }
            updatedRectangle = rectangle
        }

        pending = nil
        return .success(
            USBDisplayCompletedFrame(
                frameID: frameID,
                mode: displayMode,
                pixels: framebuffer,
                updatedRectangle: updatedRectangle
            )
        )
    }

    mutating func abortPendingFrame() {
        pending = nil
    }

    mutating func reset() {
        mode = nil
        framebuffer = []
        pending = nil
    }

    private func boundedByteCount(_ count: UInt64) -> Int? {
        guard count != 0,
              count <= UInt64(maximumFrameByteCount),
              let integer = Int(exactly: count)
        else { return nil }
        return integer
    }
}

private enum USBDisplayStreamStep {
    case packet
    case needMoreBytes
    case rejected(USBDebugDisplayDecodeRejection)
}

/// A compacting byte queue that never exposes a decoded chunk pointer beyond
/// the lifetime of its backing storage borrow.
private final class USBDisplayStreamBuffer {
    private let maximumByteCount: Int
    private var storage: [UInt8] = []
    private var readOffset = 0

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
        storage.reserveCapacity(maximumByteCount)
    }

    var availableByteCount: Int { storage.count - readOffset }

    func append(_ bytes: UnsafeRawBufferPointer) -> Int {
        compactIfUseful(force: false)
        if let base = bytes.baseAddress, bytes.count != 0 {
            let typed = base.assumingMemoryBound(to: UInt8.self)
            storage.append(contentsOf: UnsafeBufferPointer(start: typed, count: bytes.count))
        }
        let overflow = availableByteCount - maximumByteCount
        if overflow > 0 {
            discard(overflow)
            return overflow
        }
        return 0
    }

    func processNext(
        _ body: (USBDebugDisplayDecodedPacket) -> Void
    ) -> USBDisplayStreamStep {
        guard availableByteCount != 0 else { return .needMoreBytes }
        var step: USBDisplayStreamStep = .needMoreBytes
        var consumedByteCount = 0
        storage.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let active = UnsafeRawBufferPointer(
                start: base.advanced(by: readOffset),
                count: availableByteCount
            )
            switch USBDebugDisplayPacketDecoder.decodePrefix(active) {
            case .decoded(let packet):
                body(packet)
                consumedByteCount = packet.encodedByteCount
                step = .packet

            case .needMoreBytes:
                step = .needMoreBytes

            case .rejected(let rejection, let discardByteCount):
                consumedByteCount = discardByteCount > 0
                    ? discardByteCount : 1
                step = .rejected(rejection)
            }
        }
        if consumedByteCount != 0 { discard(consumedByteCount) }
        return step
    }

    func reset() {
        storage.removeAll(keepingCapacity: true)
        readOffset = 0
    }

    private func discard(_ count: Int) {
        let bounded = count < availableByteCount ? count : availableByteCount
        readOffset += bounded
        compactIfUseful(force: availableByteCount == 0)
    }

    private func compactIfUseful(force: Bool) {
        guard readOffset != 0 else { return }
        if force || readOffset >= 4_096 || readOffset * 2 >= storage.count {
            storage.removeFirst(readOffset)
            readOffset = 0
        }
    }
}

/// Complete host receive pipeline: bounded framing recovery, strict protocol
/// state validation, and atomic full/damage framebuffer assembly.
final class USBDisplayHostPipeline {
    typealias EventHandler = (USBDisplayHostEvent) -> Void

    private let stream: USBDisplayStreamBuffer
    private var receiver = USBDebugDisplayReceiver()
    private var assembler: USBDisplayFrameAssembler

    var onEvent: EventHandler?

    init(
        maximumFrameByteCount: Int =
            USBDisplayHostLimits.maximumFrameByteCount,
        maximumStreamByteCount: Int =
            USBDisplayHostLimits.maximumStreamByteCount
    ) {
        precondition(maximumFrameByteCount > 0)
        precondition(
            maximumStreamByteCount
                >= USBDebugDisplayProtocol.maximumPacketByteCount
        )
        stream = USBDisplayStreamBuffer(
            maximumByteCount: maximumStreamByteCount
        )
        assembler = USBDisplayFrameAssembler(
            maximumFrameByteCount: maximumFrameByteCount
        )
    }

    func ingest(_ bytes: UnsafeRawBufferPointer) {
        var sourceOffset = 0
        while sourceOffset < bytes.count {
            let count = min(
                USBDisplayHostLimits.ingestionSliceByteCount,
                bytes.count - sourceOffset
            )
            let slice: UnsafeRawBufferPointer
            if let base = bytes.baseAddress {
                slice = UnsafeRawBufferPointer(
                    start: base.advanced(by: sourceOffset),
                    count: count
                )
            } else {
                slice = UnsafeRawBufferPointer(start: nil, count: 0)
            }
            let discarded = stream.append(slice)
            if discarded != 0 {
                onEvent?(.streamBytesDiscarded(count: discarded))
            }
            drain()
            sourceOffset += count
        }
    }

    func resetForTransportDisconnect() {
        stream.reset()
        receiver = USBDebugDisplayReceiver()
        assembler.reset()
    }

    private func drain() {
        while true {
            var event: USBDisplayHostEvent?
            let step = stream.processNext { [self] packet in
                event = accept(packet)
            }
            if let event { onEvent?(event) }
            switch step {
            case .packet:
                continue
            case .rejected(let rejection):
                onEvent?(.framingRejected(rejection))
                continue
            case .needMoreBytes:
                return
            }
        }
    }

    private func accept(
        _ packet: USBDebugDisplayDecodedPacket
    ) -> USBDisplayHostEvent? {
        let result = receiver.accept(packet)
        guard case .accepted(let semanticEvent) = result else {
            if case .rejected(let rejection) = result {
                assembler.abortPendingFrame()
                return .semanticRejected(rejection)
            }
            return nil
        }

        switch semanticEvent {
        case .helloAccepted, .capabilitiesAccepted:
            return nil

        case .displayModeAccepted:
            guard let displayMode = receiver.mode else {
                return .assemblyRejected(.missingMode)
            }
            if let rejection = assembler.configure(displayMode) {
                return .assemblyRejected(rejection)
            }
            return .modeChanged(displayMode)

        case .frameBegan:
            let rejection: USBDisplayFrameAssemblyRejection?
            switch packet.message {
            case .fullFrameBegin(let begin):
                rejection = assembler.beginFullFrame(
                    frameID: packet.frameID,
                    byteCount: begin.totalDataByteCount
                )
            case .damageFrameBegin(let begin):
                rejection = assembler.beginDamage(
                    frameID: packet.frameID,
                    rectangle: begin.rectangle,
                    byteCount: begin.totalDataByteCount
                )
            default:
                rejection = .noActiveFrame
            }
            return rejection.map { .assemblyRejected($0) }

        case .chunkAccepted:
            guard case .frameChunk(let chunk) = packet.message else {
                return .assemblyRejected(.noActiveFrame)
            }
            if let rejection = assembler.append(
                frameID: packet.frameID,
                offset: chunk.offset,
                bytes: chunk.data
            ) {
                return .assemblyRejected(rejection)
            }
            return nil

        case .frameCompleted(let frameID):
            guard case .frameEnd(let end) = packet.message else {
                return .assemblyRejected(.noActiveFrame)
            }
            switch assembler.complete(
                frameID: frameID,
                byteCount: end.totalDataByteCount
            ) {
            case .success(let frame):
                return .frameCompleted(frame)
            case .failure(let rejection):
                return .assemblyRejected(rejection)
            }

        case .resetAccepted(let generation):
            assembler.reset()
            return .protocolReset(generation: generation)
        }
    }
}
