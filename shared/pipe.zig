//------------------------------------------------------------------------------
// Pipe Region ABI - Streaming byte pipe between cells
//
// A pipe is one SHM region created and owned by a supervisor (normally the
// shell), attached by a writer cell and a reader cell. Data flows through an
// SPSC ByteRing; the supervisor wires cells together by passing a packed
// (grant_ref << 32 | ep_token) in a reserved argv entry (ARGV_PREFIX below,
// parsed by lib/man/stdio.zig). The endpoint token is not a bearer:
// map_attach fails unless the caller holds the endpoint (chan_grant).
//
// Layout (comptime-asserted):
//   offset   0: RegionHeader          (shared SHM header, 32 bytes)
//   offset  64: PipeStatus            (writer_closed / reader_closed)
//   offset 128: ByteRing(PIPE_CAP)    (head@+0, tail@+64 -- matches ring_arm)
//
// Close protocol (mirrors channel dead-peer semantics, LAW 3: queued bytes
// drain before closure is observed):
//   Writer EOF:     writer_closed=1, ring_wake(consumer). Reader drains the
//                   ring, then read() returns 0 (EOF).
//   Reader hangup:  reader_closed=1, ring_wake(producer). Writer's next
//                   blocked write returns BrokenPipe.
//   Cell death:     the supervisor (region owner) writes the dead side's
//                   closed flag on its behalf and wakes the survivor --
//                   death and voluntary close are indistinguishable to the
//                   peer. Supervisor death destroys the region and wakes all
//                   parked attachers with .closed (registry RL.15).
//
// Argv carries an endpoint token plus the pair-local grant_ref. Stolen
// numbers without holdership fail resolveHolder (T5).
//
// SOURCE OF TRUTH: This file is copied to lib/shared/ by gen-lib.
// Do not edit lib/shared/pipe.zig directly.
//------------------------------------------------------------------------------

const shm = @import("shm.zig");

/// Usable stream buffer (capacity - 1 bytes in flight).
pub const PIPE_CAP: u32 = 8192;

/// Region page count for sys.map_create.
pub const REGION_PAGES: u64 = (@sizeOf(PipeRegion) + 4095) / 4096;

/// Reserved argv entry: "--lmn-stdio=<in>:<out>" where each side is 16 hex
/// digits packing (grant_ref << 32 | ep_token), or '-' (unbound). Always
/// the LAST argv entry; stdio.init() strips it before the program sees
/// its arguments.
pub const ARGV_PREFIX = "--lmn-stdio=";
pub const HANDLE_HEX_LEN = 16;
pub const UNBOUND: u8 = '-';

/// chan_create hash for supervisor-granted stdio pairs. Not lamina-wired.
pub const STDIO_CONTRACT_HASH: u64 = 0x504950455f535444; // "PIPE_STD"
pub const STDIO_CONTRACT_VERSION: u16 = 1;

pub const StdioCap = struct { ep: u32, grant_ref: u32 };

pub fn packCap(ep: u32, grant_ref: u32) u64 {
    return (@as(u64, grant_ref) << 32) | ep;
}

pub fn unpackCap(v: u64) StdioCap {
    return .{ .ep = @truncate(v), .grant_ref = @truncate(v >> 32) };
}

pub const PipeStatus = extern struct {
    writer_closed: u32,
    reader_closed: u32,
    _pad: [56]u8,
};

pub const PipeRegion = extern struct {
    header: shm.RegionHeader,
    _pad0: [32]u8,
    status: PipeStatus,
    ring: shm.ByteRing(PIPE_CAP),

    pub fn init(self: *volatile PipeRegion, creator: u16) void {
        self.status.writer_closed = 0;
        self.status.reader_closed = 0;
        self.ring.init();
        // Header last: state=READY publishes the initialized layout.
        self.header.init(creator);
    }
};

comptime {
    if (@offsetOf(PipeRegion, "status") != 64)
        @compileError("PipeRegion.status must be at offset 64");
    if (@offsetOf(PipeRegion, "ring") != 128)
        @compileError("PipeRegion.ring must be at offset 128");
}

/// Encode a packed stdio cap (or any u64) as fixed-width lowercase hex.
pub fn encodeHandle(handle: u64, buf: *[HANDLE_HEX_LEN]u8) void {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < HANDLE_HEX_LEN) : (i += 1) {
        const shift: u6 = @intCast((HANDLE_HEX_LEN - 1 - i) * 4);
        buf[i] = digits[@as(usize, @intCast((handle >> shift) & 0xF))];
    }
}

/// Decode a fixed-width hex handle. Null on any non-hex character or short
/// input.
pub fn decodeHandle(s: []const u8) ?u64 {
    if (s.len != HANDLE_HEX_LEN) return null;
    var v: u64 = 0;
    for (s) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}
