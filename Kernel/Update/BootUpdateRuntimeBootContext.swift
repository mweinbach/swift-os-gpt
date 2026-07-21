/// Typed platform-discovery result used to separate ordinary payload update
/// authority from the single recovery-environment selector repair. Board code
/// must derive this from authoritative firmware/boot metadata rather than from
/// journal intent or selector contents.
enum BootUpdateRuntimeBootContext: Equatable {
    case recovery
    case payload(PlatformBootObservation)
    case unsupported
}
