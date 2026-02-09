//------------------------------------------------------------------------------
// Unified Compatibility Table
//------------------------------------------------------------------------------
// Single source of truth for all DTB compatible strings across kernel and
// lamina (userspace driver orchestrator).
//
// Usage:
// - Kernel drivers use this table for table-driven isCompatible()
// - Lamina uses this table to match devices to driver containers
// - gen-docs generates documentation from this table
// - Comptime validation ensures all supported entries have drivers
//
// To add new platform support:
// 1. Add entries here with appropriate class/handler/status
// 2. Use status = .planned until driver is implemented
// 3. Comptime validation will catch missing drivers for .supported entries
//------------------------------------------------------------------------------

const std = @import("std");

//------------------------------------------------------------------------------
// Core Enums
//------------------------------------------------------------------------------

/// Handler: Which component handles this device
pub const Handler = enum {
    kernel, // Handled by kernel driver at boot
    lamina, // Lamina spawns a driver container
};

/// Device class for grouping and driver matching
pub const Class = enum {
    interrupt_controller,
    timer,
    uart,
    network,
    block,
    gpio,
    rtc,
};

/// Execution container kind (mirrors kernel ContainerType numerics)
pub const ContainerKind = enum(u8) {
    user = 0,
    driver = 1,
    init = 2,
};

/// Support status for a compatible string
pub const Status = enum {
    supported,
    planned,
    unsupported,

    pub fn label(self: Status) []const u8 {
        return @tagName(self);
    }
};

//------------------------------------------------------------------------------
// Compatibility Entry
//------------------------------------------------------------------------------

/// Single compatibility entry that maps a DTB compatible string to a driver
pub const CompatEntry = struct {
    /// DTB compatible string (exact match)
    compatible: []const u8,

    /// Device class
    class: Class,

    /// Handler (kernel or lamina)
    handler: Handler,

    /// Driver binary name to spawn (null if kernel-handled or not yet implemented)
    driver_binary: ?[]const u8 = null,

    /// Container kind expected for the driver (only relevant for lamina handlers)
    container_kind: ContainerKind = .driver,

    /// Support status
    status: Status = .supported,

    /// Free-form notes (driver, quirks, roadmap)
    notes: []const u8 = "",
};

//------------------------------------------------------------------------------
// Unified Compatibility Table
//------------------------------------------------------------------------------

/// Unified compatibility table shared by kernel, lamina, and generators
pub const table = [_]CompatEntry{
    // =========================================================================
    // Kernel-handled: Interrupt Controllers
    // =========================================================================
    .{
        .compatible = "arm,cortex-a15-gic",
        .class = .interrupt_controller,
        .handler = .kernel,
        .status = .supported,
        .notes = "GICv2 (QEMU virt, BCM2711)",
    },
    .{
        .compatible = "arm,gic-400",
        .class = .interrupt_controller,
        .handler = .kernel,
        .status = .supported,
        .notes = "GICv2 (BCM2711)",
    },
    .{
        .compatible = "arm,gic-v3",
        .class = .interrupt_controller,
        .handler = .kernel,
        .status = .planned,
        .notes = "GICv3 (BCM2712, future)",
    },

    // =========================================================================
    // Kernel-handled: Timers
    // =========================================================================
    .{
        .compatible = "arm,armv8-timer",
        .class = .timer,
        .handler = .kernel,
        .status = .supported,
        .notes = "ARM Generic Timer",
    },
    .{
        .compatible = "arm,armv7-timer",
        .class = .timer,
        .handler = .kernel,
        .status = .supported,
        .notes = "ARM Generic Timer (v7 compat)",
    },

    // =========================================================================
    // Kernel-handled: UART (early boot)
    // =========================================================================
    .{
        .compatible = "arm,pl011",
        .class = .uart,
        .handler = .kernel,
        .status = .supported,
        .notes = "PL011 UART (QEMU virt, BCM2711)",
    },

    // =========================================================================
    // Lamina-handled: VirtIO
    // =========================================================================
    .{
        .compatible = "virtio,mmio,net",
        .class = .network,
        .handler = .lamina,
        .driver_binary = "netd",
        .container_kind = .driver,
        .status = .supported,
        .notes = "VirtIO-Net over MMIO (QEMU virt, bcm2712 virtio)",
    },
    .{
        .compatible = "virtio,mmio,block",
        .class = .block,
        .handler = .lamina,
        .driver_binary = "blkd",
        .container_kind = .driver,
        .status = .supported,
        .notes = "VirtIO-Block over MMIO",
    },

    // =========================================================================
    // Lamina-handled: BCM2711 GENET
    // =========================================================================
    // NOTE: Using pure-Zig driver
    // STATUS: Disabled pending TLB invalidation hang investigation (laminae-v3b5)
    // driver_binary = null prevents spawn while status = .planned
    .{
        .compatible = "brcm,bcm2711-genet-v5",
        .class = .network,
        .handler = .lamina,
        .driver_binary = null, // DISABLED: TLB hang during spawn (was: "genetd")
        .container_kind = .driver,
        .status = .planned,
        .notes = "BCM2711 GENET Ethernet (RPi4) - primary DTB compat",
    },
    .{
        .compatible = "brcm,genet-v5",
        .class = .network,
        .handler = .lamina,
        .driver_binary = null, // DISABLED: TLB hang during spawn (was: "genetd")
        .container_kind = .driver,
        .status = .planned,
        .notes = "BCM2711 GENET Ethernet (RPi4) - fallback compat string",
    },
};

//------------------------------------------------------------------------------
// Lookup Functions
//------------------------------------------------------------------------------

/// Lookup a compatibility entry by exact string
pub fn lookup(compatible: []const u8) ?*const CompatEntry {
    for (&table) |*entry| {
        if (std.mem.eql(u8, entry.compatible, compatible)) return entry;
    }
    return null;
}

/// Slice view of the table (for iteration)
pub fn all() []const CompatEntry {
    return &table;
}

/// Get compatible strings for a given class and handler (comptime)
pub fn getCompatStringsComptime(comptime class: Class, comptime handler: Handler) []const []const u8 {
    comptime var count: usize = 0;
    inline for (table) |entry| {
        if (entry.class == class and entry.handler == handler) count += 1;
    }

    comptime var result: [count][]const u8 = undefined;
    comptime var i: usize = 0;
    inline for (table) |entry| {
        if (entry.class == class and entry.handler == handler) {
            result[i] = entry.compatible;
            i += 1;
        }
    }
    return &result;
}

//------------------------------------------------------------------------------
// Comptime Validation
//------------------------------------------------------------------------------
// Runs at compile time to catch configuration errors.
// Ensures the table is self-consistent before any code runs.

comptime {
    // 1. No duplicate compatible strings
    for (table, 0..) |entry, i| {
        for (table[i + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.compatible, other.compatible)) {
                @compileError("Duplicate compat string: " ++ entry.compatible);
            }
        }
    }

    // 2. Lamina-handled entries with status=.supported MUST have driver_binary
    for (table) |entry| {
        if (entry.handler == .lamina and entry.status == .supported) {
            if (entry.driver_binary == null) {
                @compileError("Lamina-handled supported entry missing driver_binary: " ++ entry.compatible);
            }
        }
    }

    // 3. Kernel-handled entries should NOT have driver_binary (it would be ignored)
    for (table) |entry| {
        if (entry.handler == .kernel and entry.driver_binary != null) {
            @compileError("Kernel-handled entry has driver_binary (ignored): " ++ entry.compatible);
        }
    }
}

//------------------------------------------------------------------------------
// Self-Test (runtime, for debugging)
//------------------------------------------------------------------------------

/// Runtime self-test for invariants that can't be checked at comptime
/// (Currently all checks are comptime, so this just returns true)
pub fn selfTest() bool {
    return true;
}
