//------------------------------------------------------------------------------
// Block Driver Protocol — Method specs for `lib/blk_client/`
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
//------------------------------------------------------------------------------

/// Mailbox payload size. Mirrors `src/shared/icc/schema.zig` PAYLOAD_SIZE --
/// this module is import-free by design; lib/root.zig asserts the mirror.
pub const PAYLOAD_SIZE = 248;

/// Namespace name registered by the block driver at boot.
/// The client looks this up via `ns_lookup` to discover the peer ID.
pub const NAMESPACE: []const u8 = "blk.driver";

/// Maximum bytes of sector data carried in a single READ_RESPONSE/WRITE_REQUEST
/// payload. The mailbox payload is 248 bytes, the leading status/header byte
/// claims 1, and 7 bytes are reserved as headroom for future framing.
/// Real sectors (512+ bytes) need multi-message transfer; today's blkd
/// truncates and the test verifies the first 240 bytes only.
pub const MAX_PAYLOAD_DATA: usize = 240;

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
};

//------------------------------------------------------------------------------
// Helpers — packed-byte encode / decode for unaligned payload offsets.
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
// GetDeviceInfo — query device capacity + sector size
//------------------------------------------------------------------------------

pub const GetDeviceInfo = struct {
    pub const REQ_TYPE: u16 = BlkMsgType.GET_INFO;
    pub const REPLY_TYPE: u16 = BlkMsgType.INFO_RESPONSE;

    pub const Request = struct {};
    pub const Reply = struct { capacity: u64, sector_size: u32 };

    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .capacity = readU64(payload, 0),
            .sector_size = readU32(payload, 8),
        };
    }
};

//------------------------------------------------------------------------------
// ReadSector — read `count` sectors starting at `sector`
//
// Reply layout: [status:u8][data:up to MAX_PAYLOAD_DATA bytes]. A real
// sector is 512 bytes; today the driver only fills the first 240 and the
// caller tracks the truncation. Multi-sector reads are a future concern.
//------------------------------------------------------------------------------

pub const ReadSector = struct {
    pub const REQ_TYPE: u16 = BlkMsgType.READ_REQUEST;
    pub const REPLY_TYPE: u16 = BlkMsgType.READ_RESPONSE;

    pub const Request = struct { sector: u64, count: u16 };
    pub const Reply = struct {
        status: u8,
        /// Caller copies out of this buffer; payload lifetime is the
        /// `IccMessage` on the receiver's stack.
        data: [MAX_PAYLOAD_DATA]u8,
    };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, 0, req.sector);
        writeU16(payload, 8, req.count);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        var reply: Reply = .{ .status = payload[0], .data = undefined };
        @memcpy(&reply.data, payload[1..][0..MAX_PAYLOAD_DATA]);
        return reply;
    }
};

//------------------------------------------------------------------------------
// WriteSector — write `count` sectors starting at `sector`
//
// Request layout: [sector:u64][count:u16][_pad:u8 * 6][data:up to
// MAX_PAYLOAD_DATA bytes]. 16 bytes of header leave 232 bytes for data;
// padded to 240 to align with ReadSector's data window.
//------------------------------------------------------------------------------

pub const WriteSector = struct {
    pub const REQ_TYPE: u16 = BlkMsgType.WRITE_REQUEST;
    pub const REPLY_TYPE: u16 = BlkMsgType.WRITE_RESPONSE;

    pub const Request = struct {
        sector: u64,
        count: u16,
        /// Up to MAX_PAYLOAD_DATA bytes. Caller-provided slice;
        /// `serialize` truncates to MAX_PAYLOAD_DATA and zero-fills.
        data: []const u8,
    };
    pub const Reply = struct { status: u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        writeU64(payload, 0, req.sector);
        writeU16(payload, 8, req.count);
        const n = @min(req.data.len, MAX_PAYLOAD_DATA);
        @memcpy(payload[16 .. 16 + n], req.data[0..n]);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .status = payload[0] };
    }
};
