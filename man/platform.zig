//------------------------------------------------------------------------------
// platform.zig - Platform Service Thin Wrappers
//------------------------------------------------------------------------------
// Provides a clean API for drivers to interact with the platform container.
// All platforms register as "platform" - drivers don't need to know which
// hardware platform they're running on.
//
// Usage:
//   const platform = lib.platform;
//   try platform.enableClock(clock_id);
//   try platform.enablePower(power_domain_id);
//   try platform.deassertReset(reset_id);
//   const mac = try platform.getMac();
//
// The platform container handles platform-specific details:
// - QEMU virt: All operations return OK immediately (no-op stubs)
// - BCM2711: Uses VideoCore mailbox to control clocks/power/resets
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");

// Platform ICC message types (from schema.zig 0x4000 range)
pub const Msg = struct {
    // Clock control
    pub const ENABLE_CLOCK: u16 = 0x4000;
    pub const ENABLE_CLOCK_OK: u16 = 0x4001;
    pub const ENABLE_CLOCK_FAIL: u16 = 0x4002;
    pub const DISABLE_CLOCK: u16 = 0x4003;
    pub const DISABLE_CLOCK_OK: u16 = 0x4004;

    // Reset control
    pub const DEASSERT_RESET: u16 = 0x4005;
    pub const DEASSERT_RESET_OK: u16 = 0x4006;
    pub const DEASSERT_RESET_FAIL: u16 = 0x4007;
    pub const ASSERT_RESET: u16 = 0x4008;
    pub const ASSERT_RESET_OK: u16 = 0x4009;

    // Power domain control
    pub const ENABLE_POWER: u16 = 0x4010;
    pub const ENABLE_POWER_OK: u16 = 0x4011;
    pub const ENABLE_POWER_FAIL: u16 = 0x4012;
    pub const DISABLE_POWER: u16 = 0x4013;
    pub const DISABLE_POWER_OK: u16 = 0x4014;

    // Board info
    pub const GET_MAC_ADDRESS: u16 = 0x4020;
    pub const MAC_ADDRESS_OK: u16 = 0x4021;
    pub const MAC_ADDRESS_FAIL: u16 = 0x4022;
    pub const GET_BOARD_SERIAL: u16 = 0x4030;
    pub const BOARD_SERIAL_OK: u16 = 0x4031;
    pub const GET_BOARD_REVISION: u16 = 0x4032;
    pub const BOARD_REVISION_OK: u16 = 0x4033;
    pub const SET_CLOCK_RATE: u16 = 0x4034;
    pub const SET_CLOCK_RATE_OK: u16 = 0x4035;
};

pub const Error = error{
    PlatformNotFound,
    LookupFailed,
    SendFailed,
    RecvFailed,
    RecvTimeout,
    OperationFailed,
};

// Cached platform container ID (lazy lookup)
var cached_platform_id: ?u16 = null;

const ERROR_BASE: u64 = 0xFFFF_FFFF_0000_0000;

fn isError(value: u64) bool {
    return value >= ERROR_BASE;
}

/// Get the platform container ID, looking it up if not cached.
/// Uses ns_lookup for non-blocking lookup (platform should already be registered).
pub fn getPlatformId() Error!u16 {
    if (cached_platform_id) |id| return id;

    const result = sys.ns_lookup(@ptrCast("platform".ptr), "platform".len);
    if (isError(result)) {
        return Error.LookupFailed;
    }

    cached_platform_id = @truncate(result);
    return cached_platform_id.?;
}

/// Clear cached platform ID (useful if platform container restarts)
pub fn clearCache() void {
    cached_platform_id = null;
}

/// Send a platform request and wait for response.
/// Returns the response message on success.
fn callPlatform(msg_type: u16, id: u32) Error!sys.Message {
    const platform = try getPlatformId();

    var msg: sys.Message = undefined;
    msg.msg_type = msg_type;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    @as(*align(1) u32, @ptrCast(&msg.payload[0])).* = id;

    const send_result = sys.icc_send(platform, &msg);
    if (isError(send_result)) {
        return Error.SendFailed;
    }

    // Wait for response (5 second timeout)
    var response: sys.Message = undefined;
    const recv_result = sys.icc_recv(&response, 5_000_000_000);
    if (isError(recv_result)) {
        return Error.RecvTimeout;
    }

    return response;
}

//------------------------------------------------------------------------------
// Clock Control
//------------------------------------------------------------------------------

/// Enable a clock by ID. The clock ID is platform-specific.
/// On QEMU virt: Always succeeds (no-op).
/// On BCM2711: Uses VideoCore mailbox.
pub fn enableClock(clock_id: u32) Error!void {
    const response = try callPlatform(Msg.ENABLE_CLOCK, clock_id);
    if (response.msg_type != Msg.ENABLE_CLOCK_OK) {
        return Error.OperationFailed;
    }
}

/// Disable a clock by ID.
pub fn disableClock(clock_id: u32) Error!void {
    const response = try callPlatform(Msg.DISABLE_CLOCK, clock_id);
    if (response.msg_type != Msg.DISABLE_CLOCK_OK) {
        return Error.OperationFailed;
    }
}

//------------------------------------------------------------------------------
// Reset Control
//------------------------------------------------------------------------------

/// Deassert reset (bring device out of reset).
/// Must be called after enabling power and clocks.
pub fn deassertReset(reset_id: u32) Error!void {
    const response = try callPlatform(Msg.DEASSERT_RESET, reset_id);
    if (response.msg_type != Msg.DEASSERT_RESET_OK) {
        return Error.OperationFailed;
    }
}

/// Assert reset (put device into reset).
pub fn assertReset(reset_id: u32) Error!void {
    const response = try callPlatform(Msg.ASSERT_RESET, reset_id);
    if (response.msg_type != Msg.ASSERT_RESET_OK) {
        return Error.OperationFailed;
    }
}

//------------------------------------------------------------------------------
// Power Domain Control
//------------------------------------------------------------------------------

/// Enable a power domain by ID.
pub fn enablePower(power_id: u32) Error!void {
    const response = try callPlatform(Msg.ENABLE_POWER, power_id);
    if (response.msg_type != Msg.ENABLE_POWER_OK) {
        return Error.OperationFailed;
    }
}

/// Disable a power domain by ID.
pub fn disablePower(power_id: u32) Error!void {
    const response = try callPlatform(Msg.DISABLE_POWER, power_id);
    if (response.msg_type != Msg.DISABLE_POWER_OK) {
        return Error.OperationFailed;
    }
}

//------------------------------------------------------------------------------
// Board Information
//------------------------------------------------------------------------------

/// Get MAC address from platform (OTP/EEPROM).
/// Returns 6-byte MAC address on success.
pub fn getMac() Error![6]u8 {
    const platform = try getPlatformId();

    var msg: sys.Message = undefined;
    msg.msg_type = Msg.GET_MAC_ADDRESS;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    const send_result = sys.icc_send(platform, &msg);
    if (isError(send_result)) {
        return Error.SendFailed;
    }

    var response: sys.Message = undefined;
    const recv_result = sys.icc_recv(&response, 5_000_000_000);
    if (isError(recv_result)) {
        return Error.RecvTimeout;
    }

    if (response.msg_type != Msg.MAC_ADDRESS_OK) {
        return Error.OperationFailed;
    }

    var mac: [6]u8 = undefined;
    for (&mac, 0..) |*byte, i| {
        byte.* = response.payload[i];
    }
    return mac;
}

/// Get board serial number.
/// Returns 8-byte serial number on success.
pub fn getBoardSerial() Error!u64 {
    const platform = try getPlatformId();

    var msg: sys.Message = undefined;
    msg.msg_type = Msg.GET_BOARD_SERIAL;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    const send_result = sys.icc_send(platform, &msg);
    if (isError(send_result)) {
        return Error.SendFailed;
    }

    var response: sys.Message = undefined;
    const recv_result = sys.icc_recv(&response, 5_000_000_000);
    if (isError(recv_result)) {
        return Error.RecvTimeout;
    }

    if (response.msg_type != Msg.BOARD_SERIAL_OK) {
        return Error.OperationFailed;
    }

    return @as(*align(1) const u64, @ptrCast(&response.payload[0])).*;
}

/// Get board revision.
/// Returns revision code on success.
pub fn getBoardRevision() Error!u32 {
    const platform = try getPlatformId();

    var msg: sys.Message = undefined;
    msg.msg_type = Msg.GET_BOARD_REVISION;
    msg.flags = 0;
    @memset(&msg.payload, 0);

    const send_result = sys.icc_send(platform, &msg);
    if (isError(send_result)) {
        return Error.SendFailed;
    }

    var response: sys.Message = undefined;
    const recv_result = sys.icc_recv(&response, 5_000_000_000);
    if (isError(recv_result)) {
        return Error.RecvTimeout;
    }

    if (response.msg_type != Msg.BOARD_REVISION_OK) {
        return Error.OperationFailed;
    }

    return @as(*align(1) const u32, @ptrCast(&response.payload[0])).*;
}

//------------------------------------------------------------------------------
// Clock Rate Control
//------------------------------------------------------------------------------

/// Set clock rate in Hz.
/// The payload contains: clock_id (u32) at offset 0, rate (u64) at offset 4.
pub fn setClockRate(clock_id: u32, rate_hz: u64) Error!void {
    const platform = try getPlatformId();

    var msg: sys.Message = undefined;
    msg.msg_type = Msg.SET_CLOCK_RATE;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    @as(*align(1) u32, @ptrCast(&msg.payload[0])).* = clock_id;
    @as(*align(1) u64, @ptrCast(&msg.payload[4])).* = rate_hz;

    const send_result = sys.icc_send(platform, &msg);
    if (isError(send_result)) {
        return Error.SendFailed;
    }

    var response: sys.Message = undefined;
    const recv_result = sys.icc_recv(&response, 5_000_000_000);
    if (isError(recv_result)) {
        return Error.RecvTimeout;
    }

    if (response.msg_type != Msg.SET_CLOCK_RATE_OK) {
        return Error.OperationFailed;
    }
}
