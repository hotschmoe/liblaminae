//------------------------------------------------------------------------------
// Platform Types - Shared between kernel and user space
//
// This defines platform identification types used by:
// - Kernel platform detection (src/kernel/platform/platform.zig)
// - User containers via get_platform() syscall
//
// Values correspond to what get_platform() syscall returns.
//------------------------------------------------------------------------------

/// Supported platforms
///
/// Add new platforms here as we add support. The enum values must match
/// what the kernel's get_platform() syscall returns.
pub const PlatformType = enum(u64) {
    /// QEMU virt machine (default development target)
    qemu_virt = 0,
    /// Raspberry Pi 4 (BCM2711 SoC)
    bcm2711 = 1,
    /// Raspberry Pi 5 (BCM2712 SoC) - stub for future
    bcm2712 = 2,
    /// NVIDIA Jetson Nano (Tegra X1) - stub for future
    tegra_x1 = 3,
    /// Unknown platform (fallback)
    unknown = 4,

    /// Convert from syscall return value
    pub fn fromSyscall(value: u64) PlatformType {
        const max_valid = @intFromEnum(PlatformType.unknown);
        if (value > max_valid) return .unknown;
        return @enumFromInt(value);
    }

    /// Check if running on QEMU
    pub fn isQemu(self: PlatformType) bool {
        return self == .qemu_virt;
    }

    /// Check if running on Raspberry Pi 4
    pub fn isRpi4(self: PlatformType) bool {
        return self == .bcm2711;
    }

    /// Check if running on Raspberry Pi 5
    pub fn isRpi5(self: PlatformType) bool {
        return self == .bcm2712;
    }

    /// Check if running on real hardware (not emulated)
    pub fn isRealHardware(self: PlatformType) bool {
        return switch (self) {
            .bcm2711, .bcm2712, .tegra_x1 => true,
            .qemu_virt, .unknown => false,
        };
    }

    /// Get platform container binary name
    /// Used by lamina.zig to spawn the correct platform container
    pub fn getName(self: PlatformType) []const u8 {
        return switch (self) {
            .qemu_virt => "virt",
            .bcm2711 => "bcm2711",
            .bcm2712 => "bcm2712",
            .tegra_x1 => "tegra_x1",
            .unknown => "virt", // fallback to virt stub
        };
    }
};
