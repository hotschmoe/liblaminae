//------------------------------------------------------------------------------
// CellType - Shared kernel/userspace cell classification
//
// SOURCE OF TRUTH: This file is copied to lib/shared/ by `zig build gen-lib`.
// Do not edit lib/shared/cell_type.zig directly.
//
// The enum tags must match what the kernel's spawn syscall expects in its
// `cell_type: u8` argument. The kernel's `CellTypeSpec` table
// (src/kernel/cell/table.zig) is keyed off this enum and lives kernel-side
// because it carries capability bitmasks, exception-level templates, and
// page-table policy -- none of which userspace needs to know.
//
// Userspace (lamina, build_config) uses the enum tags directly when asking the
// kernel to spawn a cell; the raw u8 sent over the syscall boundary is
// `@intFromEnum(CellType.<tag>)`.
//------------------------------------------------------------------------------

pub const CellType = enum(u8) {
    /// Regular user application -- minimal privileges.
    /// Cannot access hardware directly; all device access via syscalls.
    user = 0,

    /// Device driver -- hardware access capabilities.
    /// Can map MMIO, register IRQs, allocate DMA memory.
    /// Still runs at EL0 with capability-gated syscalls.
    driver = 1,

    /// Privileged init cell -- full capabilities.
    /// Has all capabilities including spawn/kill for cell management.
    /// Typically only one instance, but max_instances can be adjusted.
    /// Crash = system crash (not restartable by default).
    init = 2,

    /// Platform cell -- manages clocks/power/resets via platform hardware.
    /// Can map any MMIO in the platform peripheral range without an assigned
    /// device. Used by virt (today) and ms_r1 (planned) platform cells.
    platform = 3,

    /// Kernel test mode -- DEVELOPMENT ONLY.
    /// Runs at EL1h for testing scheduler without EL0 complexity.
    /// Will be removed post-Phase 6.
    kernel_test = 255,

    /// Human-readable name for logs and diagnostics.
    pub fn name(self: CellType) []const u8 {
        return switch (self) {
            .user => "user",
            .driver => "driver",
            .init => "init",
            .platform => "platform",
            .kernel_test => "kernel_test",
        };
    }
};
