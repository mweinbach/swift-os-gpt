struct LinkerRegion: Equatable {
    let start: UInt64
    let end: UInt64

    var length: UInt64 {
        end >= start ? end - start : 0
    }
}

enum KernelLinkerLayout {
    static var kernelImage: LinkerRegion {
        LinkerRegion(start: archKernelStart(), end: archKernelEnd())
    }

    static var kernelText: LinkerRegion {
        LinkerRegion(start: archKernelTextStart(), end: archKernelTextEnd())
    }

    static var kernelReadOnlyData: LinkerRegion {
        LinkerRegion(start: archKernelRODataStart(), end: archKernelRODataEnd())
    }

    static var kernelData: LinkerRegion {
        LinkerRegion(start: archKernelDataStart(), end: archKernelDataEnd())
    }

    static var userText: LinkerRegion {
        LinkerRegion(start: archUserTextStart(), end: archUserTextEnd())
    }

    static var userReadOnlyData: LinkerRegion {
        LinkerRegion(start: archUserRODataStart(), end: archUserRODataEnd())
    }

    static var bootStack: LinkerRegion {
        LinkerRegion(start: archBootStackBottom(), end: archBootStackTop())
    }

    static var secondaryStacks: LinkerRegion {
        LinkerRegion(start: archSecondaryStacksStart(), end: archSecondaryStacksEnd())
    }

    static var userStack0: LinkerRegion {
        LinkerRegion(start: archUserStack0Start(), end: archUserStack0End())
    }

    static var userStack1: LinkerRegion {
        LinkerRegion(start: archUserStack1Start(), end: archUserStack1End())
    }

    static var finalLevel1Table: LinkerRegion {
        LinkerRegion(start: archFinalL1Start(), end: archFinalL1End())
    }

    static var finalLevel2Tables: LinkerRegion {
        LinkerRegion(start: archFinalL2Start(), end: archFinalL2End())
    }

    static var finalLevel3Tables: LinkerRegion {
        LinkerRegion(start: archFinalL3Start(), end: archFinalL3End())
    }

    static var threadContexts: LinkerRegion {
        LinkerRegion(start: archThreadContextsStart(), end: archThreadContextsEnd())
    }

    static var schedulerThreads: UInt64 { archSchedulerThreadsStart() }
    static var schedulerCurrentIndices: UInt64 { archSchedulerCurrentIndices() }
    static var memoryMapStorage: UInt64 { archMemoryMapStorage() }
    static var pageAllocatorStorage: UInt64 { archPageAllocatorStorage() }
    static var smpTopologyStorage: UInt64 { archSMPTopologyStorage() }
    static var smpTargetStorage: UInt64 { archSMPTargetStorage() }
    static var smpStateStorage: UInt64 { archSMPStateStorage() }
    static var smpReportStorage: UInt64 { archSMPReportStorage() }
    static var userEntryPhysicalAddress: UInt64 { archUserEntryPhysical() }
}

extension AArch64 {
    static func installTranslationTable(
        rootPhysicalAddress: UInt64,
        addressSpaceIdentifier: UInt16
    ) {
        archInstallTTBR0(
            rootPhysicalAddress | UInt64(addressSpaceIdentifier) << 48
        )
    }

    static var translationTableBase: UInt64 {
        archCurrentTTBR0()
    }

    static var secondaryEntryPhysicalAddress: UInt64 {
        archSecondaryEntryAddress()
    }

    static func enterEL0(
        entryAddress: UInt64,
        stackPointer: UInt64,
        argument: UInt64,
        threadPointer: UInt64
    ) -> Never {
        archEnterEL0(entryAddress, stackPointer, argument, threadPointer)
    }
}

@_silgen_name("arch_kernel_start") private func archKernelStart() -> UInt64
@_silgen_name("arch_kernel_end") private func archKernelEnd() -> UInt64
@_silgen_name("arch_kernel_text_start") private func archKernelTextStart() -> UInt64
@_silgen_name("arch_kernel_text_end") private func archKernelTextEnd() -> UInt64
@_silgen_name("arch_kernel_rodata_start") private func archKernelRODataStart() -> UInt64
@_silgen_name("arch_kernel_rodata_end") private func archKernelRODataEnd() -> UInt64
@_silgen_name("arch_kernel_data_start") private func archKernelDataStart() -> UInt64
@_silgen_name("arch_kernel_data_end") private func archKernelDataEnd() -> UInt64
@_silgen_name("arch_user_text_start") private func archUserTextStart() -> UInt64
@_silgen_name("arch_user_text_end") private func archUserTextEnd() -> UInt64
@_silgen_name("arch_user_rodata_start") private func archUserRODataStart() -> UInt64
@_silgen_name("arch_user_rodata_end") private func archUserRODataEnd() -> UInt64
@_silgen_name("arch_boot_stack_bottom") private func archBootStackBottom() -> UInt64
@_silgen_name("arch_boot_stack_top") private func archBootStackTop() -> UInt64
@_silgen_name("arch_secondary_stacks_start") private func archSecondaryStacksStart() -> UInt64
@_silgen_name("arch_secondary_stacks_end") private func archSecondaryStacksEnd() -> UInt64
@_silgen_name("arch_user_stack0_start") private func archUserStack0Start() -> UInt64
@_silgen_name("arch_user_stack0_end") private func archUserStack0End() -> UInt64
@_silgen_name("arch_user_stack1_start") private func archUserStack1Start() -> UInt64
@_silgen_name("arch_user_stack1_end") private func archUserStack1End() -> UInt64
@_silgen_name("arch_final_l1_start") private func archFinalL1Start() -> UInt64
@_silgen_name("arch_final_l1_end") private func archFinalL1End() -> UInt64
@_silgen_name("arch_final_l2_start") private func archFinalL2Start() -> UInt64
@_silgen_name("arch_final_l2_end") private func archFinalL2End() -> UInt64
@_silgen_name("arch_final_l3_start") private func archFinalL3Start() -> UInt64
@_silgen_name("arch_final_l3_end") private func archFinalL3End() -> UInt64
@_silgen_name("arch_thread_contexts_start") private func archThreadContextsStart() -> UInt64
@_silgen_name("arch_thread_contexts_end") private func archThreadContextsEnd() -> UInt64
@_silgen_name("arch_scheduler_threads_start") private func archSchedulerThreadsStart() -> UInt64
@_silgen_name("arch_scheduler_current_indices") private func archSchedulerCurrentIndices() -> UInt64
@_silgen_name("arch_memory_map_storage") private func archMemoryMapStorage() -> UInt64
@_silgen_name("arch_page_allocator_storage") private func archPageAllocatorStorage() -> UInt64
@_silgen_name("arch_smp_topology_storage") private func archSMPTopologyStorage() -> UInt64
@_silgen_name("arch_smp_target_storage") private func archSMPTargetStorage() -> UInt64
@_silgen_name("arch_smp_state_storage") private func archSMPStateStorage() -> UInt64
@_silgen_name("arch_smp_report_storage") private func archSMPReportStorage() -> UInt64
@_silgen_name("arch_user_entry_physical") private func archUserEntryPhysical() -> UInt64
@_silgen_name("arch_secondary_entry_address") private func archSecondaryEntryAddress() -> UInt64
@_silgen_name("arch_install_ttbr0") private func archInstallTTBR0(_ value: UInt64)
@_silgen_name("arch_current_ttbr0") private func archCurrentTTBR0() -> UInt64
@_silgen_name("arch_enter_el0")
private func archEnterEL0(
    _ entryAddress: UInt64,
    _ stackPointer: UInt64,
    _ argument: UInt64,
    _ threadPointer: UInt64
) -> Never
