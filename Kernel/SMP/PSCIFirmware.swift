/// One board-neutral boundary for PSCI calls. SMP startup and soft restart use
/// the same firmware conduit instead of duplicating HVC/SMC policy.
enum PSCIFirmware {
    static func call(
        conduit: PSCIConduit,
        functionID: UInt64,
        argument0: UInt64,
        argument1: UInt64 = 0,
        argument2: UInt64 = 0
    ) -> UInt64 {
        switch conduit {
        case .hypervisorCall:
            return archPSCIFirmwareHVC(
                functionID,
                argument0,
                argument1,
                argument2
            )
        case .secureMonitorCall:
            return archPSCIFirmwareSMC(
                functionID,
                argument0,
                argument1,
                argument2
            )
        }
    }

    static func affinityInfo(
        conduit: PSCIConduit,
        targetAffinity: UInt64
    ) -> PSCIAffinityInfoResult {
        PSCIAffinityInfoResult(
            rawRegisterValue: call(
                conduit: conduit,
                functionID: PSCIFunctionID.affinityInfo64,
                argument0: targetAffinity,
                argument1: 0
            )
        )
    }
}

@_silgen_name("arch_psci_hvc")
private func archPSCIFirmwareHVC(
    _ functionID: UInt64,
    _ argument0: UInt64,
    _ argument1: UInt64,
    _ argument2: UInt64
) -> UInt64

@_silgen_name("arch_psci_smc")
private func archPSCIFirmwareSMC(
    _ functionID: UInt64,
    _ argument0: UInt64,
    _ argument1: UInt64,
    _ argument2: UInt64
) -> UInt64
