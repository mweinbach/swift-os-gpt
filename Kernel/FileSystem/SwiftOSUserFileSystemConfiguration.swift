/// Board-neutral identity and initial capacity policy for the primary durable
/// user filesystem. Transport runtimes may differ in discovery and media
/// layout, but `/Users` must not acquire a different on-disk identity merely
/// because it is reached through VirtIO or SDHCI.
enum SwiftOSUserFileSystemConfiguration {
    static let volumeIdentifier = VFSVolumeIdentifier(
        rawValue: 0x5357_4653_5553_4552
    )!
    static let initialNodeCapacity: UInt32 = 32
}
