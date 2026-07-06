//------------------------------------------------------------------------------
// Init Container Protocol — Method specs for `lib/init_client/`
//------------------------------------------------------------------------------
//
// Single source of truth for the lamina init container's ICC message format.
// The client lib (`lib/init_client/api.zig`) imports this; lamina's handler
// (`user/services/lamina.zig`) imports this; the kernel never touches it.
//
// Specs follow the `lib/man/rpc.zig` Method-spec convention:
//   - REQ_TYPE / REPLY_TYPE constants (REPLY_TYPE omitted for cast specs).
//   - Request / Reply struct types (Reply omitted for cast specs).
//   - serialize(req, payload) writing into a 248-byte mailbox payload.
//   - deserialize(payload) returning a Reply (call specs only).
//
// Message-type allocation: 0x3000-0x300B is lamina's ICC range. See
// `src/shared/icc/schema.zig` for the kernel-wide range registry.
//
//------------------------------------------------------------------------------

/// Mailbox payload size. Mirrors `src/shared/icc/schema.zig` PAYLOAD_SIZE --
/// this module is import-free by design; lib/root.zig asserts the mirror.
pub const PAYLOAD_SIZE = 248;

/// Lamina's container ID is fixed at 1 by `boot_contract.md` §9.4 (the
/// kernel spawns exactly one T2 container, and it's lamina). Pinned here
/// so client code doesn't have to ns_lookup.
pub const INIT_ID: u16 = 1;

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
};

/// Maximum bytes a SPAWN/SPAWN_WITH_ARGS payload can carry. The mailbox
/// payload is 248 bytes; we cap at 240 to leave room for the separator
/// byte and a small safety margin.
pub const MAX_SPAWN_PAYLOAD: usize = 240;

/// Separator byte between name and argv blob in SPAWN_WITH_ARGS.
/// 0xFF is unambiguous because container names are ASCII.
pub const SPAWN_ARGS_SEP: u8 = 0xFF;

/// Helper: encode a u64 at payload offset 0 (the dominant scalar shape
/// across these specs — container IDs and exit codes).
fn writeU64(payload: *[PAYLOAD_SIZE]u8, value: u64) void {
    @as(*align(1) u64, @ptrCast(&payload[0])).* = value;
}

//------------------------------------------------------------------------------
// Spawn — request a container spawn by name
//------------------------------------------------------------------------------

pub const Spawn = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SPAWN;
    pub const REPLY_TYPE: u16 = InitMsgType.SPAWN_RESULT;

    pub const Request = struct { name: []const u8 };
    pub const Reply = struct { id: u64, err: u64 };

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
// SpawnWithArgs — spawn + argv blob (null-separated)
//------------------------------------------------------------------------------

pub const SpawnWithArgs = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SPAWN_WITH_ARGS;
    pub const REPLY_TYPE: u16 = InitMsgType.SPAWN_RESULT;

    pub const Request = struct { name: []const u8, argv_data: []const u8 };
    pub const Reply = Spawn.Reply;

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
// SpawnShell — login asks lamina to spawn a shell
//------------------------------------------------------------------------------

pub const SpawnShell = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SPAWN_SHELL;
    pub const REPLY_TYPE: u16 = InitMsgType.SPAWN_SHELL_RESULT;

    pub const Request = struct {};
    pub const Reply = struct { shell_id: u64, err: u64 };

    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .shell_id = @bitCast(payload[0..8].*),
            .err = @bitCast(payload[8..16].*),
        };
    }
};

//------------------------------------------------------------------------------
// Kill — kill a container by ID (routed through lamina's kill capability)
//------------------------------------------------------------------------------

pub const Kill = struct {
    pub const REQ_TYPE: u16 = InitMsgType.KILL;
    pub const REPLY_TYPE: u16 = InitMsgType.KILL_RESULT;

    pub const Request = struct { container_id: u64 };
    pub const Reply = struct { result: u64 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, req.container_id);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .result = @bitCast(payload[0..8].*) };
    }
};

//------------------------------------------------------------------------------
// ConsoleSwitch — switch foreground console to target container
//------------------------------------------------------------------------------

pub const ConsoleSwitch = struct {
    pub const REQ_TYPE: u16 = InitMsgType.CONSOLE_SWITCH;
    pub const REPLY_TYPE: u16 = InitMsgType.CONSOLE_SWITCH_RESULT;

    pub const Request = struct { target_id: u64 };
    pub const Reply = struct {};

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, req.target_id);
    }

    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

//------------------------------------------------------------------------------
// Shutdown — fire-and-forget; lamina exits with the embedded code
//------------------------------------------------------------------------------

pub const Shutdown = struct {
    pub const REQ_TYPE: u16 = InitMsgType.SHUTDOWN;
    pub const Request = struct { exit_code: u64 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, req.exit_code);
    }
};

//------------------------------------------------------------------------------
// Reboot — fire-and-forget; lamina triggers PSCI/watchdog reboot
//------------------------------------------------------------------------------

pub const Reboot = struct {
    pub const REQ_TYPE: u16 = InitMsgType.REBOOT;
    pub const Request = struct {};

    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}
};
