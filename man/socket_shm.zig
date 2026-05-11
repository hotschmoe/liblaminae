//------------------------------------------------------------------------------
// Socket Shared Memory Data Plane
//
// Composes from generic SHM primitives (lib/shared/shm.zig) to provide
// a high-throughput bidirectional path between the network stack and
// application containers.
//
// Architecture:
//   +--------+                        +--------+
//   | Stack  |  <-- send_ring ---     |  App   |
//   |        |  --- recv_ring -->     |        |
//   +--------+                        +--------+
//        |                                 |
//        v                                 v
//   +-------------------------------------------------+
//   |         SocketShmRegion (per socket)             |
//   |  +--------+  +-------------+  +---------------+  |
//   |  | Header |  | recv (32KB) |  |  send (32KB)  |  |
//   |  +--------+  +-------------+  +---------------+  |
//   +-------------------------------------------------+
//
// Data Flow:
//   Stack drains TCP recv buffer into recv_ring on its poll cadence.
//   App reads from recv_ring at memory-copy speed (no syscall per read).
//   App writes to send_ring at memory-copy speed; stack drains into TCP TX.
//   ICC wakes (SOCKET_DATA_READY / SOCKET_WRITE_READY / SOCKET_SEND_READY)
//   are fire-and-forget -- the rings are the source of truth.
//
// Lifecycle:
//   1. Stack creates region on TCP connect success (map_create)
//   2. Stack sends SOCKET_SHM_OFFER with handle in CONNECT_RESULT
//   3. App calls map_attach, sends SOCKET_SHM_ACCEPT
//   4. Steady state: ring read/write + ICC wake notifications
//   5. On close: either side sends SOCKET_SHM_DETACH, map_detach
//   6. Fallback: if no SHM, app uses existing ICC RECV/SEND paths
//
// Format version:
//   FORMAT_VERSION lives in the region itself (separate from
//   shm.RegionHeader.VERSION which gates ring primitive layout). Bumped
//   when the SocketShmRegion field set or ring sizes change so a stale
//   peer can refuse to attach instead of corrupting via offset drift.
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
/// v1 = recv_ring only; v2 = recv_ring + send_ring;
/// v3 = v2 + recv-side EOF flag (`eof`) for clean peer-FIN signaling.
pub const FORMAT_VERSION: u16 = 3;

/// Per-socket shared memory region
pub const SocketShmRegion = extern struct {
    header: shm.RegionHeader,
    socket_id: u16,
    format_version: u16,

    /// Recv-side EOF marker. Stack sets to 1 on peer FIN after draining
    /// the TCP recv buffer into `recv_ring`; readers see queued bytes
    /// first, then `ReadStream.read` returns `EndOfStream`. Single-writer
    /// (stack) / multi-reader (app) -- plain u8 load/store is safe on
    /// AArch64 without atomics. 0 = open, non-zero = EOF.
    eof: u8,
    _pad: [11]u8,

    recv_ring: shm.ByteRing(RECV_RING_SIZE),
    send_ring: shm.ByteRing(SEND_RING_SIZE),

    pub fn init(self: *volatile SocketShmRegion, creator_id: u16, sock_id: u16) void {
        self.header.init(creator_id);
        self.socket_id = sock_id;
        self.format_version = FORMAT_VERSION;
        self.eof = 0;
        self._pad = [_]u8{0} ** 11;
        self.recv_ring.init();
        self.send_ring.init();
    }

    pub fn validate(self: *volatile SocketShmRegion) bool {
        return self.header.validate() and self.format_version == FORMAT_VERSION;
    }
};

/// Calculate required pages for SocketShmRegion
pub fn requiredPages() u64 {
    const size = @sizeOf(SocketShmRegion);
    return (size + 4095) / 4096;
}

comptime {
    // 32KB recv + 32KB send + header/pad + ring metadata = ~64KB == 16 pages.
    // 24 leaves headroom for future fields without forcing another comptime
    // adjustment.
    if (@sizeOf(SocketShmRegion) > 24 * 4096) {
        @compileError("SocketShmRegion too large for 24 pages");
    }
}
