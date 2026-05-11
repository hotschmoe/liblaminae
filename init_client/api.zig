//------------------------------------------------------------------------------
// Init Client — RPC stub for the lamina init container
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
const proto = @import("init_protocol");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Thin RPC client of the lamina init container -- bounded-timeout ICC for
/// spawn/kill/shutdown. Peer-dependent, hence T2.
pub const tier: u8 = 2;

/// Re-export protocol vocabulary for callers that need the message-type
/// constants (lamina's handler dispatch, mainly).
pub const InitMsgType = proto.InitMsgType;
pub const ExitCode = proto.ExitCode;

const INIT = rpc.PeerHandle.fixed(proto.INIT_ID);

//------------------------------------------------------------------------------
// Spawn operations
//------------------------------------------------------------------------------

pub const SpawnError = error{ NameTooLong, UnsafeName, AlreadyRunning, SpawnFailed } || rpc.RpcError;

fn checkSpawnReply(reply: proto.Spawn.Reply) SpawnError!u64 {
    return switch (reply.err) {
        0 => reply.id,
        2 => SpawnError.UnsafeName,
        3 => SpawnError.AlreadyRunning,
        else => SpawnError.SpawnFailed,
    };
}

/// Spawn a container by name. Returns the container ID on success.
pub fn spawn(name: []const u8) SpawnError!u64 {
    if (name.len > proto.MAX_SPAWN_PAYLOAD) return SpawnError.NameTooLong;
    const reply = try rpc.call(INIT, proto.Spawn, .{ .name = name }, .{ .ms = 1000 });
    return checkSpawnReply(reply);
}

/// Spawn a container by name with a packed null-separated argv blob.
pub fn spawnWithArgs(name: []const u8, argv_data: []const u8) SpawnError!u64 {
    if (name.len + 1 + argv_data.len > proto.MAX_SPAWN_PAYLOAD) return SpawnError.NameTooLong;
    const reply = try rpc.call(
        INIT,
        proto.SpawnWithArgs,
        .{ .name = name, .argv_data = argv_data },
        .{ .ms = 1000 },
    );
    return checkSpawnReply(reply);
}

/// Lamina spawns a shell on behalf of login. Returns the shell container ID.
/// Longer (5s) timeout because shell spawn drags in more init work than a
/// generic spawn.
pub fn spawnShell() SpawnError!u64 {
    const reply = try rpc.call(INIT, proto.SpawnShell, .{}, .{ .ms = 5000 });
    if (reply.err != 0 or reply.shell_id == 0) return SpawnError.SpawnFailed;
    return reply.shell_id;
}

//------------------------------------------------------------------------------
// Kill / shutdown / reboot
//------------------------------------------------------------------------------

pub const KillError = error{KillFailed} || rpc.RpcError;

/// Kill a container by ID. Routed through lamina (which holds the kill cap).
pub fn kill(container_id: u64) KillError!void {
    const reply = try rpc.call(INIT, proto.Kill, .{ .container_id = container_id }, .{ .ms = 1000 });
    if (reply.result != 0) return KillError.KillFailed;
}

/// Request system shutdown. Fire-and-forget.
pub fn shutdown() error{IccError}!void {
    return shutdownWith(0);
}

/// Request system shutdown with an exit code propagated to lamina's exit.
/// Fire-and-forget.
pub fn shutdownWith(exit_code: u64) error{IccError}!void {
    try rpc.cast(INIT, proto.Shutdown, .{ .exit_code = exit_code });
}

/// Request system reboot. Fire-and-forget.
pub fn reboot() error{IccError}!void {
    try rpc.cast(INIT, proto.Reboot, .{});
}

//------------------------------------------------------------------------------
// Console switch
//------------------------------------------------------------------------------

/// Switch foreground console to the named container. Used by shell to
/// hand the console to a spawned child and reclaim it on return.
pub fn switchConsole(target_id: u64) rpc.RpcError!void {
    _ = try rpc.call(INIT, proto.ConsoleSwitch, .{ .target_id = target_id }, .{ .ms = 100 });
}
