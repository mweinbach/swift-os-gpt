/// Authoritative logical-slot identity derived from firmware's runtime FDT.
/// Update policy must not infer this from a journal or selector contents: both
/// can describe intent while the CPU is actually running another partition.
struct PlatformBootObservation: Equatable {
    let slot: BootSlot
    let wasTryBoot: Bool
    let trialCapability: PlatformTrialBootCapability
}

/// Diagnostic classification of the firmware partition that entered SwiftOS.
/// Only `.payload` carries A/B update authority; a rescue or unknown context is
/// deliberately observable without being convertible to a writable slot.
enum PlatformFirmwareBootContext: Equatable {
    case rescue
    case payload(PlatformBootObservation)
    case unsupportedPartition(UInt32)
}

enum RaspberryPiBootObservationDiscovery {
    static func context(
        from selection: FirmwareBootSelection
    ) -> PlatformFirmwareBootContext {
        let slot: BootSlot
        switch selection.partitionNumber {
        case 1: return .rescue
        case 2: slot = .a
        case 3: slot = .b
        default: return .unsupportedPartition(selection.partitionNumber)
        }
        let trialCapability: PlatformTrialBootCapability
        if let capabilities = selection.capabilities,
           capabilities.contains(.tryBootAB),
           capabilities.contains(.tryBoot) {
            trialCapability = .oneShotAlternateSlot
        } else {
            // Boot identity remains authoritative when capability evidence is
            // absent. Only the later one-shot trial authorization fails shut.
            trialCapability = .unavailable
        }
        return .payload(PlatformBootObservation(
            slot: slot,
            wasTryBoot: selection.wasTryBoot,
            trialCapability: trialCapability
        ))
    }
}

extension Platform {
    /// Typed diagnostic context for the exact firmware-reported partition.
    /// Partition one is the invariant rescue environment and never becomes an
    /// A/B payload slot or receives update-write authority.
    var firmwareBootContext: PlatformFirmwareBootContext? {
        guard kind == .raspberryPi5, let firmwareBootSelection else {
            return nil
        }
        return RaspberryPiBootObservationDiscovery.context(
            from: firmwareBootSelection
        )
    }

    /// Nil disables A/B commit authority but never prevents a normal boot.
    /// Static packaged DTBs do not contain the firmware-patched chosen data.
    var bootObservation: PlatformBootObservation? {
        guard case .payload(let observation) = firmwareBootContext else {
            return nil
        }
        return observation
    }
}
