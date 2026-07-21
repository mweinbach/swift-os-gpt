/// Retains the exact watchdog MMIO page across final page-table activation.
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
