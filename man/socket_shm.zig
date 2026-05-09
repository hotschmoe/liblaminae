//------------------------------------------------------------------------------
// Socket Shared Memory Data Plane
//
// Composes from generic SHM primitives (lib/shared/shm.zig) to provide
// a high-throughput recv path between c_lwIP and application containers.
//
// Architecture:
//   +--------+                        +--------+
//   | c_lwIP |  --- recv_ring --->    |  App   |
//   +--------+                        +--------+
//        |                                 |
//        v                                 v
//   +----------------------------------------------+
//   |        SocketShmRegion (per socket)           |
//   |  +--------+  +----------------------------+  |
//   |  | Header |  |  recv_ring (32KB ByteRing) |  |
//   |  +--------+  +----------------------------+  |
//   +----------------------------------------------+
//
// Data Flow:
//   c_lwIP drains TCP recv buffer into recv_ring at ~50ms intervals.
//   App reads from recv_ring at memory-copy speed (no syscall per read).
//   ICC notifications (SOCKET_DATA_READY) wake the app when new data arrives.
//
// Lifecycle:
//   1. c_lwIP creates region on TCP connect success (map_create)
//   2. c_lwIP sends SOCKET_SHM_OFFER with handle in CONNECT_RESULT
//   3. App calls map_attach, sends SOCKET_SHM_ACCEPT
//   4. c_lwIP drains recv data into ring, sends DATA_READY notifications
//   5. On close: either side sends SOCKET_SHM_DETACH, map_detach
//   6. Fallback: if no SHM, app uses existing ICC RECV path unchanged
//------------------------------------------------------------------------------

const shm = @import("../shared/shm.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// SHM primitive composition -- no syscalls, no peer ICC. Caller does the
/// map_attach / map_detach plumbing.
pub const tier: u8 = 1;

/// Recv ring capacity (must be power of 2)
pub const RECV_RING_SIZE: u32 = 32768; // 32KB

/// Per-socket shared memory region
pub const SocketShmRegion = extern struct {
    header: shm.RegionHeader,
    socket_id: u16,
    _pad: [14]u8,
    recv_ring: shm.ByteRing(RECV_RING_SIZE),

    pub fn init(self: *volatile SocketShmRegion, creator_id: u16, sock_id: u16) void {
        self.header.init(creator_id);
        self.socket_id = sock_id;
        self._pad = [_]u8{0} ** 14;
        self.recv_ring.init();
    }

    pub fn validate(self: *volatile SocketShmRegion) bool {
        return self.header.validate();
    }
};

/// Calculate required pages for SocketShmRegion
pub fn requiredPages() u64 {
    const size = @sizeOf(SocketShmRegion);
    return (size + 4095) / 4096;
}

comptime {
    if (@sizeOf(SocketShmRegion) > 12 * 4096) {
        @compileError("SocketShmRegion too large for 12 pages");
    }
}
