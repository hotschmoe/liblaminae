//------------------------------------------------------------------------------
// Platform Types - Shared between kernel and user space
//
// This defines platform identification types used by:
// - Kernel platform detection (src/kernel/platform/platform.zig)
// - User containers via get_platform() syscall
//
// Values correspond to what get_platform() syscall returns.
//
// HISTORICAL NOTE: bcm2711 / bcm2712 / tegra_x1 enum members were removed
// in 2026-05 with the BCM2711 -> Minisforum MS-R1 platform migration.
// See docs/roadmap/PLATFORM_MIGRATION.md.
//------------------------------------------------------------------------------

/// Supported platforms.
///
/// Add new platforms here as we add support. Enum values are part of the
/// get_platform() syscall ABI -- existing values must not be reassigned.
/// `unknown` keeps its original value (4) so the ABI is stable across the
/// 2026-05 enum reduction.
pub const PlatformType = enum(u64) {
    /// QEMU virt machine (default development target)
    qemu_virt = 0,
    /// Minisforum MS-R1 (CIX CP8180). Real-hardware target; v1.0 goal.
    /// Bring-up scaffolding only at the user-container level today;
    /// kernel-side (GICv3, SCMI, EFI memmap) lands in Phase 3.
    ms_r1 = 1,
    /// Unknown platform (fallback). Preserved at 4 for ABI stability across
    /// the BCM2711/BCM2712/Tegra enum-removal migration.
    unknown = 4,

    /// Convert from syscall return value
    pub fn fromSyscall(value: u64) PlatformType {
        return switch (value) {
            0 => .qemu_virt,
            1 => .ms_r1,
            else => .unknown,
        };
    }

    /// Check if running on QEMU
    pub fn isQemu(self: PlatformType) bool {
        return self == .qemu_virt;
    }

    /// Check if running on real hardware (not emulated).
    pub fn isRealHardware(self: PlatformType) bool {
        return switch (self) {
            .ms_r1 => true,
            .qemu_virt, .unknown => false,
        };
    }

    /// Get platform container binary name.
    /// Used by lamina.zig to spawn the correct platform container.
    pub fn getName(self: PlatformType) []const u8 {
        return switch (self) {
            .qemu_virt => "virt",
            .ms_r1 => "ms_r1",
            .unknown => "virt", // fallback to virt stub
        };
    }
};
