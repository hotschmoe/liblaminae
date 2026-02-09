/// EL0-Safe Memory Barrier Operations for ARMv8-A
///
/// This module provides memory barrier operations that are safe to execute
/// from EL0 (user-space). These are the subset of barriers from
/// src/arch/aarch64/common/barriers.zig that do not require kernel privilege.
///
/// SOURCE OF TRUTH: This file is copied to lib/shared/arch/ by gen-lib.
/// Do not edit lib/shared/arch/barriers_el0.zig directly.
///
/// Barrier Scopes:
/// - sy (system): Full system scope, affects all observers
/// - ish (inner shareable): Affects all cores in the same inner shareable domain
/// - osh (outer shareable): Affects cores in the outer shareable domain
/// - nsh (non-shareable): Affects only the executing core

/// Data memory barrier - system scope
/// Ensures all memory accesses before the barrier complete before memory accesses after it
pub fn dataMemoryBarrier() void {
    asm volatile ("dmb sy");
}

/// Data memory barrier - inner shareable
pub fn dataMemoryBarrierInner() void {
    asm volatile ("dmb ish");
}

/// Data memory barrier - outer shareable
pub fn dataMemoryBarrierOuter() void {
    asm volatile ("dmb osh");
}

/// Data memory barrier - non-shareable
pub fn dataMemoryBarrierNonShareable() void {
    asm volatile ("dmb nsh");
}

/// Data sync barrier - system scope
/// More strict than DMB - waits for all operations to complete
pub fn dataSyncBarrier() void {
    asm volatile ("dsb sy");
}

/// Data sync barrier - inner shareable
pub fn dataSyncBarrierInner() void {
    asm volatile ("dsb ish");
}

/// Data sync barrier - outer shareable
pub fn dataSyncBarrierOuter() void {
    asm volatile ("dsb osh");
}

/// Data sync barrier - non-shareable
pub fn dataSyncBarrierNonShareable() void {
    asm volatile ("dsb nsh");
}

/// Instruction barrier
/// Flushes the pipeline and ensures all previous instructions are visible
pub fn instructionBarrier() void {
    asm volatile ("isb sy");
}

/// Full system barrier (DSB + ISB)
/// Use when enabling/disabling major subsystems or changing system state
pub fn systemBarrier() void {
    dataSyncBarrier();
    instructionBarrier();
}

/// Full barrier with memory clobber - use for critical sections
/// Ensures all stores are visible system-wide before continuing.
pub inline fn fullBarrierWithClobber() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Store-only barrier for page table writes before TLBI
/// DSB ISHST ensures all page table stores complete before TLBI is issued.
pub inline fn storeBarrierInner() void {
    asm volatile ("dsb ishst" ::: .{ .memory = true });
}

/// Load-store barrier for inner shareable domain with memory clobber
/// Use after TLBI to ensure invalidation completes before memory access.
pub inline fn loadStoreBarrierInner() void {
    asm volatile ("dsb ish" ::: .{ .memory = true });
}

/// Barrier sequence for after TLBI operations
pub inline fn afterTlbiBarrier() void {
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Return barrier - ensures all stores are visible before function return.
/// Critical for inline functions returning pointers.
pub inline fn returnBarrier() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

// Convenience aliases
pub const data = dataMemoryBarrier;
pub const sync = systemBarrier;
