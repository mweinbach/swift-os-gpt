/// Adds only the exact MMIO apertures needed by a discovered network backend
/// to the final kernel address space. QEMU's VirtIO transports are already
/// covered by its aggregate transport window; physical boards instead retain
/// their typed controller, wrapper, clock, and GPIO resources here.
enum PlatformNetworkBootResources {
    static func appendDiscoveredResources(
        platform: Platform,
        to resources: inout BootDriverResourceSet
    ) -> Bool {
        guard let description = platform.networkDeviceCandidate(at: 0) else {
            return true
        }
        return append(description: description, to: &resources)
    }

    static func append(
        description: PlatformNetworkDeviceDescription,
        to resources: inout BootDriverResourceSet
    ) -> Bool {
        guard let boardResources = description.boardResources else {
            return true
        }
        switch boardResources {
        case .rp1GEM(let rp1):
            guard description.controller == .rp1GEM,
                  description.registers == rp1.gemRegisters,
                  resources.append(mmio: rp1.gemRegisters),
                  resources.append(
                      mmio: rp1.ethernetConfigurationRegisters
                  ),
                  resources.append(mmio: rp1.clocks.controllerRegisters)
            else {
                return false
            }
            guard let reset = rp1.phyReset else { return true }
            return resources.append(mmio: reset.gpioRegisters.ioBank)
                && resources.append(mmio: reset.gpioRegisters.rio)
                && resources.append(mmio: reset.gpioRegisters.padsBank)
        }
    }
}
