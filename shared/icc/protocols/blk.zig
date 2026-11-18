//------------------------------------------------------------------------------
// Block Driver Protocol -- Method specs for `lib/blk_client/`
//------------------------------------------------------------------------------
//
// Single source of truth for the block driver's ICC message format. The
// client lib (`lib/blk_client/api.zig`) imports this; the driver
// (`user/drivers/blkd.zig`) imports this; the kernel never touches it.
//
// Specs follow the `lib/man/rpc.zig` Method-spec convention:
//   - REQ_TYPE / REPLY_TYPE constants.
//   - Request / Reply struct types.
//   - serialize(req, payload) writing into a 248-byte mailbox payload.
//   - deserialize(payload) returning a Reply.
//
// Message-type allocation: 0x3000-0x3005 is the block driver's range. See
// `src/shared/icc/schema.zig` for the kernel-wide range registry.
//
// Import-free by design (the_law/HARDLINE.md section 5), amended by L1.1
// (the_law/adoption_plan.md) to allow exactly one leaf import:
// `src/shared/icc/contract.zig`, itself import-free. It supplies the
// CONTRACT_HASH computation below.
//
//------------------------------------------------------------------------------

const contract = @import("contract");

/// Channel-message payload size. Mirrors `src/shared/icc/schema.zig` PAYLOAD_SIZE --
/// this module is import-free by design; lib/root.zig asserts the mirror.
pub const PAYLOAD_SIZE = 248;

/// Namespace name registered by the block driver at boot.
/// The client looks this up via `ns_lookup` to discover the peer ID.
pub const NAMESPACE: []const u8 = "blk.driver";

/// Logical block (sector) size in bytes. VirtIO-Block sectors are 512 bytes.
pub const SECTOR_SIZE: u32 = 512;

/// Shared-memory transfer geometry. Sector data no longer rides in the ICC
/// payload (which capped transfers at 240 bytes and silently truncated real
/// 512-byte sectors). Instead the client owns an SHM region of
/// `SHM_REGION_PAGES` pages, binds it onto the blk pair, and passes the
/// pair-local grant_ref in the request. The driver `map_attach`es via the
/// receiving endpoint. Sector data lives at byte 0 of the region. The
/// driver caps `count` at `SHM_MAX_SECTORS` so it never addresses past the
/// region a well-behaved client allocated.
pub const SHM_MAX_SECTORS: u16 = 128; // 64 KiB max transfer per request
pub const SHM_REGION_BYTES: usize = @as(usize, SECTOR_SIZE) * SHM_MAX_SECTORS;
pub const SHM_REGION_PAGES: u64 = (SHM_REGION_BYTES + 4095) / 4096; // 16

/// Message type constants. Kept as a flat namespace so the driver's dispatch
/// switch can use `BlkMsgType.READ_REQUEST`, etc.
pub const BlkMsgType = struct {
    pub const READ_REQUEST: u16 = 0x3000;
    pub const READ_RESPONSE: u16 = 0x3001;
    pub const WRITE_REQUEST: u16 = 0x3002;
    pub const WRITE_RESPONSE: u16 = 0x3003;
    pub const GET_INFO: u16 = 0x3004;
    pub const INFO_RESPONSE: u16 = 0x3005;
};

/// IPC status codes returned in the leading byte of READ_RESPONSE /
/// WRITE_RESPONSE payloads. The driver also emits these into its own
/// internal logs; they are intentionally narrower than `errors.zig` because
/// block I/O failure modes are limited.
pub const BlkStatus = struct {
    pub const OK: u8 = 0;
    pub const IO_ERROR: u8 = 1;
    pub const INVALID_SECTOR: u8 = 2;
    pub const INVALID_COUNT: u8 = 3;
    pub const NOT_READY: u8 = 4;
    /// The driver could not attach or validate the caller's SHM region.
    pub const SHM_ERROR: u8 = 5;
};

//------------------------------------------------------------------------------
// Helpers -- packed-byte encode / decode for unaligned payload offsets.
//------------------------------------------------------------------------------

inline fn writeU64(payload: *[PAYLOAD_SIZE]u8, offset: usize, value: u64) void {
    @as(*align(1) u64, @ptrCast(&payload[offset])).* = value;
}

inline fn readU64(payload: *const [PAYLOAD_SIZE]u8, offset: usize) u64 {
    return @as(*align(1) const u64, @ptrCast(&payload[offset])).*;
}

inline fn writeU32(payload: *[PAYLOAD_SIZE]u8, offset: usize, value: u32) void {
    @as(*align(1) u32, @ptrCast(&payload[offset])).* = value;
}

inline fn readU32(payload: *const [PAYLOAD_SIZE]u8, offset: usize) u32 {
    return @as(*align(1) const u32, @ptrCast(&payload[offset])).*;
}

inline fn writeU16(payload: *[PAYLOAD_SIZE]u8, offset: usize, value: u16) void {
    @as(*align(1) u16, @ptrCast(&payload[offset])).* = value;
}

//------------------------------------------------------------------------------
// GetDeviceInfo -- query device capacity + sector size
//------------------------------------------------------------------------------

pub const GetDeviceInfo = struct {
    pub const REQ_TYPE: u16 = BlkMsgType.GET_INFO;
    pub const REPLY_TYPE: u16 = BlkMsgType.INFO_RESPONSE;

    pub const Request = struct {};
    pub const Reply = extern struct { capacity: u64, sector_size: u32 };

    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .capacity = readU64(payload, 0),
            .sector_size = readU32(payload, 8),
        };
    }
};

//------------------------------------------------------------------------------
// ReadSector -- read `count` sectors starting at `sector` into the caller's
// SHM region.
//
// Request layout:  [sector:u64 @0][count:u16 @8][_pad:2][grant_ref:u32 @12].
// Reply layout:    [status:u8 @0][_pad:3][bytes:u32 @4].
//
// The driver writes `count * SECTOR_SIZE` bytes into the region at offset 0,
// then replies with the byte count it transferred (0 on failure). No sector
// data rides the mailbox.
//------------------------------------------------------------------------------

pub const ReadSector = struct {
    pub const REQ_TYPE: u16 = BlkMsgType.READ_REQUEST;
    pub const REPLY_TYPE: u16 = BlkMsgType.READ_RESPONSE;

    pub const Request = extern struct { sector: u64, count: u16, grant_ref: u32 };
    pub const Reply = extern struct { status: u8, bytes: u32 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, 0, req.sector);
        writeU16(payload, 8, req.count);
        writeU32(payload, 12, req.grant_ref);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .status = payload[0], .bytes = readU32(payload, 4) };
    }
};

//------------------------------------------------------------------------------
// WriteSector -- write `count` sectors starting at `sector` from the caller's
// SHM region.
//
// Request layout: [sector:u64 @0][count:u16 @8][_pad:2][grant_ref:u32 @12].
// Reply layout:   [status:u8 @0].
//
// The caller stages `count * SECTOR_SIZE` bytes at offset 0 of the region
// before sending; the driver `map_attach`es read-only and copies to disk.
//------------------------------------------------------------------------------

pub const WriteSector = struct {
    pub const REQ_TYPE: u16 = BlkMsgType.WRITE_REQUEST;
    pub const REPLY_TYPE: u16 = BlkMsgType.WRITE_RESPONSE;

    pub const Request = extern struct { sector: u64, count: u16, grant_ref: u32 };
    pub const Reply = extern struct { status: u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, 0, req.sector);
        writeU16(payload, 8, req.count);
        writeU32(payload, 12, req.grant_ref);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .status = payload[0] };
    }
};

//------------------------------------------------------------------------------
// Contract hash (L1.1) -- wire-time refusal between mismatched trees.
//------------------------------------------------------------------------------

pub const CONTRACT_VERSION: u16 = 3;

/// Method specs in wire order. Single source for both the CONTRACT_HASH walk
/// and `tools/gen_docs.zig`'s contract reference (docs/api/contracts.md).
pub const SPECS = .{ GetDeviceInfo, ReadSector, WriteSector };

pub const CONTRACT_HASH: u64 = contract.hashSpecs(SPECS, NAMESPACE, CONTRACT_VERSION);

// The contract hash and gen_docs derive field offsets from the structs via
// @offsetOf while serialize()/deserialize() hand-write byte offsets. The
// structs are `extern` so their layout is defined, and these asserts pin the
// two views together -- drift is a compile error, not a doc lie.
comptime {
    if (@offsetOf(ReadSector.Request, "sector") != 0 or
        @offsetOf(ReadSector.Request, "count") != 8 or
        @offsetOf(ReadSector.Request, "grant_ref") != 12)
        @compileError("blk: ReadSector.Request layout drifted from serialize()");
    if (@offsetOf(WriteSector.Request, "sector") != 0 or
        @offsetOf(WriteSector.Request, "count") != 8 or
        @offsetOf(WriteSector.Request, "grant_ref") != 12)
        @compileError("blk: WriteSector.Request layout drifted from serialize()");
    if (@offsetOf(ReadSector.Reply, "status") != 0 or
        @offsetOf(ReadSector.Reply, "bytes") != 4)
        @compileError("blk: ReadSector.Reply layout drifted from deserialize()");
    if (@offsetOf(GetDeviceInfo.Reply, "capacity") != 0 or
        @offsetOf(GetDeviceInfo.Reply, "sector_size") != 8)
        @compileError("blk: GetDeviceInfo.Reply layout drifted from deserialize()");
}
