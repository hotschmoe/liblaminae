//------------------------------------------------------------------------------
// Init Client -- RPC stub for the lamina init cell
//------------------------------------------------------------------------------
//
// Thin wrapper over `lib/man/rpc.zig` for spawn/kill/shutdown/console-switch
// operations. The protocol schema is `src/shared/icc/protocols/init.zig`
// (imported as the `init_protocol` module).
//
// Usage:
//   const init = @import("liblaminae").init_client;
//   const id = try init.spawn("netd");
//   try init.shutdownWith(0);
//
//------------------------------------------------------------------------------

const rpc = @import("../man/rpc.zig");
const channel = @import("../man/channel.zig");
const proto = @import("init_protocol");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Thin channel-RPC client of the lamina init cell. Peer-dependent, hence
/// T2. L4-MIGRATED: the init.lamina control bundle arrives at spawn via
/// the manifest requires edge; discovery is requiredChannel(hash) -- no
/// fixed-ID mailbox addressing.
pub const tier: u8 = 2;

/// Re-export protocol vocabulary for callers that need the message-type
/// constants (lamina's handler dispatch, mainly).
pub const InitMsgType = proto.InitMsgType;
pub const ExitCode = proto.ExitCode;

// Cached control bundle (folded in at spawn; discovered on first use).
var cached_ch: ?channel.Channel = null;

fn initChannel() rpc.RpcError!channel.Channel {
    if (cached_ch) |c| return c;
    _ = channel.reclaimClosed(proto.CONTRACT_HASH);
    const c = channel.requiredChannel(proto.CONTRACT_HASH) catch return rpc.RpcError.IccError;
    cached_ch = c;
    return c;
}

/// channel.call with errors mapped into the rpc.RpcError vocabulary the
/// existing per-method wrappers already handle. PeerClosed cannot happen in
/// practice (lamina never dies before its clients); map to IccError.
fn callInit(comptime Spec: type, req: Spec.Request, timeout: rpc.Timeout) rpc.RpcError!Spec.Reply {
    const ch = try initChannel();
    return channel.call(ch, Spec, req, timeout) catch |err| switch (err) {
        channel.CallError.InvalidProtocol => rpc.RpcError.InvalidProtocol,
        channel.CallError.TimedOut => rpc.RpcError.TimedOut,
        channel.CallError.PeerClosed => blk: {
            cached_ch = null; // stale bundle; re-discover on next call
            break :blk rpc.RpcError.IccError;
        },
        channel.CallError.IccError => rpc.RpcError.IccError,
    };
}

fn castInit(comptime Spec: type, req: Spec.Request) error{IccError}!void {
    const ch = initChannel() catch return error.IccError;
    channel.cast(ch, Spec, req) catch return error.IccError;
}

//------------------------------------------------------------------------------
// Spawn operations
//------------------------------------------------------------------------------

pub const SpawnError = error{ NameTooLong, UnsafeName, AlreadyRunning, NotFound, SpawnFailed } || rpc.RpcError;

// Reply.err codes are lamina's contract (user/services/lamina.zig resolveAndSpawn):
// 0 ok, 2 unsafe name, 3 singleton already running, 4 binary not found, else generic.
fn checkSpawnReply(reply: proto.Spawn.Reply) SpawnError!u64 {
    return switch (reply.err) {
        0 => reply.id,
        2 => SpawnError.UnsafeName,
        3 => SpawnError.AlreadyRunning,
        4 => SpawnError.NotFound,
        else => SpawnError.SpawnFailed,
    };
}

/// Spawn a cell by name. Returns the cell ID on success.
pub fn spawn(name: []const u8) SpawnError!u64 {
    if (name.len > proto.MAX_SPAWN_PAYLOAD) return SpawnError.NameTooLong;
    const reply = try callInit(proto.Spawn, .{ .name = name }, .{ .ms = 1000 });
    return checkSpawnReply(reply);
}

/// Spawn a cell by name with a packed null-separated argv blob.
pub fn spawnWithArgs(name: []const u8, argv_data: []const u8) SpawnError!u64 {
    if (name.len + 1 + argv_data.len > proto.MAX_SPAWN_PAYLOAD) return SpawnError.NameTooLong;
    const reply = try callInit(
        proto.SpawnWithArgs,
        .{ .name = name, .argv_data = argv_data },
        .{ .ms = 1000 },
    );
    return checkSpawnReply(reply);
}

/// Lamina spawns a shell on behalf of login. Returns the shell cell ID.
/// Longer (5s) timeout because shell spawn drags in more init work than a
/// generic spawn.
pub fn spawnShell() SpawnError!u64 {
    const reply = try callInit(proto.SpawnShell, .{}, .{ .ms = 5000 });
    if (reply.err != 0 or reply.shell_id == 0) return SpawnError.SpawnFailed;
    return reply.shell_id;
}

//------------------------------------------------------------------------------
// Connect -- dynamic channel acquisition (channel_contract.md 15.5)
//------------------------------------------------------------------------------

pub const ConnectError = error{ Unauthorized, NoProvider, SpawnFailed, WireFailed, ConnectFailed } || rpc.RpcError;

/// The consumer half of a freshly wired bundle, as raw tokens. Feed to
/// `channel.Channel` (lib/man/channel.zig) or use the tokens directly.
pub const Connection = struct { out_tok: u32, in_tok: u32, provider: u32 };

/// Ask lamina for a wired bundle to `namespace`'s provider. Requires a
/// `.dynamic` manifest entry (the manifest is the capability). `dedicated`
/// forces a fresh provider instance (the wasm-d daemon case). Generous
/// timeout: lamina may spawn the provider on demand.
pub fn connect(namespace: []const u8, dedicated: bool) ConnectError!Connection {
    const reply = try callInit(proto.Connect, .{ .namespace = namespace, .dedicated = dedicated }, .{ .ms = 5000 });
    return switch (reply.err) {
        0 => .{ .out_tok = reply.out_tok, .in_tok = reply.in_tok, .provider = reply.provider },
        1 => ConnectError.Unauthorized,
        2 => ConnectError.NoProvider,
        3 => ConnectError.SpawnFailed,
        4 => ConnectError.WireFailed,
        else => ConnectError.ConnectFailed,
    };
}

//------------------------------------------------------------------------------
// DryRun -- topology query without spawn/wire
//------------------------------------------------------------------------------

pub const DryRunError = error{ UnknownContract, NoProvider } || rpc.RpcError;

/// Ask lamina what would happen if we connected to `namespace`.
/// Does not spawn or wire. Returns the live provider's packed
/// gen-qualified id on WOULD_WIRE.
pub fn dryRun(namespace: []const u8) DryRunError!u32 {
    const reply = try callInit(proto.DryRun, .{ .namespace = namespace }, .{ .ms = 1000 });
    return switch (reply.err) {
        0 => reply.provider,
        1 => DryRunError.UnknownContract,
        2 => DryRunError.NoProvider,
        else => DryRunError.NoProvider,
    };
}

//------------------------------------------------------------------------------
// Kill / shutdown / reboot
//------------------------------------------------------------------------------

pub const KillError = error{ KillFailed, NoSuchIncarnation } || rpc.RpcError;

/// Kill a cell by generation-qualified identity (raw | gen<<16; gen 0 =
/// current-occupant wildcard). Routed through lamina (which holds the kill
/// cap). On failure lamina's reply carries the RAW kernel error code:
/// the -ESRCH class ("that incarnation is not there" -- stale generation,
/// empty slot, already-dead zombie) surfaces as NoSuchIncarnation so
/// supervisors can distinguish it from a genuine kill failure.
pub fn kill(cell_id: u64) KillError!void {
    const reply = try callInit(proto.Kill, .{ .cell_id = cell_id }, .{ .ms = 1000 });
    if (reply.result != 0) {
        const gen_errors = @import("../gen/errors.zig");
        if (gen_errors.isErrno(reply.result, .ESRCH)) return KillError.NoSuchIncarnation;
        return KillError.KillFailed;
    }
}

/// Request system shutdown. Fire-and-forget.
pub fn shutdown() error{IccError}!void {
    return shutdownWith(0);
}

/// Request system shutdown with an exit code propagated to lamina's exit.
/// Fire-and-forget.
pub fn shutdownWith(exit_code: u64) error{IccError}!void {
    try castInit(proto.Shutdown, .{ .exit_code = exit_code });
}

/// Network-configured notification (zmoltcp -> lamina; replaces the old
/// "net.configured" namespace flag). Fire-and-forget.
pub fn netConfigured() error{IccError}!void {
    try castInit(proto.NetEvent, .{ .kind = 1 });
}

/// Request system reboot. Fire-and-forget.
pub fn reboot() error{IccError}!void {
    try castInit(proto.Reboot, .{});
}

//------------------------------------------------------------------------------
// Console switch
//------------------------------------------------------------------------------

/// Switch foreground console to the named cell. Used by shell to
/// hand the console to a spawned child and reclaim it on return.
pub fn switchConsole(target_id: u64) rpc.RpcError!void {
    _ = try callInit(proto.ConsoleSwitch, .{ .target_id = target_id }, .{ .ms = 100 });
}
