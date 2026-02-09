/// EL0-Safe Idle/Wait Primitives for ARMv8-A
///
/// Provides CPU idle and inter-processor event operations that are safe
/// to execute from EL0 (user-space).
///
/// SOURCE OF TRUTH: This file is copied to lib/shared/arch/ by gen-lib.
/// Do not edit lib/shared/arch/idle_el0.zig directly.
///
/// NOTE: The kernel-only functions (haltLoop, panicHalt) are in
/// src/arch/aarch64/common/idle.zig and are NOT included here because
/// they require EL1+ privileges.
///
/// EL0 Safety:
/// - wfi: Safe at EL0 (may trap to EL1 depending on HCR_EL2.TWI)
/// - wfe: Safe at EL0 (may trap to EL1 depending on HCR_EL2.TWE)
/// - sev: Safe at EL0

/// Wait for interrupt - puts CPU in low-power state until interrupt
///
/// The CPU will halt execution until an IRQ, FIQ, or async abort occurs.
/// Upon waking, execution continues at the next instruction.
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}

/// Wait for event - waits for SEV signal from other CPUs
///
/// Lighter than WFI, used for spinlock contention. The CPU waits until:
/// - Another core executes SEV
/// - A global event is signaled
/// - An interrupt occurs
pub inline fn waitForEvent() void {
    asm volatile ("wfe");
}

/// Send event to all CPUs - wakes CPUs waiting in WFE
///
/// Signals all cores in the system that an event has occurred.
/// Use to wake cores that are spinning with waitForEvent().
pub inline fn sendEvent() void {
    asm volatile ("sev");
}
