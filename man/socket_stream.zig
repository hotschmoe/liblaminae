//------------------------------------------------------------------------------
// Socket Stream -- T1 vocabulary for SHM-backed socket reads and writes
//------------------------------------------------------------------------------
//
// `ReadStream` reads from a `RecvShmRegion`; `WriteStream` writes to a
// `SendShmRegion`. Both park via `sys_ring_arm` + `sys_wait_event` and
// are woken by zmoltcp's `sys_ring_wake` on the matching waiter slot.
// Region layout, direction conventions, and the recv-side EOF protocol
// live in `socket_shm.zig`.
//
// Why the SOCKET_SEND_READY / SOCKET_WRITE_READY mailbox wakes still
// exist (post-C8.17 ring-event symmetry was technically achievable):
//   * SOCKET_SEND_READY (app -> stack): the alternative is the stack
//     arming the send region's consumer_waiter every mainLoop iter, but
//     that loses the very first wake before the stack reaches the arm
//     site -- a SHM_ACCEPT-to-first-arm race that costs a 50ms poll
//     timeout on every request's hot path.
//   * SOCKET_WRITE_READY (stack -> app): superset of the M2c
//     backpressure-wake -- catches the case where the writer hasn't yet
//     called sys_ring_arm before the stack drains.
// M2d will fold both into ring-event once the stack mainLoop handles
// multi-ring arm timing without the race.
//
// What's deliberately NOT here: `close()` (T2, needs ICC handshake) and
// the high-level `SocketStream` (T2 type in `lib/net_client/api.zig`).
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const errors = @import("../gen/errors.zig");
const socket_shm = @import("socket_shm.zig");
const protocol = @import("net_stack_protocol");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Pure SHM read/write primitives: volatile ring access + `sys_wait_event`
/// + `sys_ring_arm` / `sys_ring_wake`. No peer-blocking ICC. T1 vocabulary.
pub const tier: u8 = 1;

pub const ReadError = error{
    /// `read` was called with `timeout_ms == 0` and the ring was empty.
    WouldBlock,
    /// The deadline elapsed without any data arriving.
    TimedOut,
    /// Network stack peer half-closed (TCP FIN). The recv ring is fully
    /// drained; no more data will arrive. Caller should close; further
    /// reads keep returning `EndOfStream`. Signalled via `RecvShmRegion.eof`.
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

const WAKE_SLICE_NS: u64 = 50_000_000; // 50ms per wait slice

/// L4: the mailbox wake-hint messages are gone (the ring-event wake is the
/// sole writer/reader wake), so there is nothing to drain. Kept as a no-op
/// call site anchor until the Break-6 deletion pass removes it.
fn drainOwnWake(my_socket_id: u16) void {
    _ = my_socket_id;
}

/// SHM-backed read half of a socket. `token` is the recv-region attach
/// token, passed to `sys.ring_arm` so the kernel can find the region's
/// consumer waiter slot. token == 0 is only used in unit tests that
/// construct ReadStream without a real region (ring_arm becomes a no-op).
///
/// The underlying region is owned by the network stack peer; `ReadStream`
/// is a value handle, cheap to copy while the parent socket is open.
pub const ReadStream = struct {
    region: *volatile socket_shm.RecvShmRegion,
    token: u32,

    pub fn fromRegion(region: *volatile socket_shm.RecvShmRegion, token: u32) ReadStream {
        return .{ .region = region, .token = token };
    }

    /// Drain whatever data is available *right now* without blocking.
    pub fn readNonBlocking(self: ReadStream, buf: []u8) usize {
        if (buf.len == 0) return 0;
        return self.region.ring.read(buf);
    }

    /// Read up to `buf.len` bytes. Returns as soon as >= 1 byte is available
    /// or the deadline elapses. EOF ordering: data first, then `EndOfStream`
    /// once the ring drains -- never both at once.
    ///
    /// Wake plane: arms the recv ring consumer waiter via sys_ring_arm before
    /// parking in sys_wait_event. zmoltcp wakes us with sys_ring_wake when it
    /// drains TCP rx into the ring.
    pub fn read(self: ReadStream, buf: []u8, timeout_ms: u32) ReadError!usize {
        if (buf.len == 0) return 0;

        const immediate = self.region.ring.read(buf);
        if (immediate > 0) return immediate;

        if (self.region.eof != 0) return ReadError.EndOfStream;
        if (timeout_ms == 0) return ReadError.WouldBlock;

        const deadline = sys.get_time() +% (@as(u64, timeout_ms) * 1_000_000);
        while (true) {
            const now = sys.get_time();
            if (now >= deadline) return ReadError.TimedOut;

            const wait_ns = @min(deadline -| now, WAKE_SLICE_NS);

            // Arm the recv ring consumer side (direction=0) before parking.
            // Only arm when the ring is empty -- if data arrived between the
            // last read and now, skip the arm and drain immediately.
            const last_head = self.region.ring.head;
            if (self.region.ring.isEmpty()) {
                _ = sys.ring_arm(self.token, @intFromPtr(&self.region.ring), last_head, 0);
            }
            _ = sys.wait_event(0, 0, wait_ns);

            // Drain a stale SOCKET_WRITE_READY for our own socket sitting
            // at head-of-mailbox from a prior write; otherwise wait_event
            // keeps returning .icc spuriously and we never park long
            // enough to receive a ring_wake.
            drainOwnWake(self.region.socket_id);

            const got = self.region.ring.read(buf);
            if (got > 0) return got;
            if (self.region.eof != 0) return ReadError.EndOfStream;
        }
    }
};

/// SHM-backed write half of a socket. `notify_out` + `socket_id` are
/// captured so `notify()` can fire the SOCKET_SEND_READY wake over the
/// caller's net.stack BUNDLE (L4: the mailbox is dead; the stack drains
/// this from the client's channel endpoint), beating the stack's 50ms
/// poll-timeout floor.
pub const WriteStream = struct {
    region: *volatile socket_shm.SendShmRegion,
    token: u32,
    /// The caller's net.stack bundle out-end token; 0 = no eager wake
    /// (the stack's 50ms poll still drains).
    notify_out: u32,
    socket_id: u16,

    pub fn from(
        region: *volatile socket_shm.SendShmRegion,
        token: u32,
        notify_out: u32,
        socket_id: u16,
    ) WriteStream {
        return .{ .region = region, .token = token, .notify_out = notify_out, .socket_id = socket_id };
    }

    /// Push as many bytes as fit into the send ring right now without parking.
    pub fn writeNonBlocking(self: WriteStream, buf: []const u8) usize {
        if (buf.len == 0) return 0;
        const n = self.region.ring.write(buf);
        if (n > 0) self.notify();
        return n;
    }

    /// Push up to `buf.len` bytes. Returns as soon as >= 1 byte is queued or
    /// the deadline elapses. Caller loops for "send all" semantics.
    ///
    /// Wake plane: when the ring fills, arms the send region producer waiter
    /// via sys_ring_arm(direction=1) and parks in sys_wait_event. zmoltcp
    /// wakes us with sys_ring_wake(send_token, 1) on drain (C8.17 M2c
    /// backpressure). After a successful write, fires SOCKET_SEND_READY
    /// mailbox so the stack drains promptly (tail-latency optimization).
    pub fn write(self: WriteStream, buf: []const u8, timeout_ms: u32) WriteError!usize {
        if (buf.len == 0) return WriteError.Empty;

        const immediate = self.region.ring.write(buf);
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

            // Arm the send ring producer side (direction=1) before parking.
            // Only arm when the ring is full -- if space appeared between the
            // last write and now, skip the arm and retry immediately.
            const last_tail = self.region.ring.tail;
            if (self.region.ring.isFull()) {
                _ = sys.ring_arm(self.token, @intFromPtr(&self.region.ring), last_tail, 1);
            }
            _ = sys.wait_event(0, 0, wait_ns);

            // Drain stale SOCKET_WRITE_READY messages addressed to us so
            // they don't cause spurious icc wakes on subsequent wait_event
            // calls (inter-socket drain race; see C8.13e).
            drainOwnWake(self.socket_id);

            const written = self.region.ring.write(buf);
            if (written > 0) {
                self.notify();
                return written;
            }
        }
    }

    // Fire-and-forget eager-drain wake over the net.stack bundle. Stack
    // drains the send ring synchronously on receipt; replaces the 50ms
    // poll-timeout latency floor.
    fn notify(self: WriteStream) void {
        if (self.notify_out == 0) return;
        var msg: sys.Message = undefined;
        msg.msg_type = protocol.MsgType.SOCKET_SEND_READY;
        msg.flags = 0;
        @memset(&msg.payload, 0);
        msg.payload[0] = @truncate(self.socket_id);
        msg.payload[1] = @truncate(self.socket_id >> 8);
        _ = sys.chan_send(self.notify_out, &msg);
    }
};
