//------------------------------------------------------------------------------
// Platform Client — RPC stub for the platform container
//------------------------------------------------------------------------------
//
// Drivers call into the platform container for clock/power/reset/board-info
// operations without knowing the underlying SoC details. The platform
// container handles the platform-specific work (mailbox/PSCI/PMIC/etc.);
// drivers see a uniform interface.
//
// Usage:
//   const platform = @import("liblaminae").platform_client;
//   try platform.enableClock(clock_id);
//   const mac = try platform.getMac();
//
//------------------------------------------------------------------------------

const rpc = @import("../man/rpc.zig");
const proto = @import("platform_protocol");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Thin RPC client of the platform container -- bounded-timeout ICC for
/// clock/power/reset ops. Peer-dependent, hence T2.
pub const tier: u8 = 2;

/// Re-export protocol constants for callers that need raw message types.
pub const PlatformMsgType = proto.PlatformMsgType;

pub const Error = error{
    PlatformNotFound,
    OperationFailed,
} || rpc.RpcError;

// 5-second timeout matches the original lib/man/platform.zig timing — long
// enough that a busy platform peer (e.g. waiting on real PSCI calls on
// MS-R1) won't timeout under load, short enough that a missing peer fails
// the boot sequence rather than hanging forever.
const PLATFORM_TIMEOUT: rpc.Timeout = .{ .ms = 5000 };

// Cached peer handle (lazy ns_lookup, mirrors the prior platform.zig pattern).
var cached_peer: ?rpc.PeerHandle = null;

fn getPeer() Error!rpc.PeerHandle {
    if (cached_peer) |p| return p;
    const p = rpc.PeerHandle.lookup(proto.NAMESPACE) catch return Error.PlatformNotFound;
    cached_peer = p;
    return p;
}

/// Clear the cached peer handle. Useful if the platform container restarts
/// and needs to be re-discovered.
pub fn clearCache() void {
    cached_peer = null;
}

/// Resolve the platform container ID, doing the namespace lookup on first
/// call and serving from cache thereafter. Useful for callers that want to
/// send raw ICC messages bypassing the typed wrappers (e.g. driver tests
/// asserting the lookup path itself).
pub fn getPlatformId() Error!u16 {
    const peer = try getPeer();
    return peer.id;
}

/// Resolve the platform peer, issue the RPC, and translate the generic
/// `InvalidProtocol` (peer replied with the wrong msg_type) into the
/// platform-domain `OperationFailed`. Used by both void-reply and
/// typed-reply wrappers below.
fn callRpc(comptime Spec: type, req: Spec.Request) Error!Spec.Reply {
    const peer = try getPeer();
    return rpc.call(peer, Spec, req, PLATFORM_TIMEOUT) catch |err|
        if (err == rpc.RpcError.InvalidProtocol) Error.OperationFailed else err;
}

fn callVoid(comptime Spec: type, req: Spec.Request) Error!void {
    _ = try callRpc(Spec, req);
}

//------------------------------------------------------------------------------
// Clock control
//------------------------------------------------------------------------------

pub fn enableClock(clock_id: u32) Error!void {
    return callVoid(proto.EnableClock, .{ .clock_id = clock_id });
}

pub fn disableClock(clock_id: u32) Error!void {
    return callVoid(proto.DisableClock, .{ .clock_id = clock_id });
}

pub fn setClockRate(clock_id: u32, rate_hz: u64) Error!void {
    return callVoid(proto.SetClockRate, .{ .clock_id = clock_id, .rate_hz = rate_hz });
}

//------------------------------------------------------------------------------
// Reset control
//------------------------------------------------------------------------------

pub fn deassertReset(reset_id: u32) Error!void {
    return callVoid(proto.DeassertReset, .{ .reset_id = reset_id });
}

pub fn assertReset(reset_id: u32) Error!void {
    return callVoid(proto.AssertReset, .{ .reset_id = reset_id });
}

//------------------------------------------------------------------------------
// Power domain control
//------------------------------------------------------------------------------

pub fn enablePower(power_id: u32) Error!void {
    return callVoid(proto.EnablePower, .{ .power_id = power_id });
}

pub fn disablePower(power_id: u32) Error!void {
    return callVoid(proto.DisablePower, .{ .power_id = power_id });
}

//------------------------------------------------------------------------------
// Board information
//------------------------------------------------------------------------------

pub fn getMac() Error![6]u8 {
    return (try callRpc(proto.GetMac, .{})).mac;
}

pub fn getBoardSerial() Error!u64 {
    return (try callRpc(proto.GetBoardSerial, .{})).serial;
}

pub fn getBoardRevision() Error!u32 {
    return (try callRpc(proto.GetBoardRevision, .{})).revision;
}
