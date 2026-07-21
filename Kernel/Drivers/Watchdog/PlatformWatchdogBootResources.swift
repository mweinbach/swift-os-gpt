/// Retains the exact watchdog MMIO page across final page-table activation.
/// Mapping the DT-validated aperture performs no register access: a tryboot
/// candidate adopts it after activation, while any other boot may use it only
/// after update policy reaches an explicit no-return reset boundary.
enum PlatformWatchdogBootResources {
    static func appendDiscoveredResources(
        platform: Platform,
        to resources: inout BootDriverResourceSet
    ) -> Bool {
        guard let watchdog = platform.systemWatchdog else { return true }
        switch watchdog {
        case .bcm2712PM(let registers):
            return resources.append(mmio: registers)
        }
    }
}
