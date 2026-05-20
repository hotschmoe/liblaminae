//------------------------------------------------------------------------------
// Shared Memory Network Data Plane
//
// Composes from generic SHM primitives (lib/shared/shm.zig) to provide
// the packet transport layer between netd and zmoltcp.
//
// Architecture:
//   +--------+                     +---------+
//   |  netd  |                     | zmoltcp |
//   +--------+                     +---------+
//        |                              |
//        v                              v
//   +------------------------------------------------+
//   |           Shared Memory Buffer                 |
//   |  +---------+  +---------+  +----------------+  |
//   |  | RX Ring |  | TX Ring |  |  Packet Pool   |  |
//   |  +---------+  +---------+  +----------------+  |
//   +------------------------------------------------+
//
// Data Flow:
//   RX (wire -> zmoltcp): netd writes to RX ring, zmoltcp reads
//   TX (zmoltcp -> wire): zmoltcp writes to TX ring, netd reads
//
// Signaling (still via ICC):
//   - SHM_RX_READY: netd notifies zmoltcp of new RX packets
//   - SHM_TX_READY: zmoltcp notifies netd of new TX packets
//------------------------------------------------------------------------------

const shm = @import("../shared/shm.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// SHM primitive composition -- no syscalls, no peer ICC. Caller plumbs
/// the netd <-> zmoltcp attachment.
pub const tier: u8 = 1;

/// Protocol version (v2: generic SHM primitives layout)
pub const SHM_VERSION: u32 = 2;

/// Ring size (must be power of 2)
pub const RING_SIZE: u32 = 32;

/// Maximum packet size (MTU 1500 + Ethernet header + some margin)
pub const MAX_PACKET_SIZE: u32 = 1600;

/// Number of packet buffers in pool
pub const POOL_SIZE: u32 = 64;

/// Descriptor flags
pub const DESC_F_VALID: u16 = 0x0001;
pub const DESC_F_CONSUMED: u16 = 0x0002;

/// Packet descriptor in the ring
pub const PacketDescriptor = extern struct {
    pool_idx: u16,
    length: u16,
    flags: u16,
    _reserved: u16,
};

/// Composed ring and pool types from generic primitives
pub const PacketRing = shm.SpscRing(PacketDescriptor, RING_SIZE);
pub const NetBufferPool = shm.BufferPool(MAX_PACKET_SIZE, POOL_SIZE);

/// Shared memory buffer layout (composed from generic primitives)
pub const SharedNetBuffer = extern struct {
    header: shm.RegionHeader,
    rx_ring: PacketRing,
    tx_ring: PacketRing,
    pool: NetBufferPool,

    /// Initialize the shared buffer (called by creator - netd)
    pub fn init(self: *volatile SharedNetBuffer, creator_id: u16) void {
        self.header.init(creator_id);
        self.rx_ring.init();
        self.tx_ring.init();
        self.pool.init();
    }

    /// Validate the shared buffer (called by attacher - zmoltcp)
    pub fn validate(self: *volatile SharedNetBuffer) bool {
        return self.header.validate();
    }

    /// Allocate a buffer from the pool (returns index or 0xFFFF if full)
    pub fn allocBuffer(self: *volatile SharedNetBuffer) u16 {
        return self.pool.alloc() orelse 0xFFFF;
    }

    /// Free a buffer back to the pool
    pub fn freeBuffer(self: *volatile SharedNetBuffer, idx: u16) void {
        self.pool.free(idx);
    }

    /// Get pointer to a packet buffer
    pub fn getBuffer(self: *volatile SharedNetBuffer, idx: u16) ?[*]volatile u8 {
        return self.pool.getBuffer(idx);
    }
};

/// IPC message types for shared memory signaling.
/// SHM_RX_READY (0x1012) was retired in M2b -- the RX wake plane is now
/// `sys_ring_wake` against the rx_ring's per-attach token.
pub const ShmMsgType = struct {
    pub const SHM_HANDLE: u16 = 0x1010;
    pub const SHM_ATTACHED: u16 = 0x1011;
    pub const SHM_TX_READY: u16 = 0x1013;
};

/// Calculate required pages for SharedNetBuffer
pub fn requiredPages() u64 {
    const size = @sizeOf(SharedNetBuffer);
    return (size + 4095) / 4096;
}

comptime {
    if (@sizeOf(SharedNetBuffer) > 26 * 4096) {
        @compileError("SharedNetBuffer too large for 26 pages");
    }
}
