/// Host-side reconstruction of the canonical console byte stream retained in
/// `KernelDebugLogRuntime`. SDBG transports the original `KernelLogEntry`
/// records, so this decoder shares the guest's CONS record definition instead
/// of inventing a second USB-only console format.
struct SwiftOSCanonicalConsoleDecodeResult: Equatable {
    let bytes: [UInt8]
    let consoleChunkCount: Int
    let nonConsoleEntryCount: Int
    let malformedConsoleEntryCount: Int
    let sequenceDiscontinuityCount: Int
    let incompleteMessageCount: Int
    let startsMidMessage: Bool
    let endsMidMessage: Bool
}

enum SwiftOSCanonicalConsoleDecoder {
    static func decode(
        _ entries: [KernelLogEntry]
    ) -> SwiftOSCanonicalConsoleDecodeResult {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(entries.count * 8)

        var consoleChunkCount = 0
        var nonConsoleEntryCount = 0
        var malformedConsoleEntryCount = 0
        var sequenceDiscontinuityCount = 0
        var incompleteMessageCount = 0
        var startsMidMessage = false
        var inMessage = false
        var currentMessageIsIncomplete = false
        var currentSource: KernelConsoleLogSource?
        var previousSequence: UInt64?

        for entry in entries {
            if let previousSequence {
                let isContiguous = previousSequence != UInt64.max
                    && entry.sequence == previousSequence + 1
                if !isContiguous {
                    sequenceDiscontinuityCount += 1
                    if inMessage {
                        incompleteMessageCount += 1
                        inMessage = false
                        currentMessageIsIncomplete = false
                        currentSource = nil
                    }
                }
            }
            previousSequence = entry.sequence

            guard let chunk = KernelConsoleLogChunk(event: entry.event) else {
                if entry.event.eventCode == KernelConsoleLogChunk.eventCode {
                    malformedConsoleEntryCount += 1
                } else {
                    nonConsoleEntryCount += 1
                }
                continue
            }

            consoleChunkCount += 1
            if chunk.isFirst {
                if inMessage {
                    incompleteMessageCount += 1
                }
                inMessage = true
                currentMessageIsIncomplete = false
                currentSource = chunk.source
            } else if !inMessage {
                if consoleChunkCount == 1 {
                    startsMidMessage = true
                }
                inMessage = true
                currentMessageIsIncomplete = true
                currentSource = chunk.source
            } else if currentSource != chunk.source {
                currentMessageIsIncomplete = true
                currentSource = chunk.source
            }

            var byteIndex = 0
            while byteIndex < chunk.byteCount {
                if let byte = chunk.byte(at: byteIndex) {
                    bytes.append(byte)
                }
                byteIndex += 1
            }

            if chunk.isLast {
                if currentMessageIsIncomplete {
                    incompleteMessageCount += 1
                }
                inMessage = false
                currentMessageIsIncomplete = false
                currentSource = nil
            }
        }

        let endsMidMessage = inMessage
        if endsMidMessage {
            incompleteMessageCount += 1
        }
        return SwiftOSCanonicalConsoleDecodeResult(
            bytes: bytes,
            consoleChunkCount: consoleChunkCount,
            nonConsoleEntryCount: nonConsoleEntryCount,
            malformedConsoleEntryCount: malformedConsoleEntryCount,
            sequenceDiscontinuityCount: sequenceDiscontinuityCount,
            incompleteMessageCount: incompleteMessageCount,
            startsMidMessage: startsMidMessage,
            endsMidMessage: endsMidMessage
        )
    }
}
