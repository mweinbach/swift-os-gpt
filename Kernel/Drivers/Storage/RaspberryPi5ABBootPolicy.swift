enum RaspberryPi5ABFailureDisposition: UInt8, Equatable {
    /// No effect occurred; another cooperative pass may retry the shared owner.
    case retry
    /// Remove A/B write authority for this boot while allowing the confirmed
    /// payload or diagnostic recovery environment to use signed data normally.
    case disableAndContinue
    /// A peer/candidate operation failed while the persistent selector still
    /// names the confirmed slot. Leave journal state resumable on a later boot.
    case suspendAndContinue
    /// Durability or selector state is uncertain. No further SD alias may run
    /// before a controlled default reset.
    case quarantineAndReset
}

/// Physical-board failure policy kept separate from the board-neutral update
/// executor. It decides whether the Pi storage owner may safely publish its
/// filesystem/log aliases after an A/B error; it never performs I/O itself.
enum RaspberryPi5ABBootPolicy {
    static func disposition(
        for failure: BootUpdateRuntimeExecutorFailure,
        context: BootUpdateRuntimeBootContext
    ) -> RaspberryPi5ABFailureDisposition {
        switch failure {
        case .mediaLeaseUnavailable:
            return .retry
        case .candidateStageFailed, .candidateVerificationFailed,
             .peerMirrorFailed, .peerMirrorVerificationFailed,
             .selectorCommitRejectedBeforeWrite:
            return .suspendAndContinue
        case .journalCommitFailed, .durabilityRecoveryRequired,
             .selectorCommitDurabilityUncertain:
            return .quarantineAndReset
        case .recoverySelectorRepairFailed:
            // Remaining in the immutable rescue environment is safer than a
            // reset loop when its selector cannot be validated or repaired.
            return .disableAndContinue
        case .journalUnavailable:
            if case .payload(let observation) = context,
               observation.wasTryBoot {
                return .quarantineAndReset
            }
            return .disableAndContinue
        case .orchestrator(.recoveryNotAuthorized):
            return .disableAndContinue
        case .orchestrator:
            if case .payload(let observation) = context,
               observation.wasTryBoot {
                return .quarantineAndReset
            }
            return .disableAndContinue
        case .bootRecoveryRequired, .recoveryEnvironmentRequired:
            return .quarantineAndReset
        }
    }
}
