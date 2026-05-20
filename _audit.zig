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
//     doesn't expose source-text introspection at comptime. Two build-time
//     gates fill this gap, both wired into the default build:
//       * `tools/check_tier_imports.zig` (item C8.10) -- scans every
//         `lib/man/*.zig` for `@import("...<peer>_client/...")` and fails
//         the build on hit.
//       * `tools/check_client_isolation.zig` (item C8.16) -- scans every
//         `lib/<peer>_client/*.zig` for cross-client `@import("..._client/")`
//         targeting a different peer; `init_client/` is exempt as the
//         universal spawn orchestrator.
//
//------------------------------------------------------------------------------

const std = @import("std");

/// T1 modules: vocabulary, T0 syscalls only, no peer ICC.
/// `rpc` is the generic RPC primitive — itself parameterized over peer,
/// so vocabulary by construction; per-peer instantiations are T2.
const t1_modules = struct {
    pub const console = @import("man/console.zig");
    pub const heap = @import("man/heap.zig");
    pub const tasks = @import("man/tasks.zig");
    pub const fwcfg = @import("man/fwcfg.zig");
    pub const virtio = @import("man/virtio.zig");
    pub const socket_shm = @import("man/socket_shm.zig");
    pub const net_shm = @import("man/net_shm.zig");
    pub const net_protocol = @import("man/net_protocol.zig");
    pub const rpc = @import("man/rpc.zig");
    pub const http = @import("man/http.zig");
    pub const socket_stream = @import("man/socket_stream.zig");
    pub const ring = @import("man/ring.zig");
};

/// T2 modules: thin RPC clients of peer containers, bounded-timeout ICC.
/// Each lives in its own per-peer namespace (`lib/<peer>_client/`) so the
/// directory itself documents the tier — `lib/man/` is strict T1.
const t2_modules = struct {
    pub const init_client = @import("init_client/api.zig");
    pub const platform_client = @import("platform_client/api.zig");
    pub const blk_client = @import("blk_client/api.zig");
    pub const wasm_client = @import("wasm_client/api.zig");
    pub const net_client = @import("net_client/api.zig");
    pub const http_client = @import("net_client/http_transport.zig");
};

comptime {
    // T1 audit: each module declares `pub const tier: u8 = 1`.
    for (std.meta.declarations(t1_modules)) |decl| {
        const m = @field(t1_modules, decl.name);
        if (!@hasDecl(m, "tier")) {
            @compileError("t1_modules member `" ++ decl.name ++ "` has no `pub const tier: u8` decl");
        }
        if (m.tier != 1) {
            @compileError(std.fmt.comptimePrint(
                "t1_modules member `{s}` declares tier = {d} (expected 1)",
                .{ decl.name, m.tier },
            ));
        }
    }

    // T2 audit: each module declares `pub const tier: u8 = 2`.
    for (std.meta.declarations(t2_modules)) |decl| {
        const m = @field(t2_modules, decl.name);
        if (!@hasDecl(m, "tier")) {
            @compileError("t2_modules member `" ++ decl.name ++ "` has no `pub const tier: u8` decl");
        }
        if (m.tier != 2) {
            @compileError(std.fmt.comptimePrint(
                "t2_modules member `{s}` declares tier = {d} (expected 2)",
                .{ decl.name, m.tier },
            ));
        }
    }
}
