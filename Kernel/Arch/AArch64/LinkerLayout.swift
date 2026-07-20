struct LinkerRegion: Equatable {
    let start: UInt64
    let end: UInt64

    var length: UInt64 {
        end >= start ? end - start : 0
    }
}

enum KernelLinkerLayout {
    static let maximumUserStackCount = 5
    static let maximumThreadContextCount = maximumUserStackCount

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

    /// Returns one physical linker-owned stack backing. The first two linker
    /// symbols establish the stride; subsequent stacks remain an indexed part
    /// of the same contiguous section rather than becoming public one-off
    /// symbols.
    static func userStack(at index: Int) -> LinkerRegion? {
        guard index >= 0, index < maximumUserStackCount else { return nil }
        let first = userStack0
        let second = userStack1
        let stackLength = first.length
        guard stackLength > 0,
              second.start == first.end,
              second.length == stackLength,
              UInt64(maximumUserStackCount) <= UInt64.max / stackLength
        else {
            return nil
        }
        let completeLength = UInt64(maximumUserStackCount) * stackLength
        guard completeLength <= UInt64.max - first.start,
              first.start + completeLength == threadContexts.start
        else {
            return nil
        }
        let stackIndex = UInt64(index)
        guard stackIndex <= (UInt64.max - first.start) / stackLength else {
            return nil
        }
        let start = first.start + stackIndex * stackLength
        guard stackLength <= UInt64.max - start else { return nil }
        return LinkerRegion(start: start, end: start + stackLength)
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

    /// Returns a stored thread frame without embedding the architecture frame
    /// size in the linker facade. The caller supplies its current ABI size;
    /// the complete five-frame plus launch-scratch span is validated before an
    /// address is exposed.
    static func threadContextAddress(
        at index: Int,
        frameByteCount: Int
    ) -> UInt64? {
        guard index >= 0,
              index < maximumThreadContextCount,
              let frameSize = validatedThreadContextFrameSize(frameByteCount)
        else {
            return nil
        }
        return threadContextAddress(
            slot: UInt64(index),
            frameSize: frameSize
        )
    }

    static func launchScratchContextAddress(
        frameByteCount: Int
    ) -> UInt64? {
        guard let frameSize = validatedThreadContextFrameSize(frameByteCount)
        else {
            return nil
        }
        return threadContextAddress(
            slot: UInt64(maximumThreadContextCount),
            frameSize: frameSize
        )
    }

    private static func validatedThreadContextFrameSize(
        _ frameByteCount: Int
    ) -> UInt64? {
        guard frameByteCount > 0 else { return nil }
        let frameSize = UInt64(frameByteCount)
        let slotCount = UInt64(maximumThreadContextCount + 1)
        guard frameSize & 0xf == 0,
              frameSize <= UInt64.max / slotCount,
              frameSize * slotCount <= threadContexts.length
        else {
            return nil
        }
        return frameSize
    }

    private static func threadContextAddress(
        slot: UInt64,
        frameSize: UInt64
    ) -> UInt64? {
        let contexts = threadContexts
        guard slot <= UInt64.max / frameSize else { return nil }
        let offset = slot * frameSize
        guard offset <= UInt64.max - contexts.start else { return nil }
        return contexts.start + offset
    }

    static var schedulerThreads: UInt64 { archSchedulerThreadsStart() }
    static var schedulerCurrentIndices: UInt64 { archSchedulerCurrentIndices() }
    static var memoryMapStorage: UInt64 { archMemoryMapStorage() }
    static var pageAllocatorStorage: UInt64 { archPageAllocatorStorage() }
    static var classifiedFreeRunStorage: LinkerRegion {
        LinkerRegion(
            start: archClassifiedFreeRunStorage(),
            end: archClassifiedFreeRunStorageEnd()
        )
    }
    static var classifiedAllocationLedgerStorage: LinkerRegion {
        LinkerRegion(
            start: archClassifiedAllocationLedgerStorage(),
            end: archClassifiedAllocationLedgerStorageEnd()
        )
    }
    static var smpTopologyStorage: UInt64 { archSMPTopologyStorage() }
    static var smpTargetStorage: UInt64 { archSMPTargetStorage() }
    static var smpStateStorage: UInt64 { archSMPStateStorage() }
    static var smpReportStorage: UInt64 { archSMPReportStorage() }
    static var smpWorkThreadStorage: UInt64 { archSMPWorkThreadStorage() }
    static var smpWorkIndexStorage: UInt64 { archSMPWorkIndexStorage() }
    static var smpWorkContextStorage: UInt64 { archSMPWorkContextStorage() }
    static var smpWorkResultStorage: UInt64 { archSMPWorkResultStorage() }
    static var smpWorkStateStorage: UInt64 { archSMPWorkStateStorage() }
    static var smpWorkStackStorage: UInt64 { archSMPWorkStackStorage() }
    static var smpWorkTimerTickStorage: UInt64 {
        archSMPWorkTimerTickStorage()
    }
    static var pagingLayoutStorage: LinkerRegion {
        LinkerRegion(
            start: archPagingLayoutStorage(),
            end: archPagingLayoutStorageEnd()
        )
    }
    static var debugLogStorage: LinkerRegion {
        LinkerRegion(
            start: archDebugLogStorageStart(),
            end: archDebugLogStorageEnd()
        )
    }
    static var rp1GEMWorkspace: LinkerRegion {
        LinkerRegion(
            start: archRP1GEMWorkspaceStart(),
            end: archRP1GEMWorkspaceEnd()
        )
    }
    static var rp1GEMDescriptorPage: LinkerRegion {
        LinkerRegion(
            start: archRP1GEMDescriptorPageStart(),
            end: archRP1GEMDescriptorPageEnd()
        )
    }
    static var rp1GEMCacheablePages: LinkerRegion {
        LinkerRegion(
            start: archRP1GEMCacheablePagesStart(),
            end: archRP1GEMCacheablePagesEnd()
        )
    }
    static var storageScratch: LinkerRegion {
        LinkerRegion(
            start: archStorageScratchStart(),
            end: archStorageScratchEnd()
        )
    }
    static var userEntryPhysicalAddress: UInt64 { archUserEntryPhysical() }
}

extension AArch64 {
    static func installTranslationTable(
        rootPhysicalAddress: UInt64,
        addressSpaceIdentifier: UInt16
    ) {
        archInstallTTBR0(
            rootPhysicalAddress | UInt64(addressSpaceIdentifier) << 56
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
@_silgen_name("arch_classified_free_run_storage")
private func archClassifiedFreeRunStorage() -> UInt64
@_silgen_name("arch_classified_free_run_storage_end")
private func archClassifiedFreeRunStorageEnd() -> UInt64
@_silgen_name("arch_classified_allocation_ledger_storage")
private func archClassifiedAllocationLedgerStorage() -> UInt64
@_silgen_name("arch_classified_allocation_ledger_storage_end")
private func archClassifiedAllocationLedgerStorageEnd() -> UInt64
@_silgen_name("arch_smp_topology_storage") private func archSMPTopologyStorage() -> UInt64
@_silgen_name("arch_smp_target_storage") private func archSMPTargetStorage() -> UInt64
@_silgen_name("arch_smp_state_storage") private func archSMPStateStorage() -> UInt64
@_silgen_name("arch_smp_report_storage") private func archSMPReportStorage() -> UInt64
@_silgen_name("arch_smp_work_thread_storage")
private func archSMPWorkThreadStorage() -> UInt64
@_silgen_name("arch_smp_work_index_storage")
private func archSMPWorkIndexStorage() -> UInt64
@_silgen_name("arch_smp_work_context_storage")
private func archSMPWorkContextStorage() -> UInt64
@_silgen_name("arch_smp_work_result_storage")
private func archSMPWorkResultStorage() -> UInt64
@_silgen_name("arch_smp_work_state_storage")
private func archSMPWorkStateStorage() -> UInt64
@_silgen_name("arch_smp_work_stack_storage")
private func archSMPWorkStackStorage() -> UInt64
@_silgen_name("arch_smp_work_timer_tick_storage")
private func archSMPWorkTimerTickStorage() -> UInt64
@_silgen_name("arch_paging_layout_storage") private func archPagingLayoutStorage() -> UInt64
@_silgen_name("arch_paging_layout_storage_end") private func archPagingLayoutStorageEnd() -> UInt64
@_silgen_name("arch_debug_log_storage_start") private func archDebugLogStorageStart() -> UInt64
@_silgen_name("arch_debug_log_storage_end") private func archDebugLogStorageEnd() -> UInt64
@_silgen_name("arch_rp1_gem_workspace_start")
private func archRP1GEMWorkspaceStart() -> UInt64
@_silgen_name("arch_rp1_gem_workspace_end")
private func archRP1GEMWorkspaceEnd() -> UInt64
@_silgen_name("arch_rp1_gem_descriptor_page_start")
private func archRP1GEMDescriptorPageStart() -> UInt64
@_silgen_name("arch_rp1_gem_descriptor_page_end")
private func archRP1GEMDescriptorPageEnd() -> UInt64
@_silgen_name("arch_rp1_gem_cacheable_pages_start")
private func archRP1GEMCacheablePagesStart() -> UInt64
@_silgen_name("arch_rp1_gem_cacheable_pages_end")
private func archRP1GEMCacheablePagesEnd() -> UInt64
@_silgen_name("arch_storage_scratch_start")
private func archStorageScratchStart() -> UInt64
@_silgen_name("arch_storage_scratch_end")
private func archStorageScratchEnd() -> UInt64
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
