//------------------------------------------------------------------------------
// Init API - Interface to Lamina (Init Container)
//
// Allows containers to request spawn operations and shutdown.
//------------------------------------------------------------------------------

const lib = @import("../root.zig");
const sys = lib.syscalls;
const IccMessage = sys.Message;
const errors = lib.errors;

/// Init container ID is always 1
const INIT_ID: u16 = 1;

/// Exit codes for shell/login coordination
pub const ExitCode = struct {
    pub const NORMAL: u8 = 0; // Normal exit, login respawns shell
    pub const SHUTDOWN: u8 = 250; // System shutdown requested
    pub const REBOOT: u8 = 251; // System reboot requested
};

/// ICC Message Types
pub const InitMsgType = struct {
    /// Spawn request: payload[0..len] = name
    pub const SPAWN: u16 = 0x3000;
    /// Spawn result: payload[0..7] = id (u64), [8..15] = error (u64)
    pub const SPAWN_RESULT: u16 = 0x3001;

    /// Shutdown request
    pub const SHUTDOWN: u16 = 0x3002;
    /// Shutdown result (ack)
    pub const SHUTDOWN_RESULT: u16 = 0x3003;

    /// Console switch request: payload[0..7] = target container ID
    pub const CONSOLE_SWITCH: u16 = 0x3004;
    /// Console switch result (ack)
    pub const CONSOLE_SWITCH_RESULT: u16 = 0x3005;

    /// Spawn shell request (from login -> lamina)
    pub const SPAWN_SHELL: u16 = 0x3006;
    /// Spawn shell result: payload[0..7] = shell container ID
    pub const SPAWN_SHELL_RESULT: u16 = 0x3007;

    /// Reboot request (triggers PSCI/watchdog reboot)
    pub const REBOOT: u16 = 0x3008;

    /// Kill container request: payload[0..8] = container_id (u64)
    pub const KILL: u16 = 0x3009;
    /// Kill result: payload[0..8] = 0 success, nonzero = error
    pub const KILL_RESULT: u16 = 0x300A;
};

/// Spawn a container by name
/// Returns the container ID on success
pub fn spawn(name: []const u8) !u64 {
    if (name.len > 240) return error.NameTooLong;

    var msg: IccMessage = undefined;
    msg.msg_type = InitMsgType.SPAWN;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    // Copy name into payload
    @memcpy(msg.payload[0..name.len], name);

    // Send request
    const send_res = sys.icc_send(INIT_ID, &msg);
    if (lib.isError(send_res)) return error.IccError;

    // Wait for response
    var response: IccMessage = undefined;
    const recv_res = sys.icc_recv(&response, 1_000_000_000); // 1s timeout
    if (lib.isError(recv_res)) return error.TimedOut;

    if (response.msg_type != InitMsgType.SPAWN_RESULT) return error.invalidProtocol;

    // Parse result
    const id = @as(u64, @bitCast(response.payload[0..8].*));
    const err = @as(u64, @bitCast(response.payload[8..16].*));

    if (err == 2) return error.UnsafeName;
    if (err == 3) return error.AlreadyRunning;
    if (err != 0) return error.SpawnFailed;

    return id;
}

/// Request system shutdown
pub fn shutdown() !void {
    return shutdownWith(0);
}

/// Request system shutdown with exit code
/// The exit code will be propagated to lamina's exit, useful for test harness
pub fn shutdownWith(exit_code: u64) !void {
    var msg: IccMessage = undefined;
    msg.msg_type = InitMsgType.SHUTDOWN;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    // Embed exit code in payload[0..8]
    @as(*align(1) u64, @ptrCast(&msg.payload[0])).* = exit_code;

    const send_res = sys.icc_send(INIT_ID, &msg);
    if (lib.isError(send_res)) return error.IccError;
}

/// Request console switch to specified container
/// Used by shell to switch console to spawned child and back
pub fn switchConsole(target_id: u64) !void {
    var msg: IccMessage = undefined;
    msg.msg_type = InitMsgType.CONSOLE_SWITCH;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    // Embed target ID in payload[0..8]
    @as(*align(1) u64, @ptrCast(&msg.payload[0])).* = target_id;

    const send_res = sys.icc_send(INIT_ID, &msg);
    if (lib.isError(send_res)) return error.IccError;

    // Wait for ack
    var response: IccMessage = undefined;
    const recv_res = sys.icc_recv(&response, 100_000_000); // 100ms timeout
    if (lib.isError(recv_res)) return error.TimedOut;
}

/// Request lamina to spawn a shell container
/// Returns shell container ID on success
/// Used by login container for shell lifecycle management
pub fn spawnShell() !u64 {
    var msg: IccMessage = undefined;
    msg.msg_type = InitMsgType.SPAWN_SHELL;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    const send_res = sys.icc_send(INIT_ID, &msg);
    if (lib.isError(send_res)) return error.IccError;

    // Wait for response (shell spawn can take a moment)
    var response: IccMessage = undefined;
    const recv_res = sys.icc_recv(&response, 5_000_000_000); // 5s timeout
    if (lib.isError(recv_res)) return error.TimedOut;

    if (response.msg_type != InitMsgType.SPAWN_SHELL_RESULT) return error.InvalidProtocol;

    // Parse result - shell container ID in payload[0..8]
    const shell_id = @as(u64, @bitCast(response.payload[0..8].*));
    const err = @as(u64, @bitCast(response.payload[8..16].*));

    if (err != 0 or shell_id == 0) return error.SpawnFailed;

    return shell_id;
}

/// Kill a container by ID (routes through lamina which has kill capability)
pub fn kill(container_id: u64) !void {
    var msg: IccMessage = undefined;
    msg.msg_type = InitMsgType.KILL;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    @as(*align(1) u64, @ptrCast(&msg.payload[0])).* = container_id;

    const send_res = sys.icc_send(INIT_ID, &msg);
    if (lib.isError(send_res)) return error.IccError;

    // Wait for response
    var response: IccMessage = undefined;
    const recv_res = sys.icc_recv(&response, 1_000_000_000); // 1s timeout
    if (lib.isError(recv_res)) return error.TimedOut;

    if (response.msg_type != InitMsgType.KILL_RESULT) return error.InvalidProtocol;

    const result = @as(u64, @bitCast(response.payload[0..8].*));
    if (result != 0) return error.KillFailed;
}

/// Request system reboot
pub fn reboot() !void {
    var msg: IccMessage = undefined;
    msg.msg_type = InitMsgType.REBOOT;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    const send_res = sys.icc_send(INIT_ID, &msg);
    if (lib.isError(send_res)) return error.IccError;
}
