enum USBDebugDisplayTransmitResult: Equatable {
    case packet(byteCount: Int)
    case idle
    case outputBufferTooSmall(requiredByteCount: Int)
    case faulted
}

enum USBDebugDisplayTransmitPhase: UInt8, Equatable {
    case hello
    case capabilities
    case mode
    case ready
    case frameBegin
    case frameChunks
    case frameEnd
    case faulted
}

/// Allocation-free producer for a framebuffer observation stream. Rendering
/// remains owned by the GPU/display backend; this type reads only a completed,
/// CPU-visible diagnostic surface after presentation synchronization.
struct USBDebugDisplayTransmitter {
    private enum PreparedTransition: UInt8 {
        case none
        case hello
        case capabilities
        case mode
        case frameBegin
        case frameChunk
        case frameEnd
    }

    private let sourceBaseAddress: UInt
    private let sourceByteCount: UInt64
    private let sessionID: UInt64
    private let displayMode: DisplayMode
    private let wireMode: USBDebugDisplayMode

    private(set) var phase: USBDebugDisplayTransmitPhase = .hello
    private(set) var sequence: UInt32 = 1
    private(set) var activeFrameID: UInt64 = 0
    private var nextFrameID: UInt64 = 1
    private var activeDamage: DamageRectangle?
    private var queuedDamage: DamageRectangle?
    private var frameByteCount: UInt64 = 0
    private var frameChunkCount: UInt32 = 0
    private var frameChunkSequence: UInt32 = 1
    private var frameOffset: UInt64 = 0
    private var frameCRC = USBDebugDisplayCRC32()
    private var preparedTransition: PreparedTransition = .none
    private var preparedByteCount = 0

    init?(
        sourceBaseAddress: UInt64,
        sourceByteCount: UInt64,
        mode: DisplayMode,
        bytesPerRow: UInt64,
        scaleNumerator: UInt16,
        scaleDenominator: UInt16 = 1,
        horizontalPixelsPerInchMilli: UInt32 = 0,
        verticalPixelsPerInchMilli: UInt32 = 0,
        sessionID: UInt64
    ) {
        guard sourceBaseAddress <= UInt64(UInt.max),
              sourceByteCount > 0,
              sourceByteCount <= UInt64.max - sourceBaseAddress,
              bytesPerRow <= UInt64(UInt32.max),
              UInt64(mode.heightInPixels) <= UInt64.max / bytesPerRow,
              bytesPerRow * UInt64(mode.heightInPixels) <= sourceByteCount,
              let pixelFormat = USBDebugDisplayPixelFormat(
                  rawValue: mode.pixelFormat.rawValue
              ), let wireMode = USBDebugDisplayMode(
                  width: mode.widthInPixels,
                  height: mode.heightInPixels,
                  bytesPerRow: UInt32(bytesPerRow),
                  pixelFormat: pixelFormat,
                  scaleNumerator: scaleNumerator,
                  scaleDenominator: scaleDenominator,
                  horizontalPixelsPerInchMilli:
                    horizontalPixelsPerInchMilli,
                  verticalPixelsPerInchMilli: verticalPixelsPerInchMilli,
                  refreshRateMilliHertz: mode.refreshRateMilliHertz ?? 0
              ), sessionID != 0
        else {
            return nil
        }
        self.sourceBaseAddress = UInt(sourceBaseAddress)
        self.sourceByteCount = sourceByteCount
        self.sessionID = sessionID
        displayMode = mode
        self.wireMode = wireMode
    }

    var isReady: Bool {
        phase == .ready && preparedTransition == .none
    }

    var hasQueuedFrame: Bool {
        queuedDamage != nil || activeDamage != nil
    }

    mutating func requestFullFrame() {
        queuedDamage = DamageRectangle.fullMode(displayMode)
    }

    mutating func requestDamage(_ damage: DamageRectangle) {
        let full = DamageRectangle.fullMode(displayMode)
        guard damage != full else {
            queuedDamage = full
            return
        }
        guard let existing = queuedDamage else {
            queuedDamage = damage
            return
        }
        guard existing != full else { return }
        let minimumX = existing.x < damage.x ? existing.x : damage.x
        let minimumY = existing.y < damage.y ? existing.y : damage.y
        let existingEndX = UInt64(existing.x) + UInt64(existing.width)
        let existingEndY = UInt64(existing.y) + UInt64(existing.height)
        let damageEndX = UInt64(damage.x) + UInt64(damage.width)
        let damageEndY = UInt64(damage.y) + UInt64(damage.height)
        let maximumX = existingEndX > damageEndX ? existingEndX : damageEndX
        let maximumY = existingEndY > damageEndY ? existingEndY : damageEndY
        queuedDamage = DamageRectangle.clipped(
            x: Int64(minimumX),
            y: Int64(minimumY),
            width: Int64(maximumX - UInt64(minimumX)),
            height: Int64(maximumY - UInt64(minimumY)),
            to: displayMode
        )
    }

    mutating func prepareNextPacket(
        into output: UnsafeMutableRawBufferPointer
    ) -> USBDebugDisplayTransmitResult {
        guard phase != .faulted else { return .faulted }
        if preparedTransition != .none {
            return .packet(byteCount: preparedByteCount)
        }
        guard output.count >= USBDebugDisplayProtocol.maximumPacketByteCount
        else {
            return .outputBufferTooSmall(
                requiredByteCount:
                    USBDebugDisplayProtocol.maximumPacketByteCount
            )
        }
        guard sequence < UInt32.max else { return fail() }

        if phase == .ready {
            guard beginQueuedFrame() else { return .idle }
        }

        let message: USBDebugDisplayMessage
        let frameID: UInt64
        let transition: PreparedTransition
        switch phase {
        case .hello:
            guard let hello = USBDebugDisplayHello(
                      sessionID: sessionID,
                      role: .guest
                  )
            else { return fail() }
            message = .hello(hello)
            frameID = 0
            transition = .hello

        case .capabilities:
            guard let capabilities = USBDebugDisplayCapabilities(
                      sessionID: sessionID,
                      features: USBDebugDisplayCapabilityBits(
                          rawValue: USBDebugDisplayCapabilityBits.required
                      ),
                      maximumPayloadByteCount: UInt32(
                          USBDebugDisplayProtocol.maximumPayloadByteCount
                      ),
                      maximumChunkDataByteCount: UInt32(
                          USBDebugDisplayProtocol.maximumChunkDataByteCount
                      ),
                      maximumWidth: displayMode.widthInPixels,
                      maximumHeight: displayMode.heightInPixels,
                      pixelFormatMask: wireMode.pixelFormat.capabilityMask
                  )
            else { return fail() }
            message = .capabilities(capabilities)
            frameID = 0
            transition = .capabilities

        case .mode:
            message = .displayMode(wireMode)
            frameID = 0
            transition = .mode

        case .frameBegin:
            guard let damage = activeDamage else { return fail() }
            if damage == DamageRectangle.fullMode(displayMode) {
                message = .fullFrameBegin(
                    USBDebugDisplayFullFrameBegin(
                        totalDataByteCount: frameByteCount,
                        chunkCount: frameChunkCount
                    )
                )
            } else {
                guard let rectangle = USBDebugDisplayDamageRectangle(
                          x: damage.x,
                          y: damage.y,
                          width: damage.width,
                          height: damage.height
                      )
                else { return fail() }
                message = .damageFrameBegin(
                    USBDebugDisplayDamageFrameBegin(
                        rectangle: rectangle,
                        totalDataByteCount: frameByteCount,
                        chunkCount: frameChunkCount
                    )
                )
            }
            frameID = activeFrameID
            transition = .frameBegin

        case .frameChunks:
            guard let damage = activeDamage,
                  frameOffset < frameByteCount,
                  let outputBase = output.baseAddress
            else { return fail() }
            let remaining = frameByteCount - frameOffset
            let chunkByteCount = remaining
                < UInt64(USBDebugDisplayProtocol.maximumChunkDataByteCount)
                ? Int(remaining)
                : USBDebugDisplayProtocol.maximumChunkDataByteCount
            let payload = UnsafeMutableRawBufferPointer(
                start: outputBase.advanced(
                    by: USBDebugDisplayProtocol.headerByteCount
                        + USBDebugDisplayProtocol.frameChunkPrefixByteCount
                ),
                count: chunkByteCount
            )
            guard copyFrameBytes(
                      damage: damage,
                      packedOffset: frameOffset,
                      into: payload
                  )
            else { return fail() }
            let chunkBytes = UnsafeRawBufferPointer(payload)
            message = .frameChunk(
                USBDebugDisplayFrameChunk(
                    chunkSequence: frameChunkSequence,
                    offset: frameOffset,
                    data: chunkBytes
                )
            )
            frameCRC.update(chunkBytes)
            frameID = activeFrameID
            transition = .frameChunk

        case .frameEnd:
            message = .frameEnd(
                USBDebugDisplayFrameEnd(
                    chunkCount: frameChunkCount,
                    frameCRC32: frameCRC.value,
                    totalDataByteCount: frameByteCount
                )
            )
            frameID = activeFrameID
            transition = .frameEnd

        case .ready:
            return .idle
        case .faulted:
            return .faulted
        }

        switch USBDebugDisplayPacketEncoder.encode(
            message,
            sequence: sequence,
            frameID: frameID,
            into: output
        ) {
        case .encoded(let byteCount):
            preparedTransition = transition
            preparedByteCount = byteCount
            return .packet(byteCount: byteCount)
        case .rejected:
            return fail()
        }
    }

    @discardableResult
    mutating func commitPreparedPacket() -> Bool {
        guard preparedTransition != .none else { return false }
        let transition = preparedTransition
        preparedTransition = .none
        preparedByteCount = 0
        sequence &+= 1

        switch transition {
        case .none:
            return false
        case .hello:
            phase = .capabilities
        case .capabilities:
            phase = .mode
        case .mode:
            phase = .ready
        case .frameBegin:
            phase = .frameChunks
        case .frameChunk:
            let remaining = frameByteCount - frameOffset
            let committed = remaining
                < UInt64(USBDebugDisplayProtocol.maximumChunkDataByteCount)
                ? remaining
                : UInt64(USBDebugDisplayProtocol.maximumChunkDataByteCount)
            frameOffset += committed
            frameChunkSequence &+= 1
            if frameOffset == frameByteCount { phase = .frameEnd }
        case .frameEnd:
            activeDamage = nil
            activeFrameID = 0
            frameByteCount = 0
            frameChunkCount = 0
            frameChunkSequence = 1
            frameOffset = 0
            frameCRC = USBDebugDisplayCRC32()
            phase = .ready
        }
        return true
    }

    private mutating func beginQueuedFrame() -> Bool {
        guard let damage = queuedDamage,
              nextFrameID != 0,
              nextFrameID < UInt64.max
        else {
            return false
        }
        let full = damage == DamageRectangle.fullMode(displayMode)
        let byteCount: UInt64
        if full {
            byteCount = wireMode.fullFrameByteCount
        } else {
            let rowBytes = UInt64(damage.width).multipliedReportingOverflow(
                by: UInt64(wireMode.pixelFormat.bytesPerPixel)
            )
            guard !rowBytes.overflow else { return false }
            let total = rowBytes.partialValue.multipliedReportingOverflow(
                by: UInt64(damage.height)
            )
            guard !total.overflow, total.partialValue > 0 else { return false }
            byteCount = total.partialValue
        }
        let maximum = UInt64(
            USBDebugDisplayProtocol.maximumChunkDataByteCount
        )
        let chunks = byteCount / maximum + (byteCount % maximum == 0 ? 0 : 1)
        guard chunks > 0, chunks <= UInt64(UInt32.max) else { return false }

        queuedDamage = nil
        activeDamage = damage
        activeFrameID = nextFrameID
        nextFrameID &+= 1
        frameByteCount = byteCount
        frameChunkCount = UInt32(chunks)
        frameChunkSequence = 1
        frameOffset = 0
        frameCRC = USBDebugDisplayCRC32()
        phase = .frameBegin
        return true
    }

    private func copyFrameBytes(
        damage: DamageRectangle,
        packedOffset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> Bool {
        guard let source = UnsafeRawPointer(bitPattern: sourceBaseAddress),
              output.count > 0
        else {
            return false
        }
        let full = damage == DamageRectangle.fullMode(displayMode)
        if full {
            guard packedOffset <= sourceByteCount,
                  UInt64(output.count) <= sourceByteCount - packedOffset,
                  packedOffset <= UInt64(Int.max)
            else {
                return false
            }
            let input = source.advanced(by: Int(packedOffset))
                .assumingMemoryBound(to: UInt8.self)
            var index = 0
            while index < output.count {
                output[index] = input[index]
                index += 1
            }
            return true
        }

        let bytesPerPixel = UInt64(wireMode.pixelFormat.bytesPerPixel)
        let packedRowByteCount = UInt64(damage.width) * bytesPerPixel
        guard packedRowByteCount > 0 else { return false }
        var outputIndex = 0
        var offset = packedOffset
        while outputIndex < output.count {
            let row = offset / packedRowByteCount
            let columnByte = offset % packedRowByteCount
            guard row < UInt64(damage.height) else { return false }
            let sourceRow = UInt64(damage.y) + row
            let sourceColumn = UInt64(damage.x) * bytesPerPixel + columnByte
            let rowOffset = sourceRow.multipliedReportingOverflow(
                by: UInt64(wireMode.bytesPerRow)
            )
            guard !rowOffset.overflow else { return false }
            let sourceOffset = rowOffset.partialValue.addingReportingOverflow(
                sourceColumn
            )
            guard !sourceOffset.overflow,
                  sourceOffset.partialValue < sourceByteCount,
                  sourceOffset.partialValue <= UInt64(Int.max)
            else {
                return false
            }
            output[outputIndex] = source
                .advanced(by: Int(sourceOffset.partialValue))
                .load(as: UInt8.self)
            outputIndex += 1
            offset += 1
        }
        return true
    }

    private mutating func fail() -> USBDebugDisplayTransmitResult {
        phase = .faulted
        preparedTransition = .none
        preparedByteCount = 0
        return .faulted
    }
}
