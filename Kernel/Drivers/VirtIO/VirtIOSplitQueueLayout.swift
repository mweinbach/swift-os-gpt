/// Transport-neutral split-virtqueue geometry for caller-owned DMA storage.
///
/// Both trailing event words are reserved even when EVENT_IDX is not
/// negotiated. This keeps every ring conforming while allowing a device
/// driver to select the smaller notification contract independently.
struct VirtIOSplitQueueLayout: Equatable {
    static let maximumSize: UInt16 = 1_024

    let size: UInt16
    let descriptorOffset: UInt64
    let availableOffset: UInt64
    let usedOffset: UInt64
    let requiredByteCount: UInt64

    init?(size: UInt16) {
        guard size > 0,
              size <= Self.maximumSize,
              size & (size - 1) == 0
        else {
            return nil
        }

        let count = UInt64(size)
        let descriptorByteCount = count * 16
        // flags + idx + ring entries + used_event.
        let availableByteCount = 6 + count * 2
        let used = Self.aligned(
            descriptorByteCount + availableByteCount,
            to: 4
        )
        // flags + idx + used elements + avail_event.
        let required = used + 6 + count * 8

        self.size = size
        descriptorOffset = 0
        availableOffset = descriptorByteCount
        usedOffset = used
        requiredByteCount = required
    }

    private static func aligned(
        _ value: UInt64,
        to alignment: UInt64
    ) -> UInt64 {
        (value + alignment - 1) & ~(alignment - 1)
    }
}
