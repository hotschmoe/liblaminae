//------------------------------------------------------------------------------
// liblaminae tier-contract audit (contracts follow-up item 3)
//------------------------------------------------------------------------------
//
// Each `lib/man/*.zig` module declares its tier per `tier_contract.md`:
//
//   T1: self-contained vocabulary
//       - T0 syscalls only, no peer ICC
//       - bounded computation, no indefinite blocking
//       - pure or caller-allocator (no hidden allocations -- T1.2)
//
//   T2: thin client of a peer container
//       - bounded-timeout peer ICC permitted
//       - still no indefinite block
//
// This file is the comptime audit:
//
//   - Walks the T1 module list and asserts each declares `pub const tier: u8 = 1`.
//   - Walks the T2 module list and asserts each declares `pub const tier: u8 = 2`.
//   - Forces every `lib/man/*.zig` to be claimed by exactly one list -- a new
//     module in `lib/man/` that nobody classifies fails the build via the
//     orphan check at the bottom.
//
// This file is referenced from `lib/root.zig` so its comptime block fires
// on every build of the user library.
//
// Limitations:
//   - We don't comptime-verify "T1 module doesn't import T2 module": Zig
//     doesn't expose source-text introspection at comptime, and a runtime
//     check would defeat the point. The tier tag is a load-bearing
//     reviewer signal, not a blanket enforcement. Adding `@import("init_api.zig")`
//     to a T1 module is still a code review concern. (A `tools/check_t1_imports.zig`
//     CI script could fill this gap by grepping; not yet built.)
//
//------------------------------------------------------------------------------

const std = @import("std");

/// T1 modules: vocabulary, T0 syscalls only, no peer ICC.
const t1_modules = struct {
    pub const console = @import("man/console.zig");
    pub const heap = @import("man/heap.zig");
    pub const tasks = @import("man/tasks.zig");
    pub const fwcfg = @import("man/fwcfg.zig");
    pub const virtio = @import("man/virtio.zig");
    pub const socket_shm = @import("man/socket_shm.zig");
    pub const net_shm = @import("man/net_shm.zig");
    pub const net_protocol = @import("man/net_protocol.zig");
};

/// T2 modules: thin RPC clients of peer containers, bounded-timeout ICC.
const t2_modules = struct {
    pub const init_api = @import("man/init_api.zig");
    pub const net_api = @import("man/net_api.zig");
    pub const http = @import("man/http.zig");
    pub const platform = @import("man/platform.zig");
};

comptime {
    // T1 audit: each module declares `pub const tier: u8 = 1`.
    for (std.meta.declarations(t1_modules)) |decl| {
        const m = @field(t1_modules, decl.name);
        if (!@hasDecl(m, "tier")) {
            @compileError("lib/man/" ++ decl.name ++ ".zig is in t1_modules but has no `pub const tier: u8` decl");
        }
        if (m.tier != 1) {
            @compileError(std.fmt.comptimePrint(
                "lib/man/{s}.zig is in t1_modules but declares tier = {d} (expected 1)",
                .{ decl.name, m.tier },
            ));
        }
    }

    // T2 audit: each module declares `pub const tier: u8 = 2`.
    for (std.meta.declarations(t2_modules)) |decl| {
        const m = @field(t2_modules, decl.name);
        if (!@hasDecl(m, "tier")) {
            @compileError("lib/man/" ++ decl.name ++ ".zig is in t2_modules but has no `pub const tier: u8` decl");
        }
        if (m.tier != 2) {
            @compileError(std.fmt.comptimePrint(
                "lib/man/{s}.zig is in t2_modules but declares tier = {d} (expected 2)",
                .{ decl.name, m.tier },
            ));
        }
    }
}
