//------------------------------------------------------------------------------
// Block Client -- RPC stub for the block driver
//------------------------------------------------------------------------------
//
// User programs call into the block driver for sector read/write and device
// info without speaking the raw ICC envelope. L4-MIGRATED: the blk bundle
// arrives at spawn via the manifest `requires` edge (spawn-fold); discovery
// is channel.requiredChannel(hash) -- no ns_lookup, no CONTRACT_HELLO (the
// wire-time hash check already enforced contract agreement).
//
// Sector data crosses via a client-owned SHM transfer region (created lazily,
// reused across calls); only the request header rides the ICC mailbox, so
// transfers up to MAX_SECTORS * SECTOR_SIZE round-trip intact.
//
// Usage:
//   const blk = @import("liblaminae").blk_client;
//   try blk.init();                       // optional pre-warm; first call also resolves
//   const info = try blk.getDeviceInfo();
//   var buf: [blk.SECTOR_SIZE]u8 = undefined;
//   const status = try blk.readSectors(0, 1, &buf);
//
//------------------------------------------------------------------------------

const rpc = @import("../man/rpc.zig");
const channel = @import("../man/channel.zig");
const sys = @import("../gen/syscalls.zig");
const proto = @import("blk_protocol");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Thin RPC client of the block driver -- bounded-timeout ICC for I/O ops.
/// Peer-dependent, hence T2.
pub const tier: u8 = 2;

/// Re-export protocol vocabulary for callers that need raw constants.
pub const BlkMsgType = proto.BlkMsgType;
pub const BlkStatus = proto.BlkStatus;
pub const SECTOR_SIZE = proto.SECTOR_SIZE;
pub const MAX_SECTORS = proto.SHM_MAX_SECTORS;

/// `getDeviceInfo` shape (capacity in sectors + sector size in bytes).
pub const DeviceInfo = proto.GetDeviceInfo.Reply;

pub const Error = error{
    DriverNotFound,
    /// L1.1 (the_law/adoption_plan.md): blkd is reachable but its protocol
    /// module's CONTRACT_HASH disagrees with ours -- refused at wire time
    /// rather than misinterpreting payload bytes.
    ContractMismatch,
    /// blkd replied with a non-OK BlkStatus byte. Callers that want the
    /// concrete status (IO_ERROR / INVALID_SECTOR / ...) should call the
    /// raw variants below.
    BlkFailed,
    /// Could not allocate or publish the client-side SHM transfer region.
    ShmFailed,
    /// Caller asked for more sectors than a single transfer region holds
    /// (`MAX_SECTORS`) or `count == 0`.
    InvalidCount,
    /// Caller buffer is smaller than `count * SECTOR_SIZE`.
    BufferTooSmall,
} || rpc.RpcError;

// 5-second timeout matches `test_blk.zig`'s old hard-coded value -- generous
// enough for a virtio-blk under load, short enough to fail a missing or
// hung driver promptly.
const READ_TIMEOUT: rpc.Timeout = .{ .ms = 5000 };
const WRITE_TIMEOUT: rpc.Timeout = .{ .ms = 5000 };
const INFO_TIMEOUT: rpc.Timeout = .{ .ms = 2000 };

const ERROR_BASE: u64 = 0xFFFF_FFFF_0000_0000;

inline fn isErr(v: u64) bool {
    return v >= ERROR_BASE;
}

var cached_ch: ?channel.Channel = null;

// Persistent SHM transfer region: created lazily on first I/O, reused across
// calls, and torn down by `clearCache`. The client is the region owner; if it
// dies mid-request the kernel registry keeps the pages alive (refcount) until
// the driver detaches, then reclaims them (region_lifecycle_contract RL.15).
var region_token: ?u32 = null;
var region_va: u64 = 0;
var region_grant: u32 = 0;

fn ensureRegion() Error!void {
    if (region_token != null) return;
    const ch = try getChannel();
    const created = sys.map_create(proto.SHM_REGION_PAGES, 0);
    if (isErr(created)) return Error.ShmFailed;
    const token = sys.MapResult.token(created);
    const grant = sys.map_bind(token, ch.out);
    if (isErr(grant) or grant == 0) {
        _ = sys.map_detach(token);
        return Error.ShmFailed;
    }
    region_token = token;
    region_va = sys.MapResult.va(created);
    region_grant = @truncate(grant);
}

inline fn regionData() [*]volatile u8 {
    return @ptrFromInt(region_va);
}

fn getChannel() Error!channel.Channel {
    if (cached_ch) |c| return c;
    // Sweep dead pairs first so a replayed fresh bundle is unambiguous and
    // respawn cycles cannot accrete toward the endpoint budget (post-land
    // review, grok finding 3).
    _ = channel.reclaimClosed(proto.CONTRACT_HASH);
    const c = channel.requiredChannel(proto.CONTRACT_HASH) catch return Error.DriverNotFound;
    cached_ch = c;
    return c;
}

/// Resolve and cache the block bundle. Optional -- the typed wrappers
/// below resolve on first call. Use this to pre-warm during init or to
/// fail-fast if no blk bundle was folded in at spawn.
pub fn init() Error!void {
    _ = try getChannel();
}

/// Clear the cached peer handle and release the SHM transfer region. Useful
/// if blkd is killed and respawns (the stale peer id is dropped and the next
/// call re-resolves and re-publishes a fresh region handle).
pub fn clearCache() void {
    cached_ch = null;
    if (region_token) |token| {
        _ = sys.map_detach(token);
        region_token = null;
        region_va = 0;
        region_grant = 0;
    }
}

/// The block driver's raw cell id (from the bundle's wired-peer identity).
pub fn getDriverId() Error!u16 {
    const ch = try getChannel();
    return @truncate(ch.peer);
}

//------------------------------------------------------------------------------
// Typed RPC ops
//------------------------------------------------------------------------------

/// Map channel-RPC errors to the client's `Error` set. PeerClosed (blkd
/// died; lamina re-wires on respawn) drops the stale bundle and surfaces
/// DriverNotFound so the caller re-acquires after the re-wire.
fn mapRpcErr(err: channel.CallError) Error {
    return switch (err) {
        channel.CallError.InvalidProtocol => Error.BlkFailed,
        channel.CallError.PeerClosed => blk: {
            cached_ch = null;
            break :blk Error.DriverNotFound;
        },
        channel.CallError.TimedOut => Error.TimedOut,
        channel.CallError.IccError => Error.IccError,
    };
}

/// Query device capacity (in sectors) and sector size (in bytes).
pub fn getDeviceInfo() Error!DeviceInfo {
    const ch = try getChannel();
    return channel.call(ch, proto.GetDeviceInfo, .{}, INFO_TIMEOUT) catch |err| mapRpcErr(err);
}

fn checkTransfer(count: u16, buf_len: usize) Error!usize {
    if (count == 0 or count > MAX_SECTORS) return Error.InvalidCount;
    const bytes = @as(usize, count) * SECTOR_SIZE;
    if (buf_len < bytes) return Error.BufferTooSmall;
    return bytes;
}

/// Read `count` sectors starting at `sector` into `out`. Data crosses via the
/// shared-memory transfer region, so full 512-byte sectors (and multi-sector
/// runs up to `MAX_SECTORS`) round-trip intact -- no 240-byte truncation.
/// `out` must be at least `count * SECTOR_SIZE` bytes. Returns the raw
/// `BlkStatus` byte (`OK` on success).
pub fn readSectors(sector: u64, count: u16, out: []u8) Error!u8 {
    const bytes = try checkTransfer(count, out.len);
    try ensureRegion();
    const ch = try getChannel();
    const reply = channel.call(
        ch,
        proto.ReadSector,
        .{ .sector = sector, .count = count, .grant_ref = region_grant },
        READ_TIMEOUT,
    ) catch |err| return mapRpcErr(err);
    if (reply.status == BlkStatus.OK) {
        const src = regionData();
        for (0..bytes) |i| out[i] = src[i];
    }
    return reply.status;
}

/// Same as `readSectors` but maps non-OK status to `Error.BlkFailed`. Use
/// when the caller doesn't care which BlkStatus variant occurred.
pub fn readSectorsErr(sector: u64, count: u16, out: []u8) Error!void {
    const status = try readSectors(sector, count, out);
    if (status != BlkStatus.OK) return Error.BlkFailed;
}

/// Write `count` sectors starting at `sector` from `data`. Data crosses via
/// the shared-memory transfer region. `data` must be at least
/// `count * SECTOR_SIZE` bytes. Returns the raw `BlkStatus` byte.
pub fn writeSectors(sector: u64, count: u16, data: []const u8) Error!u8 {
    const bytes = try checkTransfer(count, data.len);
    try ensureRegion();
    const dst = regionData();
    for (0..bytes) |i| dst[i] = data[i];
    const ch = try getChannel();
    const reply = channel.call(
        ch,
        proto.WriteSector,
        .{ .sector = sector, .count = count, .grant_ref = region_grant },
        WRITE_TIMEOUT,
    ) catch |err| return mapRpcErr(err);
    return reply.status;
}
