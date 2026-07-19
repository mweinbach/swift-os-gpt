/// The configured display path retained by the monitor. Rendering targets the
/// same linear Swift surface for every backend; only presentation differs.
enum ActiveDisplayBackend {
    case memorySurface(mode: DisplayMode)
    case firmwareRAMFramebuffer(mode: DisplayMode)
    case platformFramebuffer(
        mode: DisplayMode,
        driver: SimpleFramebufferDisplayDriver
    )
    case virtIOGPU(mode: DisplayMode, driver: VirtIOGPU)

    var kind: DisplayBackendKind {
        switch self {
        case .memorySurface:
            return .memorySurface
        case .firmwareRAMFramebuffer:
            return .firmwareRAMFramebuffer
        case .platformFramebuffer:
            return .platformFramebuffer
        case .virtIOGPU:
            return .virtIOGPU
        }
    }

    var mode: DisplayMode {
        switch self {
        case .memorySurface(let mode),
             .firmwareRAMFramebuffer(let mode),
             .platformFramebuffer(let mode, _),
             .virtIOGPU(let mode, _):
            return mode
        }
    }

    mutating func present(_ damage: DamageRectangle) -> Bool {
        switch self {
        case .memorySurface, .firmwareRAMFramebuffer:
            // A memory surface has no scanout, while QEMU ramfb continuously
            // scans coherent guest RAM. In both cases presentation is the
            // ordering point before a remote display transport reads pixels.
            AArch64.synchronizeData()
            return true
        case .platformFramebuffer(let mode, let driver):
            let succeeded = driver.present(damage)
            self = .platformFramebuffer(mode: mode, driver: driver)
            return succeeded
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
