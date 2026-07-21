/// Raspberry Pi's mapping from the shared logical A/B contract to its FAT32
/// firmware media. Partition discovery supplies the ranges; this adapter adds
/// only the stable format identity and bootability ordering. QEMU and future
/// boards continue to use the same orchestrator with their own adapter.
enum RaspberryPiABUpdateLayout {
    static let mediaLayoutFingerprint: UInt64 = 0x5357_4142_0000_0002
    static let writePolicy = BootSlotWritePolicy.deferredActivation(
        firstCommitBlock: 6,
        lastCommitBlock: 0
    )

    static func make(
        deviceGeometry: BlockDeviceGeometry,
        slotA: BlockDeviceRange,
        slotB: BlockDeviceRange
    ) -> BootSlotLayout? {
        // Pi media format v2 and the firmware FAT commit offsets are defined
        // in 512-byte logical sectors. Refuse a transport with 4 KiB logical
        // blocks rather than applying sector 0/6 ordering to the wrong bytes.
        guard deviceGeometry.logicalBlockByteCount == 512,
              slotA.endBlock <= deviceGeometry.logicalBlockCount,
              slotB.endBlock <= deviceGeometry.logicalBlockCount
        else { return nil }
        return BootSlotLayout(
            slotA: slotA,
            slotB: slotB,
            mediaLayoutFingerprint: mediaLayoutFingerprint,
            writePolicy: writePolicy
        )
    }
}
