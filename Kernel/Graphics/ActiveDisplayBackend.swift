/// The configured display path retained by the monitor. Rendering targets the
/// same linear Swift surface for every backend; only presentation differs.
enum ActiveDisplayBackend {
    case firmwareRAMFramebuffer(mode: DisplayMode)
    case virtIOGPU(mode: DisplayMode, driver: VirtIOGPU)

    var kind: DisplayBackendKind {
        switch self {
        case .firmwareRAMFramebuffer:
            return .firmwareRAMFramebuffer
        case .virtIOGPU:
            return .virtIOGPU
        }
    }

    var mode: DisplayMode {
        switch self {
        case .firmwareRAMFramebuffer(let mode),
             .virtIOGPU(let mode, _):
            return mode
        }
    }

    mutating func present(_ damage: DamageRectangle) -> Bool {
        switch self {
        case .firmwareRAMFramebuffer:
            // QEMU ramfb continuously scans coherent guest RAM.
            AArch64.synchronizeData()
            return true
        case .virtIOGPU(let mode, var driver):
            let succeeded = driver.present(damage)
            self = .virtIOGPU(mode: mode, driver: driver)
            return succeeded
        }
    }

    mutating func presentFullFrame() -> Bool {
        present(DamageRectangle.fullMode(mode))
    }
}
