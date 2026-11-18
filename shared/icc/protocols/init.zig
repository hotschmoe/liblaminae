//------------------------------------------------------------------------------
// Init Cell Protocol -- Method specs for `lib/init_client/`
//------------------------------------------------------------------------------
//
// Single source of truth for the lamina init cell's ICC message format.
// The client lib (`lib/init_client/api.zig`) imports this; lamina's handler
// (`user/services/lamina.zig`) imports this; the kernel never touches it.
//
// Specs follow the `lib/man/rpc.zig` Method-spec convention:
//   - REQ_TYPE / REPLY_TYPE constants (REPLY_TYPE omitted for cast specs).
//   - Request / Reply struct types (Reply omitted for cast specs).
//   - serialize(req, payload) writing into a 248-byte mailbox payload.
//   - deserialize(payload) returning a Reply (call specs only).
//
// Message-type allocation: 0x3000-0x3010 is lamina's ICC range. See
// `src/shared/icc/schema.zig` for the kernel-wide range registry.
//
// Import-free by design (the_law/HARDLINE.md section 5), amended by L1.1
// (the_law/adoption_plan.md) to allow exactly one leaf import:
// `src/shared/icc/contract.zig`, itself import-free. It supplies the
// CONTRACT_HASH computation below (lamina answers CONTRACT_HELLO with it
// even though `init_client` addresses lamina by fixed ID rather than
// `ns_lookup`).
//
//------------------------------------------------------------------------------

const contract = @import("contract");

/// Channel-message payload size. Mirrors `src/shared/icc/schema.zig` PAYLOAD_SIZE --
/// this module is import-free by design; lib/root.zig asserts the mirror.
pub const PAYLOAD_SIZE = 248;

/// Lamina's cell ID is fixed at 1 by `boot_contract.md` Section 9.4 (the
/// kernel spawns exactly one T2 cell, and it's lamina). Pinned here
/// so client code doesn't have to ns_lookup.
pub const INIT_ID: u16 = 1;

/// Namespace label used only for the CONTRACT_HASH descriptor (lamina has
/// no `ns_register` string -- it is addressed by `INIT_ID`, not lookup).
pub const NAMESPACE: []const u8 = "init.lamina";

/// Exit codes for shell/login coordination. Propagated through
/// `init_client.shutdownWith()` to lamina's exit syscall.
pub const ExitCode = struct {
    pub const NORMAL: u8 = 0;
    pub const SHUTDOWN: u8 = 250;
    pub const REBOOT: u8 = 251;
};

/// Message type constants. Kept as a flat namespace so lamina's dispatch
/// switch can use `InitMsgType.SPAWN`, `InitMsgType.KILL`, etc.
pub const InitMsgType = struct {
    pub const SPAWN: u16 = 0x3000;
    pub const SPAWN_RESULT: u16 = 0x3001;

    pub const SHUTDOWN: u16 = 0x3002;
    pub const SHUTDOWN_RESULT: u16 = 0x3003;

    pub const CONSOLE_SWITCH: u16 = 0x3004;
    pub const CONSOLE_SWITCH_RESULT: u16 = 0x3005;

    pub const SPAWN_SHELL: u16 = 0x3006;
    pub const SPAWN_SHELL_RESULT: u16 = 0x3007;

    pub const REBOOT: u16 = 0x3008;

    pub const KILL: u16 = 0x3009;
    pub const KILL_RESULT: u16 = 0x300A;

    pub const SPAWN_WITH_ARGS: u16 = 0x300B;

    pub const CONNECT: u16 = 0x300C;
    pub const CONNECT_RESULT: u16 = 0x300D;

    pub const NET_EVENT: u16 = 0x300E;

    pub const DRY_RUN: u16 = 0x300F;
    pub const DRY_RUN_RESULT: u16 = 0x3010;
};

/// Maximum bytes a SPAWN/SPAWN_WITH_ARGS payload can carry. The mailbox
/// payload is 248 bytes; we cap at 240 to leave room for the separator
/// byte and a small safety margin.
pub const MAX_SPAWN_PAYLOAD: usize = 240;

/// Separator byte between name and argv blob in SPAWN_WITH_ARGS.
/// 0xFF is unambiguous because cell names are ASCII.
pub const SPAWN_ARGS_SEP: u8 = 0xFF;

/// Helper: encode a u64 at payload offset 0 (the dominant scalar shape
/// across these specs -- cell IDs and exit codes).
fn writeU64(payload: *[PAYLOAD_SIZE]u8, value: u64) void {
    @as(*align(1) u64, @ptrCast(&payload[0])).* = value;
}

//------------------------------------------------------------------------------
// Spawn -- request a cell spawn by name
//------------------------------------------------------------------------------

pub const Spawn = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SPAWN;
    pub const REPLY_TYPE: u16 = InitMsgType.SPAWN_RESULT;

    pub const Request = struct { name: []const u8 };
    pub const Reply = extern struct { id: u64, err: u64 };

    /// Wire: cell name bytes at offset 0, NUL-terminated (the mailbox
    /// payload is zeroed before serialize). Lamina scans to the first 0,
    /// capped at MAX_SPAWN_PAYLOAD.
    pub const WireRequest = extern struct { name: [MAX_SPAWN_PAYLOAD]u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        @memcpy(payload[0..req.name.len], req.name);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .id = @bitCast(payload[0..8].*),
            .err = @bitCast(payload[8..16].*),
        };
    }
};

//------------------------------------------------------------------------------
// SpawnWithArgs -- spawn + argv blob (null-separated)
//------------------------------------------------------------------------------

pub const SpawnWithArgs = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SPAWN_WITH_ARGS;
    pub const REPLY_TYPE: u16 = InitMsgType.SPAWN_RESULT;

    pub const Request = struct { name: []const u8, argv_data: []const u8 };
    pub const Reply = Spawn.Reply;

    /// Wire: `name` bytes, one SPAWN_ARGS_SEP (0xFF) byte, then the
    /// NUL-separated argv blob -- all variable-length within one
    /// MAX_SPAWN_PAYLOAD region (zero-filled tail; lamina scans for the
    /// separator, then takes argv up to the last non-zero byte).
    pub const WireRequest = extern struct { name_sep_argv: [MAX_SPAWN_PAYLOAD]u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        @memcpy(payload[0..req.name.len], req.name);
        payload[req.name.len] = SPAWN_ARGS_SEP;
        @memcpy(payload[req.name.len + 1 ..][0..req.argv_data.len], req.argv_data);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return Spawn.deserialize(payload);
    }
};

//------------------------------------------------------------------------------
// SpawnShell -- login asks lamina to spawn a shell
//------------------------------------------------------------------------------

pub const SpawnShell = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SPAWN_SHELL;
    pub const REPLY_TYPE: u16 = InitMsgType.SPAWN_SHELL_RESULT;

    pub const Request = struct {};
    pub const Reply = extern struct { shell_id: u64, err: u64 };

    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .shell_id = @bitCast(payload[0..8].*),
            .err = @bitCast(payload[8..16].*),
        };
    }
};

//------------------------------------------------------------------------------
// Kill -- kill a cell by ID (routed through lamina's kill capability)
//------------------------------------------------------------------------------

pub const Kill = struct {
    pub const REQ_TYPE: u16 = InitMsgType.KILL;
    pub const REPLY_TYPE: u16 = InitMsgType.KILL_RESULT;

    pub const Request = extern struct { cell_id: u64 };
    pub const Reply = extern struct { result: u64 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, req.cell_id);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .result = @bitCast(payload[0..8].*) };
    }
};

//------------------------------------------------------------------------------
// ConsoleSwitch -- switch foreground console to target cell
//------------------------------------------------------------------------------

pub const ConsoleSwitch = struct {
    pub const REQ_TYPE: u16 = InitMsgType.CONSOLE_SWITCH;
    pub const REPLY_TYPE: u16 = InitMsgType.CONSOLE_SWITCH_RESULT;

    pub const Request = extern struct { target_id: u64 };
    pub const Reply = struct {};

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, req.target_id);
    }

    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

//------------------------------------------------------------------------------
// Shutdown -- fire-and-forget; lamina exits with the embedded code
//------------------------------------------------------------------------------

pub const Shutdown = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SHUTDOWN;
    pub const Request = extern struct { exit_code: u64 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, req.exit_code);
    }
};

//------------------------------------------------------------------------------
// Reboot -- fire-and-forget; lamina triggers PSCI/watchdog reboot
//------------------------------------------------------------------------------

pub const Reboot = struct {
    pub const REQ_TYPE: u16 = InitMsgType.REBOOT;
    pub const Request = struct {};

    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}
};

//------------------------------------------------------------------------------
// Contract hash (L1.1) -- wire-time refusal between mismatched trees.
//------------------------------------------------------------------------------

pub const CONTRACT_VERSION: u16 = 1;

/// Method specs in wire order. Single source for both the CONTRACT_HASH walk
/// and `tools/gen_docs.zig`'s contract reference (docs/api/contracts.md).
//------------------------------------------------------------------------------
// Connect -- dynamic channel acquisition (channel_contract.md 15.5)
//------------------------------------------------------------------------------

/// Ask lamina for a wired RPC bundle to a contract's provider at RUNTIME.
/// Authorization is the requester's manifest: its `requires` must carry a
/// `.dynamic` entry for `namespace` (the manifest IS the capability).
/// lamina spawns the provider on demand (`dedicated` forces a FRESH
/// instance -- the wasm-d daemon case), wires a bundle, chan_delivers the
/// provider half to the provider and the consumer half to the REQUESTER,
/// and replies with the consumer tokens (valid selectors post-transfer;
/// no discovery scan needed, so a requester holding several bundles of one
/// hash stays unambiguous).
pub const Connect = struct {
    pub const REQ_TYPE: u16 = InitMsgType.CONNECT;
    pub const REPLY_TYPE: u16 = InitMsgType.CONNECT_RESULT;

    pub const Request = struct { namespace: []const u8, dedicated: bool };
    /// err: 0 ok, 1 unauthorized, 2 unknown contract/provider, 3 spawn
    /// failed, 4 wire/deliver failed.
    pub const Reply = extern struct { err: u8, _pad: [3]u8 = .{ 0, 0, 0 }, provider: u32, out_tok: u32, in_tok: u32 };

    /// Wire layout for the CONTRACT_HASH walk: dedicated flag at 0,
    /// namespace bytes from 1, NUL-terminated.
    pub const WireRequest = extern struct { dedicated: u8, namespace: [63]u8 };

    /// Wire: dedicated flag at 0; namespace bytes from 1, NUL-terminated
    /// (payload zeroed before serialize).
    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        payload[0] = if (req.dedicated) 1 else 0;
        @memcpy(payload[1 .. 1 + req.namespace.len], req.namespace);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .err = payload[0],
            .provider = @bitCast(payload[4..8].*),
            .out_tok = @bitCast(payload[8..12].*),
            .in_tok = @bitCast(payload[12..16].*),
        };
    }
};

//------------------------------------------------------------------------------
// NetEvent -- network state notification (replaces the "net.configured"
// namespace flag the dhcp boot gate polled). Cast-only, zmoltcp -> lamina.
//------------------------------------------------------------------------------

pub const NetEvent = struct {
    pub const REQ_TYPE: u16 = InitMsgType.NET_EVENT;

    /// kind 1 = network configured (addressed and routable).
    pub const Request = extern struct { kind: u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        payload[0] = req.kind;
    }
};

//------------------------------------------------------------------------------
// DryRun -- topology query: "if I connect to namespace X, what happens?"
// Does not spawn and does not wire. lamina looks up known_contracts + the
// live provider_ids registry and replies WOULD_WIRE or REFUSED.
//------------------------------------------------------------------------------

pub const DryRun = struct {
    pub const REQ_TYPE: u16 = InitMsgType.DRY_RUN;
    pub const REPLY_TYPE: u16 = InitMsgType.DRY_RUN_RESULT;

    pub const Request = struct { namespace: []const u8 };
    /// err 0 = WOULD_WIRE (provider = packed gen-qualified id of the live
    /// provider). err 1 = unknown namespace (not in known_contracts).
    /// err 2 = no live provider (known, but provider_ids[i] == 0).
    pub const Reply = extern struct { err: u8, _pad: [3]u8 = .{ 0, 0, 0 }, provider: u32 };

    /// Wire: namespace NUL-terminated at payload[0] (payload zeroed before
    /// serialize). 64-byte region leaves a guaranteed terminator.
    pub const WireRequest = extern struct { namespace: [64]u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        const n = @min(req.namespace.len, 63);
        @memcpy(payload[0..n], req.namespace[0..n]);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .err = payload[0],
            .provider = @bitCast(payload[4..8].*),
        };
    }
};

pub const SPECS = .{ Spawn, SpawnWithArgs, SpawnShell, Kill, ConsoleSwitch, Shutdown, Reboot, Connect, NetEvent, DryRun };

pub const CONTRACT_HASH: u64 = contract.hashSpecs(SPECS, NAMESPACE, CONTRACT_VERSION);

// The contract hash and gen_docs derive field offsets from the structs via
// @offsetOf while serialize()/deserialize() hand-write byte offsets. The
// hashed structs are `extern` (or fixed-array WireRequest definitions for
// the string-carrying specs) so their layout is defined, and these asserts
// pin the two views together -- drift is a compile error, not a doc lie.
comptime {
    if (MAX_SPAWN_PAYLOAD > PAYLOAD_SIZE)
        @compileError("init: MAX_SPAWN_PAYLOAD exceeds the mailbox payload");
    if (@sizeOf(Spawn.WireRequest) != MAX_SPAWN_PAYLOAD or
        @sizeOf(SpawnWithArgs.WireRequest) != MAX_SPAWN_PAYLOAD)
        @compileError("init: spawn wire regions drifted from MAX_SPAWN_PAYLOAD");
    if (@offsetOf(Spawn.Reply, "id") != 0 or
        @offsetOf(Spawn.Reply, "err") != 8)
        @compileError("init: Spawn.Reply layout drifted from deserialize()");
    if (@offsetOf(SpawnShell.Reply, "shell_id") != 0 or
        @offsetOf(SpawnShell.Reply, "err") != 8)
        @compileError("init: SpawnShell.Reply layout drifted from deserialize()");
    if (@offsetOf(Kill.Request, "cell_id") != 0 or
        @offsetOf(Kill.Reply, "result") != 0 or
        @offsetOf(ConsoleSwitch.Request, "target_id") != 0 or
        @offsetOf(Shutdown.Request, "exit_code") != 0)
        @compileError("init: scalar request/reply layout drifted from serialize()");
    if (@offsetOf(DryRun.Reply, "err") != 0 or
        @offsetOf(DryRun.Reply, "provider") != 4)
        @compileError("init: DryRun.Reply layout drifted from deserialize()");
}
