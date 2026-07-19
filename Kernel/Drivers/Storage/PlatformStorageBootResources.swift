/// Retains only the MMIO required by the selected physical storage transport.
/// BCM2712 publishes host and configuration windows in one page, so that exact
/// pinned layout becomes one page-table input. A future tree may describe
/// disjoint pages; those are retained independently and an untrusted gap is
/// never pulled into the Device mapping. The AON GPIO bank remains separate.
enum PlatformStorageBootResources {
    static func appendDiscoveredResources(
        platform: Platform,
        to resources: inout BootDriverResourceSet
    ) -> Bool {
        guard let description = platform.systemStorageDevice else {
            return true
        }
        return append(description: description, to: &resources)
    }

    static func append(
        description: PlatformStorageDeviceDescription,
        to resources: inout BootDriverResourceSet
    ) -> Bool {
        guard description.controller == .bcm2712SDHCI else {
            return false
        }

        // Build transactionally: failure must not leave half of a controller
        // retained in the caller's final page-table plan.
        var planned = resources
        guard appendControllerResources(
                  host: description.hostRegisters,
                  configuration: description.configurationRegisters,
                  to: &planned
              ), planned.append(mmio: description.power.gpioRegisters)
        else { return false }
        resources = planned
        return true
    }

    private static func appendControllerResources(
        host: DeviceResource,
        configuration: DeviceResource,
        to resources: inout BootDriverResourceSet
    ) -> Bool {
        guard let hostPages = normalizedPages(for: host),
              let configurationPages = normalizedPages(for: configuration)
        else { return false }

        if hostPages.baseAddress == configurationPages.baseAddress,
           hostPages.length == MemoryPageGeometry.pageSize,
           configurationPages.length == MemoryPageGeometry.pageSize {
            return resources.append(mmio: hostPages)
        }

        // Page-overlapping but non-identical intervals cannot be expressed as
        // two disjoint BootDriverResourceSet entries. Reject instead of
        // silently broadening either firmware-described aperture.
        guard hostPages.baseAddress + hostPages.length
                  <= configurationPages.baseAddress
                || configurationPages.baseAddress
                  + configurationPages.length <= hostPages.baseAddress,
              resources.append(mmio: hostPages),
              resources.append(mmio: configurationPages)
        else { return false }
        return true
    }

    private static func normalizedPages(
        for resource: DeviceResource
    ) -> DeviceResource? {
        guard resource.length > 0,
              resource.length <= UInt64.max - resource.baseAddress,
              let end = MemoryPageGeometry.alignUp(
                  resource.baseAddress + resource.length
              )
        else { return nil }
        let base = MemoryPageGeometry.alignDown(resource.baseAddress)
        guard end > base else { return nil }
        return DeviceResource(baseAddress: base, length: end - base)
    }
}
