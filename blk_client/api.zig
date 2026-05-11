//------------------------------------------------------------------------------
// Block Client — RPC stub for the block driver
//------------------------------------------------------------------------------
//
// User programs call into the block driver for sector read/write and device
// info without speaking the raw ICC envelope. The driver registers as
// `blk.driver`; this client looks it up lazily and caches the peer ID.
//
// Usage:
//   const blk = @import("liblaminae").blk_client;
//   try blk.init();                       // optional pre-warm; first call also resolves
//   const info = try blk.getDeviceInfo();
//   const status = try blk.readSector(0, &buf);
//
//------------------------------------------------------------------------------

const rpc = @import("../man/rpc.zig");
const proto = @import("blk_protocol");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Thin RPC client of the block driver -- bounded-timeout ICC for I/O ops.
/// Peer-dependent, hence T2.
pub const tier: u8 = 2;

/// Re-export protocol vocabulary for callers that need raw constants.
pub const BlkMsgType = proto.BlkMsgType;
pub const BlkStatus = proto.BlkStatus;
pub const MAX_PAYLOAD_DATA = proto.MAX_PAYLOAD_DATA;

/// `getDeviceInfo` shape (capacity in sectors + sector size in bytes).
pub const DeviceInfo = proto.GetDeviceInfo.Reply;

pub const Error = error{
    DriverNotFound,
    /// blkd replied with a non-OK BlkStatus byte. Callers that want the
    /// concrete status (IO_ERROR / INVALID_SECTOR / ...) should call the
    /// raw variants below.
    BlkFailed,
} || rpc.RpcError;

// 5-second timeout matches `test_blk.zig`'s old hard-coded value -- generous
// enough for a virtio-blk under load, short enough to fail a missing or
// hung driver promptly.
const READ_TIMEOUT: rpc.Timeout = .{ .ms = 5000 };
const WRITE_TIMEOUT: rpc.Timeout = .{ .ms = 5000 };
const INFO_TIMEOUT: rpc.Timeout = .{ .ms = 2000 };

var cached_peer: ?rpc.PeerHandle = null;

fn getPeer() Error!rpc.PeerHandle {
    if (cached_peer) |p| return p;
    const p = rpc.PeerHandle.lookup(proto.NAMESPACE) catch return Error.DriverNotFound;
    cached_peer = p;
    return p;
}

/// Resolve and cache the block driver peer. Optional -- the typed wrappers
/// below resolve on first call. Use this to pre-warm during init or to
/// fail-fast if the driver isn't registered yet.
pub fn init() Error!void {
    _ = try getPeer();
}

/// Clear the cached peer handle. Useful if blkd is killed and respawns.
pub fn clearCache() void {
    cached_peer = null;
}

/// Resolve the block driver container ID.
pub fn getDriverId() Error!u16 {
    const peer = try getPeer();
    return peer.id;
}

//------------------------------------------------------------------------------
// Typed RPC ops
//------------------------------------------------------------------------------

/// Map `rpc.call` errors to the client's `Error` set, normalising
/// `InvalidProtocol` (driver replied with the wrong message type) to
/// `BlkFailed` so callers don't need to know about the RPC layer's
/// vocabulary.
fn mapRpcErr(err: rpc.RpcError) Error {
    return if (err == rpc.RpcError.InvalidProtocol) Error.BlkFailed else err;
}

/// Query device capacity (in sectors) and sector size (in bytes).
pub fn getDeviceInfo() Error!DeviceInfo {
    const peer = try getPeer();
    return rpc.call(peer, proto.GetDeviceInfo, .{}, INFO_TIMEOUT) catch |err| mapRpcErr(err);
}

/// Read a single sector. `out` receives up to `MAX_PAYLOAD_DATA` (240) bytes
/// of sector data. Returns the raw `BlkStatus` byte (`OK` on success);
/// callers that prefer an error union can use `readSectorErr`.
pub fn readSector(sector: u64, out: *[MAX_PAYLOAD_DATA]u8) Error!u8 {
    const peer = try getPeer();
    const reply = rpc.call(peer, proto.ReadSector, .{ .sector = sector, .count = 1 }, READ_TIMEOUT) catch |err|
        return mapRpcErr(err);
    @memcpy(out, &reply.data);
    return reply.status;
}

/// Same as `readSector` but maps non-OK status to `Error.BlkFailed`. Use
/// when the caller doesn't care which BlkStatus variant occurred.
pub fn readSectorErr(sector: u64, out: *[MAX_PAYLOAD_DATA]u8) Error!void {
    const status = try readSector(sector, out);
    if (status != BlkStatus.OK) return Error.BlkFailed;
}

/// Write up to `MAX_PAYLOAD_DATA` (240) bytes to `sector`. Larger payloads
/// are truncated; the protocol does not yet support multi-message transfer.
/// Returns the raw `BlkStatus` byte.
pub fn writeSector(sector: u64, data: []const u8) Error!u8 {
    const peer = try getPeer();
    const reply = rpc.call(
        peer,
        proto.WriteSector,
        .{ .sector = sector, .count = 1, .data = data },
        WRITE_TIMEOUT,
    ) catch |err| return mapRpcErr(err);
    return reply.status;
}
