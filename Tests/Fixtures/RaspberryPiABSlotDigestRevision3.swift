/// Swift constants paired with `rpi5_ab_slot_digest_revision3.json`.
///
/// The Python golden checks these declarations against the JSON fixture before
/// invoking the production media builder. Keeping the Swift half free of host
/// SDK imports also exercises the same freestanding compilation boundary as
/// the update port.
enum RaspberryPiABSlotDigestRevision3Golden {
    static let fixtureVersion = 1
    static let mediaLayoutFingerprint: UInt64 = 0x5357_4142_0000_0003
    static let logicalBlockByteCount = 512
    static let slotBlockCount: UInt64 = 256
    static let slotAStartBlock: UInt64 = 2_048
    static let slotBStartBlock: UInt64 = 2_304
    static let contentPatternMultiplier = 37
    static let contentPatternIncrement = 11
    static let contentPatternModulus = 256
    static let hiddenSectorRelativeBlocks: [UInt64] = [0, 6]
    static let hiddenSectorByteOffset = 28
    static let hiddenSectorByteCount = 4
    static let hiddenSectorEncoding = "little-endian-u32"
    static let normalizedSHA256Hex =
        "b82cd79876de9d4f6ae35efe51fceffb924cbb3569106bd027d551753d8ba391"
}
