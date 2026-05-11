//------------------------------------------------------------------------------
// Socket Stream — T1 vocabulary for SHM-backed socket reads and writes
//------------------------------------------------------------------------------
//
// `ReadStream` and `WriteStream` are the two halves of a connected socket's
// data plane once the network stack has offered a SHM region
// (`SOCKET_SHM_OFFER` + `SOCKET_SHM_ACCEPT`). Steady state on either side is:
//
//   read:  volatile recv_ring read; sys_wait_event for SOCKET_DATA_READY;
//          drain the ICC notification msg (no peer-blocking RPC); re-read.
//   write: volatile send_ring write; fire-and-forget icc_send so the stack
//          drains promptly; sys_wait_event for SOCKET_WRITE_READY when the
//          ring is full; re-write.
//
// None of these steps are peer-dependent in the T2 sense (no
// `icc_send` + matched `icc_recv`). The fire-and-forget `icc_send` for
// the wake notification is just that -- fire-and-forget; the rings are
// the source of truth, the wake just removes the 50ms poll-cadence
// floor on tail latency.
//
// What's deliberately NOT here:
//   - `close()` -- teardown still needs the ICC handshake (peer must
//     release the SHM region), so it stays in `lib/net_client/api.zig`.
//   - The high-level `SocketStream` that mixes SHM and ICC fallback --
//     that's a T2 type and lives in api.zig where it can reach the RPC
//     helpers.
//
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const errors = @import("../gen/errors.zig");
const socket_shm = @import("socket_shm.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Pure SHM read/write primitives: volatile ring access + `sys_wait_event`
/// + fire-and-forget `icc_send` for wake. No peer-blocking ICC. T1 vocabulary.
pub const tier: u8 = 1;

pub const ReadError = error{
    /// `read` was called with `timeout_ms == 0` and the ring was empty.
    WouldBlock,
    /// The deadline elapsed without any data arriving.
    TimedOut,
    /// Network stack peer half-closed (TCP FIN). `recv_ring` is fully
    /// drained; no more data will arrive. Caller should close; further
    /// reads keep returning `EndOfStream`. Signalled via `SocketShmRegion.eof`.
    EndOfStream,
};

pub const WriteError = error{
    /// `write` was called with `timeout_ms == 0` and the ring was full.
    WouldBlock,
    /// The deadline elapsed without any space appearing.
    TimedOut,
    /// Caller passed an empty buffer.
    Empty,
};

// MsgType constants used for fire-and-forget wake notifications. Mirrors
// `lib/shared/icc/net_stack_protocol.zig` MsgType values to avoid pulling
// in the whole protocol surface here.
const MSG_SOCKET_DATA_READY: u16 = 0x2062;
const MSG_SOCKET_SEND_READY: u16 = 0x2064;
const MSG_SOCKET_WRITE_READY: u16 = 0x2065;

const WAKE_SLICE_NS: u64 = 50_000_000; // 50ms per wait slice

/// Drain at most one head-of-mailbox ICC notification, gated on ownership:
/// a SOCKET_DATA_READY / SOCKET_WRITE_READY wake addressed to a *different*
/// socket is left queued for that socket's own reader. Non-socket-wake
/// messages are swallowed (the historical "consume whatever woke us"
/// semantics). Prevents the inter-socket drain race in `secondary_followups.md`
/// item C8.13e.
fn drainOwnWake(my_socket_id: u16) void {
    var msg: sys.Message = undefined;
    if (errors.isError(sys.icc_peek(&msg))) return;

    const is_socket_wake = msg.msg_type == MSG_SOCKET_DATA_READY or
        msg.msg_type == MSG_SOCKET_WRITE_READY;
    if (is_socket_wake) {
        const wake_socket_id: u16 = @as(u16, msg.payload[0]) |
            (@as(u16, msg.payload[1]) << 8);
        if (wake_socket_id != my_socket_id) return;
    }
    _ = sys.icc_recv(&msg, 0);
}

/// SHM-backed read half of a socket. Constructed by `lib/net_client/api.zig`
/// once `SOCKET_SHM_ACCEPT` has been sent and the region is mapped.
///
/// Lifetime: the underlying `SocketShmRegion` is owned by the network stack
/// peer. The `ReadStream` is a value handle; copying it is cheap and safe
/// as long as the parent socket hasn't been closed.
pub const ReadStream = struct {
    region: *volatile socket_shm.SocketShmRegion,

    pub fn fromRegion(region: *volatile socket_shm.SocketShmRegion) ReadStream {
        return .{ .region = region };
    }

    /// Drain whatever data is available *right now* without blocking.
    pub fn readNonBlocking(self: ReadStream, buf: []u8) usize {
        if (buf.len == 0) return 0;
        return self.region.recv_ring.read(buf);
    }

    /// Read up to `buf.len` bytes. Returns as soon as >= 1 byte is available
    /// or the deadline elapses. EOF ordering: data first, then `EndOfStream`
    /// once `recv_ring` drains -- never both at once.
    pub fn read(self: ReadStream, buf: []u8, timeout_ms: u32) ReadError!usize {
        if (buf.len == 0) return 0;

        const immediate = self.region.recv_ring.read(buf);
        if (immediate > 0) return immediate;

        if (self.region.eof != 0) return ReadError.EndOfStream;
        if (timeout_ms == 0) return ReadError.WouldBlock;

        const deadline = sys.get_time() +% (@as(u64, timeout_ms) * 1_000_000);
        while (true) {
            const now = sys.get_time();
            if (now >= deadline) return ReadError.TimedOut;

            const wait_ns = @min(deadline -| now, WAKE_SLICE_NS);
            _ = sys.wait_event(0, 1, 0, wait_ns);

            drainOwnWake(self.region.socket_id);

            const got = self.region.recv_ring.read(buf);
            if (got > 0) return got;
            if (self.region.eof != 0) return ReadError.EndOfStream;
        }
    }
};

/// SHM-backed write half of a socket. Construction mirrors `ReadStream` but
/// also captures the `peer_id` and `socket_id` so the stream can fire wake
/// notifications without needing the api layer in the loop.
pub const WriteStream = struct {
    region: *volatile socket_shm.SocketShmRegion,
    peer_id: u16,
    socket_id: u16,

    pub fn from(
        region: *volatile socket_shm.SocketShmRegion,
        peer_id: u16,
        socket_id: u16,
    ) WriteStream {
        return .{ .region = region, .peer_id = peer_id, .socket_id = socket_id };
    }

    /// Push as many bytes as fit into the send ring right now. Wakes the
    /// stack via fire-and-forget icc_send if any bytes were written.
    pub fn writeNonBlocking(self: WriteStream, buf: []const u8) usize {
        if (buf.len == 0) return 0;
        const written = self.region.send_ring.write(buf);
        if (written > 0) self.notify();
        return written;
    }

    /// Push up to `buf.len` bytes. Returns as soon as >= 1 byte is queued or
    /// the deadline elapses. Caller loops for "send all" semantics.
    pub fn write(self: WriteStream, buf: []const u8, timeout_ms: u32) WriteError!usize {
        if (buf.len == 0) return WriteError.Empty;

        const immediate = self.region.send_ring.write(buf);
        if (immediate > 0) {
            self.notify();
            return immediate;
        }

        if (timeout_ms == 0) return WriteError.WouldBlock;

        const deadline = sys.get_time() +% (@as(u64, timeout_ms) * 1_000_000);
        while (true) {
            const now = sys.get_time();
            if (now >= deadline) return WriteError.TimedOut;

            const wait_ns = @min(deadline -| now, WAKE_SLICE_NS);
            _ = sys.wait_event(0, 1, 0, wait_ns);

            drainOwnWake(self.socket_id);

            const written = self.region.send_ring.write(buf);
            if (written > 0) {
                self.notify();
                return written;
            }
        }
    }

    // Fire-and-forget wake. bytes_available is left zero -- the stack drain
    // path doesn't read it; kept in the protocol for future flow control.
    fn notify(self: WriteStream) void {
        var msg: sys.Message = undefined;
        msg.msg_type = MSG_SOCKET_SEND_READY;
        msg.flags = 0;
        @memset(&msg.payload, 0);
        msg.payload[0] = @truncate(self.socket_id);
        msg.payload[1] = @truncate(self.socket_id >> 8);
        _ = sys.icc_send(self.peer_id, &msg);
    }
};
