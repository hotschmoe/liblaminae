//------------------------------------------------------------------------------
// VirtIO User-Space Library
//
// Phase 8.2: Provides VirtIO queue management for driver containers.
//
// This library implements the VirtIO specification (v1.2) for user-space
// driver containers. It handles:
// - MMIO register access (VirtIO over MMIO transport)
// - Virtqueue initialization and management
// - Descriptor chain building
// - Notification mechanisms
//
// Reference: https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html
//
// Design:
// - Zero std library dependencies (freestanding)
// - Works with sys_map_device for MMIO access
// - Works with sys_alloc_dma for queue memory
// - Memory barriers via barriers module
//
// Usage:
//   1. Map VirtIO device MMIO via sys_map_device
//   2. Allocate DMA memory via sys_alloc_dma for queues
//   3. Initialize device using this library
//   4. Submit/poll virtqueues
//------------------------------------------------------------------------------

const barriers = @import("../shared/arch/barriers_el0.zig");

//==============================================================================
// VirtIO MMIO Registers (Section 4.2.2 of VirtIO spec)
//==============================================================================

/// VirtIO MMIO register offsets
pub const MmioRegs = struct {
    /// Magic value ("virt" = 0x74726976)
    pub const MAGIC_VALUE: u32 = 0x000;
    /// Device version (2 for modern)
    pub const VERSION: u32 = 0x004;
    /// Device ID (1=net, 2=block, etc.)
    pub const DEVICE_ID: u32 = 0x008;
    /// Vendor ID
    pub const VENDOR_ID: u32 = 0x00C;
    /// Device features (read to select, write feature set)
    pub const DEVICE_FEATURES: u32 = 0x010;
    /// Device features selection
    pub const DEVICE_FEATURES_SEL: u32 = 0x014;
    /// Driver features
    pub const DRIVER_FEATURES: u32 = 0x020;
    /// Driver features selection
    pub const DRIVER_FEATURES_SEL: u32 = 0x024;
    /// Queue selector
    pub const QUEUE_SEL: u32 = 0x030;
    /// Max queue size
    pub const QUEUE_NUM_MAX: u32 = 0x034;
    /// Queue size
    pub const QUEUE_NUM: u32 = 0x038;
    /// Ready bit
    pub const QUEUE_READY: u32 = 0x044;
    /// Queue notify (write queue index to notify)
    pub const QUEUE_NOTIFY: u32 = 0x050;
    /// Interrupt status
    pub const INTERRUPT_STATUS: u32 = 0x060;
    /// Interrupt acknowledge
    pub const INTERRUPT_ACK: u32 = 0x064;
    /// Device status
    pub const STATUS: u32 = 0x070;
    /// Queue descriptor low
    pub const QUEUE_DESC_LOW: u32 = 0x080;
    /// Queue descriptor high
    pub const QUEUE_DESC_HIGH: u32 = 0x084;
    /// Queue available low
    pub const QUEUE_AVAIL_LOW: u32 = 0x090;
    /// Queue available high
    pub const QUEUE_AVAIL_HIGH: u32 = 0x094;
    /// Queue used low
    pub const QUEUE_USED_LOW: u32 = 0x0A0;
    /// Queue used high
    pub const QUEUE_USED_HIGH: u32 = 0x0A4;
    /// Config space starts at 0x100
    pub const CONFIG: u32 = 0x100;
};

/// VirtIO Device Status bits (Section 2.1)
pub const Status = struct {
    /// Guest OS has found the device
    pub const ACKNOWLEDGE: u8 = 1;
    /// Guest OS knows how to drive the device
    pub const DRIVER: u8 = 2;
    /// Driver setup complete, ready to drive
    pub const DRIVER_OK: u8 = 4;
    /// Feature negotiation complete
    pub const FEATURES_OK: u8 = 8;
    /// Device needs reset (fatal error)
    pub const DEVICE_NEEDS_RESET: u8 = 64;
    /// Driver gave up on the device
    pub const FAILED: u8 = 128;
};

/// VirtIO Device IDs
pub const DeviceId = struct {
    pub const NETWORK: u32 = 1;
    pub const BLOCK: u32 = 2;
    pub const CONSOLE: u32 = 3;
    pub const ENTROPY: u32 = 4;
    pub const BALLOON: u32 = 5;
    pub const SCSI: u32 = 8;
    pub const GPU: u32 = 16;
    pub const INPUT: u32 = 18;
    pub const SOCKET: u32 = 19;
};

/// VirtIO magic value (ASCII "virt")
pub const VIRTIO_MAGIC: u32 = 0x74726976;

//==============================================================================
// Virtqueue Structures (Section 2.6)
//==============================================================================

/// Virtqueue descriptor flags
pub const DescFlags = struct {
    /// Buffer continues via next field
    pub const NEXT: u16 = 1;
    /// Buffer is write-only (for device)
    pub const WRITE: u16 = 2;
    /// Buffer contains list of buffer descriptors
    pub const INDIRECT: u16 = 4;
};

/// Virtqueue descriptor (16 bytes)
/// Describes a buffer in guest memory
pub const VirtqDesc = extern struct {
    /// Guest physical address of buffer
    addr: u64,
    /// Length of buffer in bytes
    len: u32,
    /// Descriptor flags (NEXT, WRITE, INDIRECT)
    flags: u16,
    /// Index of next descriptor if NEXT flag set
    next: u16,
};

/// Virtqueue available ring header
pub const VirtqAvailHeader = extern struct {
    /// Available ring flags (0 = no interrupt needed)
    flags: u16,
    /// Index where driver puts next entry (modulo queue size)
    idx: u16,
};

/// Virtqueue used ring header
pub const VirtqUsedHeader = extern struct {
    /// Used ring flags
    flags: u16,
    /// Index where device puts next entry (modulo queue size)
    idx: u16,
};

/// Virtqueue used element (8 bytes)
pub const VirtqUsedElem = extern struct {
    /// Index of start of used descriptor chain
    id: u32,
    /// Total length written to descriptor chain
    len: u32,
};

//==============================================================================
// Virtqueue Manager
//==============================================================================

/// Maximum queue size (common default)
pub const MAX_QUEUE_SIZE: u16 = 256;

/// Size calculation helpers
pub fn descriptorTableSize(queue_size: u16) u64 {
    return @as(u64, queue_size) * @sizeOf(VirtqDesc);
}

pub fn availableRingSize(queue_size: u16) u64 {
    // Header (4 bytes) + ring entries (2 bytes each) + used_event (2 bytes)
    return 4 + (@as(u64, queue_size) * 2) + 2;
}

pub fn usedRingSize(queue_size: u16) u64 {
    // Header (4 bytes) + ring entries (8 bytes each) + avail_event (2 bytes)
    return 4 + (@as(u64, queue_size) * @sizeOf(VirtqUsedElem)) + 2;
}

/// Total memory needed for a virtqueue
pub fn virtqueueSize(queue_size: u16) u64 {
    // Descriptor table + Available ring + Used ring
    // Each section needs to be aligned
    const desc_size = alignUp(descriptorTableSize(queue_size), 4096);
    const avail_size = alignUp(availableRingSize(queue_size), 4096);
    const used_size = alignUp(usedRingSize(queue_size), 4096);
    return desc_size + avail_size + used_size;
}

/// Virtqueue state for driver use
pub const Virtqueue = struct {
    /// Queue size (number of descriptors)
    size: u16,
    /// Descriptor table pointer (VA)
    desc: [*]volatile VirtqDesc,
    /// Available ring pointer (VA)
    avail: *volatile VirtqAvailHeader,
    /// Used ring pointer (VA)
    used: *volatile VirtqUsedHeader,
    /// Available ring entries (immediately after header)
    avail_ring: [*]volatile u16,
    /// Used ring entries (immediately after header)
    used_ring: [*]volatile VirtqUsedElem,
    /// Physical addresses for device programming
    desc_pa: u64,
    avail_pa: u64,
    used_pa: u64,
    /// Last seen used index (for polling)
    last_used_idx: u16,
    /// Next available descriptor index
    free_head: u16,
    /// Number of free descriptors
    num_free: u16,
    /// Descriptor allocation tracking (simple linked list via next field)
    /// Each entry points to next free descriptor, or 0xFFFF if end
    free_list: [256]u16, // Static size for simplicity

    /// Initialize virtqueue from allocated DMA memory
    ///
    /// Parameters:
    /// - queue_size: Number of descriptors
    /// - va_base: Virtual address of allocated DMA memory
    /// - pa_base: Physical address of allocated DMA memory
    ///
    /// Memory layout:
    /// [0..desc_size): Descriptor table
    /// [desc_size..desc_size+avail_size): Available ring
    /// [desc_size+avail_size..): Used ring
    pub fn init(self: *Virtqueue, queue_size: u16, va_base: u64, pa_base: u64) void {
        self.size = queue_size;
        self.last_used_idx = 0;
        self.free_head = 0;
        self.num_free = queue_size;

        // Calculate offsets
        const desc_size = alignUp(descriptorTableSize(queue_size), 4096);
        const avail_size = alignUp(availableRingSize(queue_size), 4096);

        // Set up pointers (VA for CPU access)
        self.desc = @ptrFromInt(va_base);
        self.avail = @ptrFromInt(va_base + desc_size);
        self.used = @ptrFromInt(va_base + desc_size + avail_size);

        // Available ring entries start after header
        self.avail_ring = @ptrFromInt(va_base + desc_size + @sizeOf(VirtqAvailHeader));

        // Used ring entries start after header
        self.used_ring = @ptrFromInt(va_base + desc_size + avail_size + @sizeOf(VirtqUsedHeader));

        // Physical addresses for device
        self.desc_pa = pa_base;
        self.avail_pa = pa_base + desc_size;
        self.used_pa = pa_base + desc_size + avail_size;

        // Zero the memory regions
        const total_size = virtqueueSize(queue_size);
        const mem: [*]volatile u8 = @ptrFromInt(va_base);
        for (0..total_size) |i| {
            mem[i] = 0;
        }

        // Initialize free list (link all descriptors)
        for (0..queue_size) |i| {
            self.free_list[i] = @intCast(i + 1);
            self.desc[i].next = @intCast(i + 1);
        }
        // Mark last as end of list
        if (queue_size > 0) {
            self.free_list[queue_size - 1] = 0xFFFF;
            self.desc[queue_size - 1].next = 0;
        }

        // Memory barrier to ensure initialization is visible
        memoryBarrier();
    }

    /// Allocate a descriptor from the free list
    /// Returns descriptor index or 0xFFFF if none available
    pub fn allocDescriptor(self: *Virtqueue) u16 {
        if (self.num_free == 0) {
            return 0xFFFF;
        }

        const idx = self.free_head;
        self.free_head = self.free_list[idx];
        self.num_free -= 1;
        return idx;
    }

    /// Free a descriptor back to the free list
    pub fn freeDescriptor(self: *Virtqueue, idx: u16) void {
        self.free_list[idx] = self.free_head;
        self.free_head = idx;
        self.num_free += 1;
    }

    /// Free a descriptor chain (follows next pointers)
    pub fn freeChain(self: *Virtqueue, head: u16) void {
        var idx = head;
        while (true) {
            const desc = &self.desc[idx];
            const next = desc.next;
            const has_next = (desc.flags & DescFlags.NEXT) != 0;

            self.freeDescriptor(idx);

            if (!has_next) break;
            idx = next;
        }
    }

    /// Add a buffer to the available ring
    ///
    /// Parameters:
    /// - head: Index of first descriptor in chain
    ///
    /// Call this after setting up descriptor chain
    pub fn submitChain(self: *Virtqueue, head: u16) void {
        const avail_idx = self.avail.idx;
        self.avail_ring[avail_idx % self.size] = head;
        memoryBarrier();
        self.avail.idx = avail_idx +% 1;
        memoryBarrier();
    }

    /// Check if there are used buffers to process
    pub fn hasUsed(self: *Virtqueue) bool {
        memoryBarrier();
        return self.used.idx != self.last_used_idx;
    }

    /// Get next used buffer (returns descriptor head index and length)
    /// Call only if hasUsed() returns true
    pub fn popUsed(self: *Virtqueue) struct { idx: u16, len: u32 } {
        const used_idx = self.last_used_idx % self.size;
        const elem = self.used_ring[used_idx];
        self.last_used_idx +%= 1;
        return .{
            .idx = @truncate(elem.id),
            .len = elem.len,
        };
    }
};

//==============================================================================
// VirtIO Device Handle
//==============================================================================

/// VirtIO device handle for driver use
pub const VirtioDevice = struct {
    /// MMIO base address (VA from sys_map_device)
    mmio_base: u64,
    /// Device ID
    device_id: u32,
    /// Number of queues
    num_queues: u32,

    /// Read a 32-bit MMIO register
    pub fn read32(self: *const VirtioDevice, offset: u32) u32 {
        const ptr: *volatile u32 = @ptrFromInt(self.mmio_base + offset);
        return ptr.*;
    }

    /// Write a 32-bit MMIO register
    pub fn write32(self: *VirtioDevice, offset: u32, value: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(self.mmio_base + offset);
        ptr.* = value;
    }

    /// Initialize from MMIO base address
    /// Returns error if not a valid VirtIO device
    pub fn init(self: *VirtioDevice, mmio_va: u64) bool {
        self.mmio_base = mmio_va;

        // Verify magic value
        const magic = self.read32(MmioRegs.MAGIC_VALUE);
        if (magic != VIRTIO_MAGIC) {
            return false;
        }

        // Verify version (we support version 2 = modern)
        const version = self.read32(MmioRegs.VERSION);
        if (version != 2) {
            return false;
        }

        // Read device ID
        self.device_id = self.read32(MmioRegs.DEVICE_ID);
        if (self.device_id == 0) {
            // Device ID 0 means no device
            return false;
        }

        self.num_queues = 0;
        return true;
    }

    /// Reset the device
    pub fn reset(self: *VirtioDevice) void {
        self.write32(MmioRegs.STATUS, 0);
        memoryBarrier();
    }

    /// Get current device status
    pub fn getStatus(self: *const VirtioDevice) u8 {
        return @truncate(self.read32(MmioRegs.STATUS));
    }

    /// Set device status (OR with existing)
    pub fn setStatus(self: *VirtioDevice, status: u8) void {
        const current = self.getStatus();
        self.write32(MmioRegs.STATUS, current | status);
    }

    /// Begin device initialization sequence
    pub fn acknowledge(self: *VirtioDevice) void {
        self.reset();
        memoryBarrier();
        self.setStatus(Status.ACKNOWLEDGE);
        self.setStatus(Status.DRIVER);
    }

    /// Complete device initialization
    pub fn driverOk(self: *VirtioDevice) void {
        self.setStatus(Status.DRIVER_OK);
    }

    /// Read device features (32 bits at a time)
    pub fn readFeatures(self: *VirtioDevice, high: bool) u32 {
        self.write32(MmioRegs.DEVICE_FEATURES_SEL, if (high) 1 else 0);
        memoryBarrier();
        return self.read32(MmioRegs.DEVICE_FEATURES);
    }

    /// Write driver features (32 bits at a time)
    pub fn writeFeatures(self: *VirtioDevice, high: bool, features: u32) void {
        self.write32(MmioRegs.DRIVER_FEATURES_SEL, if (high) 1 else 0);
        memoryBarrier();
        self.write32(MmioRegs.DRIVER_FEATURES, features);
    }

    /// Finalize feature negotiation
    pub fn finalizeFeatures(self: *VirtioDevice) bool {
        self.setStatus(Status.FEATURES_OK);
        memoryBarrier();
        // Device should have FEATURES_OK set if it accepted
        return (self.getStatus() & Status.FEATURES_OK) != 0;
    }

    /// Get maximum queue size for a queue
    pub fn getQueueMaxSize(self: *VirtioDevice, queue_idx: u16) u16 {
        self.write32(MmioRegs.QUEUE_SEL, queue_idx);
        memoryBarrier();
        return @truncate(self.read32(MmioRegs.QUEUE_NUM_MAX));
    }

    /// Configure a queue
    pub fn configureQueue(
        self: *VirtioDevice,
        queue_idx: u16,
        queue_size: u16,
        desc_pa: u64,
        avail_pa: u64,
        used_pa: u64,
    ) void {
        self.write32(MmioRegs.QUEUE_SEL, queue_idx);
        memoryBarrier();

        self.write32(MmioRegs.QUEUE_NUM, queue_size);
        self.write32(MmioRegs.QUEUE_DESC_LOW, @truncate(desc_pa));
        self.write32(MmioRegs.QUEUE_DESC_HIGH, @truncate(desc_pa >> 32));
        self.write32(MmioRegs.QUEUE_AVAIL_LOW, @truncate(avail_pa));
        self.write32(MmioRegs.QUEUE_AVAIL_HIGH, @truncate(avail_pa >> 32));
        self.write32(MmioRegs.QUEUE_USED_LOW, @truncate(used_pa));
        self.write32(MmioRegs.QUEUE_USED_HIGH, @truncate(used_pa >> 32));

        memoryBarrier();
        self.write32(MmioRegs.QUEUE_READY, 1);
    }

    /// Notify device about queue updates
    pub fn notifyQueue(self: *VirtioDevice, queue_idx: u16) void {
        memoryBarrier();
        self.write32(MmioRegs.QUEUE_NOTIFY, queue_idx);
    }

    /// Acknowledge interrupts
    pub fn ackInterrupt(self: *VirtioDevice) u32 {
        const status = self.read32(MmioRegs.INTERRUPT_STATUS);
        self.write32(MmioRegs.INTERRUPT_ACK, status);
        return status;
    }

    /// Read config space byte
    pub fn readConfig8(self: *const VirtioDevice, offset: u32) u8 {
        const ptr: *volatile u8 = @ptrFromInt(self.mmio_base + MmioRegs.CONFIG + offset);
        return ptr.*;
    }

    /// Read config space u32
    pub fn readConfig32(self: *const VirtioDevice, offset: u32) u32 {
        const ptr: *volatile u32 = @ptrFromInt(self.mmio_base + MmioRegs.CONFIG + offset);
        return ptr.*;
    }

    /// Read config space u64
    pub fn readConfig64(self: *const VirtioDevice, offset: u32) u64 {
        const low = self.readConfig32(offset);
        const high = self.readConfig32(offset + 4);
        return @as(u64, low) | (@as(u64, high) << 32);
    }
};

//==============================================================================
// Utility Functions
//==============================================================================

/// Memory barrier (data synchronization)
pub inline fn memoryBarrier() void {
    barriers.dataMemoryBarrier();
}

/// Align value up to alignment
fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

