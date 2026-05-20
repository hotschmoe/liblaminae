//------------------------------------------------------------------------------
// Socket Shared Memory Data Plane
//
// Composes from generic SHM primitives (lib/shared/shm.zig) to provide
// a high-throughput bidirectional path between the network stack and
// application containers.
//
// Architecture (post-C8.17 split):
//   +--------+                                       +--------+
//   | Stack  |  --- RecvShmRegion.ring (stack->app)  |  App   |
//   |        |  <-- SendShmRegion.ring (app->stack)  |        |
//   +--------+                                       +--------+
//
//   Per socket, the stack creates TWO single-ring SHM regions and hands
//   both handles to the app in CONNECT_RESULT. Each region has its own
//   kernel `SharedRegion` slot and therefore its own `consumer_waiter` /
//   `producer_waiter` pair -- the SPSC waiter discipline (RE.4) is
//   enforced by region structure, not by prose.
//
// Direction conventions:
//   Recv region:  producer = stack,  consumer = app
//   Send region:  producer = app,    consumer = stack
//
// Wake plane (ring-event, M2a/M2c):
//   App ReadStream parks as consumer (direction=0) on the recv region.
//   Stack wakes the app via sys_ring_wake(stack_recv_token, 0) after
//   draining TCP rx into recv region.
//   App WriteStream parks as producer (direction=1) on the send region
//   when the ring is full. Stack wakes the app via
//   sys_ring_wake(stack_send_token, 1) after draining bytes out of the
//   send region into the TCP tx queue.
//
// Lifecycle:
//   1. Stack creates recv + send regions on TCP connect success
//      (two map_create calls) and writes both handles into
//      CONNECT_RESULT.recv_shm_handle / .send_shm_handle. Either field
//      being 0 means no SHM (UDP today, or the stack chose not to offer)
//      and the app falls back to ICC RECV/SEND.
//   2. App map_attaches both handles, validates both regions, then sends
//      a single SOCKET_SHM_ACCEPT so the stack flips its slot to "active".
//   3. Steady state: ring read/write + ring-event wakes.
//   4. On close: SOCKET_SHM_DETACH, map_detach on both tokens.
//
// Format version:
//   FORMAT_VERSION lives in each region (separate from shm.RegionHeader.VERSION
//   which gates ring primitive layout). v4 = post-C8.17 split (was v3 = single
//   bundled SocketShmRegion with both rings and an eof byte).
//------------------------------------------------------------------------------

const shm = @import("../shared/shm.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// SHM primitive composition -- no syscalls, no peer ICC. Caller does the
/// map_attach / map_detach plumbing.
pub const tier: u8 = 1;

/// Recv ring capacity (stack -> app). Must be power of 2.
pub const RECV_RING_SIZE: u32 = 32768; // 32KB

/// Send ring capacity (app -> stack). Must be power of 2.
pub const SEND_RING_SIZE: u32 = 32768; // 32KB

/// Region layout version. Bump when fields shift or ring sizes change.
/// v1 = recv_ring only; v2 = recv_ring + send_ring bundled;
/// v3 = v2 + recv-side EOF flag (single bundled region);
/// v4 = split into RecvShmRegion + SendShmRegion (C8.17).
pub const FORMAT_VERSION: u16 = 4;

/// Stack-to-app data ring. Single-direction; the kernel `SharedRegion` slot
/// owns the (consumer_waiter, producer_waiter) pair unambiguously.
pub const RecvShmRegion = extern struct {
    header: shm.RegionHeader,
    socket_id: u16,
    format_version: u16,

    /// Recv-side EOF marker. Stack sets to 1 on peer FIN after draining
    /// the TCP recv buffer into `ring`; readers see queued bytes first,
    /// then `ReadStream.read` returns `EndOfStream`. Single-writer (stack)
    /// / multi-reader (app) -- plain u8 load/store is safe on AArch64
    /// without atomics. 0 = open, non-zero = EOF.
    eof: u8,
    _pad: [11]u8,

    ring: shm.ByteRing(RECV_RING_SIZE),

    pub fn init(self: *volatile RecvShmRegion, creator_id: u16, sock_id: u16) void {
        self.header.init(creator_id);
        self.socket_id = sock_id;
        self.format_version = FORMAT_VERSION;
        self.eof = 0;
        self._pad = [_]u8{0} ** 11;
        self.ring.init();
    }

    pub fn validate(self: *volatile RecvShmRegion) bool {
        return self.header.validate() and self.format_version == FORMAT_VERSION;
    }
};

/// App-to-stack data ring. Mirror of `RecvShmRegion` but without the EOF
/// byte -- send-direction half-close is a separate future protocol concern.
pub const SendShmRegion = extern struct {
    header: shm.RegionHeader,
    socket_id: u16,
    format_version: u16,
    _pad: [12]u8,

    ring: shm.ByteRing(SEND_RING_SIZE),

    pub fn init(self: *volatile SendShmRegion, creator_id: u16, sock_id: u16) void {
        self.header.init(creator_id);
        self.socket_id = sock_id;
        self.format_version = FORMAT_VERSION;
        self._pad = [_]u8{0} ** 12;
        self.ring.init();
    }

    pub fn validate(self: *volatile SendShmRegion) bool {
        return self.header.validate() and self.format_version == FORMAT_VERSION;
    }
};

/// Pages required for `RecvShmRegion`. Caller passes this to `sys.map_create`.
pub fn recvRequiredPages() u64 {
    const size = @sizeOf(RecvShmRegion);
    return (size + 4095) / 4096;
}

/// Pages required for `SendShmRegion`.
pub fn sendRequiredPages() u64 {
    const size = @sizeOf(SendShmRegion);
    return (size + 4095) / 4096;
}

comptime {
    // 32KB ring + header/pad + ring metadata = ~33KB == 9 pages.
    // 12 leaves headroom for future fields without forcing another comptime
    // adjustment.
    if (@sizeOf(RecvShmRegion) > 12 * 4096) {
        @compileError("RecvShmRegion too large for 12 pages");
    }
    if (@sizeOf(SendShmRegion) > 12 * 4096) {
        @compileError("SendShmRegion too large for 12 pages");
    }
}
