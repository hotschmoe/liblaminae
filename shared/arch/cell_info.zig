/// Cell Info - Zero-syscall cell information retrieval
///
/// The kernel sets TPIDRRO_EL0 on context switch, allowing EL0 to read
/// the current cell's ID with a single MRS instruction.
///
/// SOURCE OF TRUTH: This file is copied to lib/shared/arch/ by gen-lib.
/// Do not edit lib/shared/arch/cell_info.zig directly.
///
/// This is safe at both EL0 and EL1 - TPIDRRO_EL0 is readable from any
/// exception level.
/// Get the current cell's ID without a syscall.
///
/// The kernel sets TPIDRRO_EL0 on context switch, so this is a single
/// MRS instruction with no privilege transition.
pub inline fn getCellId() u16 {
    return @truncate(asm volatile ("mrs %[id], tpidrro_el0"
        : [id] "=r" (-> u64),
    ));
}
