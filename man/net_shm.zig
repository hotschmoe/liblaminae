//------------------------------------------------------------------------------
// Shared Memory Network Data Plane
//
// Phase 2 of "Make it Right" refactor - eliminates ICC for packet data.
//
// CANONICAL SOURCE - Keep these copies in sync:
//   - user/drivers/net_shm.zig (for netd)
//   - user/drivers/c_lwIP/net_shm.zig (for c_lwIP)
//
// Architecture:
//   +--------+                     +--------+
//   |  netd  |                     | c_lwIP |
//   +--------+                     +--------+
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
//   RX (wire -> c_lwIP): netd writes to RX ring, c_lwIP reads
//   TX (c_lwIP -> wire): c_lwIP writes to TX ring, netd reads
//
// Signaling (still via ICC):
//   - SHM_RX_READY: netd notifies c_lwIP of new RX packets
//   - SHM_TX_READY: c_lwIP notifies netd of new TX packets
//
// This reduces per-packet overhead from 2 syscalls + copy to just polling.
//------------------------------------------------------------------------------

/// Magic number for validation ("NETB" in ASCII)
pub const SHM_MAGIC: u32 = 0x4E455442;

/// Protocol version (increment on breaking changes)
pub const SHM_VERSION: u32 = 1;

/// Ring size (must be power of 2)
pub const RING_SIZE: u32 = 32;

/// Maximum packet size (MTU 1500 + Ethernet header + some margin)
pub const MAX_PACKET_SIZE: u32 = 1600;

/// Number of packet buffers in pool
pub const POOL_SIZE: u32 = 64;

/// Descriptor flags
pub const DESC_F_VALID: u16 = 0x0001; // Descriptor contains valid data
pub const DESC_F_CONSUMED: u16 = 0x0002; // Consumer has processed this

/// Packet descriptor in the ring
pub const PacketDescriptor = extern struct {
    /// Index into packet_pool (0 to POOL_SIZE-1)
    pool_idx: u16,
    /// Actual packet length
    length: u16,
    /// Descriptor flags
    flags: u16,
    /// Reserved for future use
    _reserved: u16,
};

/// Ring buffer for one direction (RX or TX)
pub const PacketRing = extern struct {
    /// Producer index (writer advances this after writing)
    head: u32 align(8),
    /// Consumer index (reader advances this after reading)
    tail: u32,
    /// Number of entries in ring (always RING_SIZE)
    size: u32,
    /// Reserved for cache line alignment
    _pad: u32,
    /// Ring entries
    descriptors: [RING_SIZE]PacketDescriptor,

    /// Check if ring has data to consume
    pub fn hasData(self: *volatile PacketRing) bool {
        return self.head != self.tail;
    }

    /// Check if ring has space to produce
    pub fn hasSpace(self: *volatile PacketRing) bool {
        const next = (self.head + 1) % self.size;
        return next != self.tail;
    }

    /// Get number of entries available to consume
    pub fn available(self: *volatile PacketRing) u32 {
        if (self.head >= self.tail) {
            return self.head - self.tail;
        } else {
            return self.size - self.tail + self.head;
        }
    }

    /// Get number of free slots for production
    pub fn freeSlots(self: *volatile PacketRing) u32 {
        return self.size - 1 - self.available();
    }
};

/// Shared memory buffer layout
/// Total size: ~104KB (fits in 26 pages)
pub const SharedNetBuffer = extern struct {
    /// Magic number for validation
    magic: u32,
    /// Protocol version
    version: u32,
    /// netd's container ID (set by netd)
    netd_id: u16,
    /// c_lwIP's container ID (set by c_lwIP on attach)
    clwip_id: u16,
    /// Flags (reserved)
    flags: u32,

    /// RX ring: netd -> c_lwIP (received packets from wire)
    rx_ring: PacketRing,
    /// TX ring: c_lwIP -> netd (packets to transmit)
    tx_ring: PacketRing,

    /// Free buffer bitmap (1 = free, 0 = in use)
    /// Each u64 covers 64 buffers
    free_bitmap: [1]u64, // Covers up to 64 buffers

    /// Reserved for alignment
    _reserved: [56]u8,

    /// Packet buffer pool (must be last, variable size)
    packet_pool: [POOL_SIZE][MAX_PACKET_SIZE]u8,

    /// Initialize the shared buffer (called by creator - netd)
    pub fn init(self: *volatile SharedNetBuffer, netd_container_id: u16) void {
        self.magic = SHM_MAGIC;
        self.version = SHM_VERSION;
        self.netd_id = netd_container_id;
        self.clwip_id = 0;
        self.flags = 0;

        // Initialize RX ring
        self.rx_ring.head = 0;
        self.rx_ring.tail = 0;
        self.rx_ring.size = RING_SIZE;
        self.rx_ring._pad = 0;
        for (&self.rx_ring.descriptors) |*desc| {
            desc.pool_idx = 0;
            desc.length = 0;
            desc.flags = 0;
            desc._reserved = 0;
        }

        // Initialize TX ring
        self.tx_ring.head = 0;
        self.tx_ring.tail = 0;
        self.tx_ring.size = RING_SIZE;
        self.tx_ring._pad = 0;
        for (&self.tx_ring.descriptors) |*desc| {
            desc.pool_idx = 0;
            desc.length = 0;
            desc.flags = 0;
            desc._reserved = 0;
        }

        // All buffers start as free
        self.free_bitmap[0] = 0xFFFFFFFFFFFFFFFF;

        // Zero reserved
        for (&self._reserved) |*b| b.* = 0;
    }

    /// Validate the shared buffer (called by attacher - c_lwIP)
    pub fn validate(self: *volatile SharedNetBuffer) bool {
        if (self.magic != SHM_MAGIC) return false;
        if (self.version != SHM_VERSION) return false;
        if (self.rx_ring.size != RING_SIZE) return false;
        if (self.tx_ring.size != RING_SIZE) return false;
        return true;
    }

    /// Allocate a buffer from the pool (returns index or 0xFFFF if full)
    pub fn allocBuffer(self: *volatile SharedNetBuffer) u16 {
        const bitmap = self.free_bitmap[0];
        if (bitmap == 0) return 0xFFFF; // No free buffers

        // Find first set bit (free buffer)
        var idx: u6 = 0;
        var mask: u64 = 1;
        while (idx < POOL_SIZE) : (idx += 1) {
            if ((bitmap & mask) != 0) {
                // Clear the bit (mark as allocated)
                self.free_bitmap[0] &= ~mask;
                return idx;
            }
            mask <<= 1;
        }
        return 0xFFFF;
    }

    /// Free a buffer back to the pool
    pub fn freeBuffer(self: *volatile SharedNetBuffer, idx: u16) void {
        if (idx >= POOL_SIZE) return;
        const mask: u64 = @as(u64, 1) << @as(u6, @intCast(idx));
        self.free_bitmap[0] |= mask;
    }

    /// Get pointer to a packet buffer
    pub fn getBuffer(self: *volatile SharedNetBuffer, idx: u16) ?[*]volatile u8 {
        if (idx >= POOL_SIZE) return null;
        return @ptrCast(&self.packet_pool[idx]);
    }
};

/// IPC message types for shared memory signaling
pub const ShmMsgType = struct {
    /// netd -> c_lwIP: Shared memory handle during registration
    pub const SHM_HANDLE: u16 = 0x1010;
    /// c_lwIP -> netd: Attached to shared memory
    pub const SHM_ATTACHED: u16 = 0x1011;
    /// netd -> c_lwIP: New RX packets available (optional, can poll)
    pub const SHM_RX_READY: u16 = 0x1012;
    /// c_lwIP -> netd: New TX packets available (optional, can poll)
    pub const SHM_TX_READY: u16 = 0x1013;
};

/// Calculate required pages for SharedNetBuffer
pub fn requiredPages() u64 {
    const size = @sizeOf(SharedNetBuffer);
    return (size + 4095) / 4096;
}

comptime {
    // Ensure structure fits in reasonable shared memory size
    // 104KB = 26 pages
    if (@sizeOf(SharedNetBuffer) > 26 * 4096) {
        @compileError("SharedNetBuffer too large for 26 pages");
    }
}
