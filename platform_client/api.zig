//------------------------------------------------------------------------------
// Platform Client -- RPC stub for the platform cell
//------------------------------------------------------------------------------
//
// Drivers call into the platform cell for clock/power/reset/board-info
// operations without knowing the underlying SoC details. The platform
// cell handles the platform-specific work (mailbox/PSCI/PMIC/etc.);
// drivers see a uniform interface.
//
// Usage:
//   const platform = @import("liblaminae").platform_client;
//   try platform.enableClock(clock_id);
//   const mac = try platform.getMac();
//
//------------------------------------------------------------------------------

const rpc = @import("../man/rpc.zig");
const channel = @import("../man/channel.zig");
const proto = @import("platform_protocol");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Thin channel-RPC client of the platform cell. Peer-dependent, hence T2.
/// FIRST L4-MIGRATED CLIENT (channel_contract.md 15.2/15.3): the platform
/// bundle arrives at spawn via the manifest `requires` edge (spawn-fold),
/// discovery is channel.requiredChannel(hash) -- no ns_lookup, and no
/// CONTRACT_HELLO handshake: the wire-time hash check (CH.5) already
/// enforced contract agreement when lamina wired the bundle.
pub const tier: u8 = 2;

/// Re-export protocol constants for callers that need raw message types.
pub const PlatformMsgType = proto.PlatformMsgType;

pub const Error = error{
    PlatformNotFound,
    OperationFailed,
    /// Retained for API stability (wasm/blk peers still handshake); the
    /// channel path cannot produce it -- a hash mismatch refuses the WIRE.
    ContractMismatch,
} || rpc.RpcError;

// 5-second timeout matches the original lib/man/platform.zig timing -- long
// enough that a busy platform peer (e.g. waiting on real PSCI calls on
// MS-R1) won't timeout under load, short enough that a missing peer fails
// the boot sequence rather than hanging forever.
const PLATFORM_TIMEOUT: rpc.Timeout = .{ .ms = 5000 };

// Cached bundle (lazy self-snapshot discovery; the bundle itself was folded
// in at spawn, so discovery cannot race the provider).
var cached_ch: ?channel.Channel = null;

fn getChannel() Error!channel.Channel {
    if (cached_ch) |c| return c;
    // Sweep dead pairs first so a replayed fresh bundle is unambiguous and
    // respawn cycles cannot accrete toward the endpoint budget (post-land
    // review, grok finding 3).
    _ = channel.reclaimClosed(proto.CONTRACT_HASH);
    const c = channel.requiredChannel(proto.CONTRACT_HASH) catch return Error.PlatformNotFound;
    cached_ch = c;
    return c;
}

/// Clear the cached bundle. Useful if the platform cell restarts and a
/// fresh bundle is delivered (re-discovery via self-snapshot).
pub fn clearCache() void {
    cached_ch = null;
}

/// The platform provider's raw cell id (from the bundle's wired-peer
/// identity). Kept for callers/tests that assert the discovery path.
pub fn getPlatformId() Error!u16 {
    const ch = try getChannel();
    return @truncate(ch.peer);
}

/// Issue the RPC over the platform bundle and translate the generic
/// errors into the platform-domain set. PeerClosed (LAW 3: the provider
/// died; lamina re-wires on respawn) surfaces as PlatformNotFound after
/// dropping the stale cached bundle.
fn callRpc(comptime Spec: type, req: Spec.Request) Error!Spec.Reply {
    const ch = try getChannel();
    return channel.call(ch, Spec, req, PLATFORM_TIMEOUT) catch |err| switch (err) {
        channel.CallError.InvalidProtocol => Error.OperationFailed,
        channel.CallError.PeerClosed => blk: {
            cached_ch = null;
            break :blk Error.PlatformNotFound;
        },
        channel.CallError.TimedOut => Error.TimedOut,
        channel.CallError.IccError => Error.IccError,
    };
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
