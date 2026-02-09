//------------------------------------------------------------------------------
// Platform Table - Single Source of Truth for Platform Containers
//------------------------------------------------------------------------------
// Minimal table mapping DTB root compatible strings to platform container
// binaries. Platform containers self-discover their hardware via DTB probing.
//
// This table intentionally contains ONLY:
//   - name: Container binary name
//   - compatible: DTB root compatible string
//   - namespace: Service namespace for ns_register/ns_lookup
//
// Platform internals (mailbox discovery, clock IDs, power domains) stay
// inside each platform container. This keeps the central table minimal.
//
// Usage:
//   - lamina.zig: Lookup platform by DTB root compatible, spawn container
//   - Drivers: ns_lookup("platform.*") to find active platform
//   - gen_docs: Generate platform documentation
//
// To add a new platform:
//   1. Add entry to this table
//   2. Create user/platforms/<name>.zig
//   3. Done - lamina will spawn it automatically
//------------------------------------------------------------------------------

const std = @import("std");

//------------------------------------------------------------------------------
// Platform Entry Definition
//------------------------------------------------------------------------------

pub const PlatformEntry = struct {
    /// Container binary name (used for spawn lookup)
    name: []const u8,

    /// DTB root compatible string (matched against root "/" node)
    compatible: []const u8,

    /// Service namespace (platform containers register as this)
    namespace: []const u8,

    /// Human-readable description
    description: []const u8 = "",
};

//------------------------------------------------------------------------------
// Platform Table
//------------------------------------------------------------------------------

pub const table = [_]PlatformEntry{
    // QEMU virt machine - stub platform (all ops return OK immediately)
    .{
        .name = "virt",
        .compatible = "linux,dummy-virt",
        .namespace = "platform.virt",
        .description = "QEMU virt machine (stub platform, no-op operations)",
    },

    // Raspberry Pi 4 (BCM2711) - VideoCore mailbox for clock/power
    .{
        .name = "bcm2711",
        .compatible = "brcm,bcm2711",
        .namespace = "platform.bcm2711",
        .description = "Raspberry Pi 4 (VideoCore mailbox for clock/power)",
    },

    // Future: Raspberry Pi 5 (BCM2712)
    // .{
    //     .name = "bcm2712",
    //     .compatible = "brcm,bcm2712",
    //     .namespace = "platform.bcm2712",
    //     .description = "Raspberry Pi 5 (RP1 southbridge + VideoCore)",
    // },
};

//------------------------------------------------------------------------------
// Lookup Functions
//------------------------------------------------------------------------------

/// Lookup platform entry by DTB root compatible string
pub fn lookupByCompatible(compatible: []const u8) ?*const PlatformEntry {
    for (&table) |*entry| {
        if (std.mem.eql(u8, entry.compatible, compatible)) return entry;
    }
    return null;
}

/// Lookup platform entry by binary name
pub fn lookupByName(name: []const u8) ?*const PlatformEntry {
    for (&table) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Get all platform entries
pub fn all() []const PlatformEntry {
    return &table;
}

/// Get platform count
pub fn count() usize {
    return table.len;
}

//------------------------------------------------------------------------------
// Comptime Validation
//------------------------------------------------------------------------------

comptime {
    // No duplicate compatible strings
    for (table, 0..) |entry, i| {
        for (table[i + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.compatible, other.compatible)) {
                @compileError("Duplicate platform compatible: " ++ entry.compatible);
            }
        }
    }

    // No duplicate names
    for (table, 0..) |entry, i| {
        for (table[i + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.name, other.name)) {
                @compileError("Duplicate platform name: " ++ entry.name);
            }
        }
    }

    // All namespaces must start with "platform."
    const prefix = "platform.";
    for (table) |entry| {
        if (!std.mem.startsWith(u8, entry.namespace, prefix)) {
            @compileError("Platform namespace must start with 'platform.': " ++ entry.namespace);
        }
    }
}
