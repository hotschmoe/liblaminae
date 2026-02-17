//------------------------------------------------------------------------------
// Generic Shared Memory Primitives
//
// Composable building blocks for inter-container shared memory data planes.
// All types are extern structs for stable ABI layout across containers.
//
// Primitives:
//   RegionHeader    - Standard SHM region header with lifecycle states
//   SpscRing        - Fixed-entry single-producer/single-consumer ring buffer
//   BufferPool      - Bitmap-based buffer allocator (up to 64 slots)
//   ByteRing        - Variable-length byte stream ring buffer
//
// Barrier Convention:
//   All ring operations use DMB ISH (inner shareable data memory barrier)
//   between data access and index updates. This provides release/acquire
//   semantics for SPSC communication between containers on the same SoC.
//
// SOURCE OF TRUTH: This file is copied to lib/shared/ by gen-lib.
// Do not edit lib/shared/shm.zig directly.
//------------------------------------------------------------------------------

const barriers = @import("arch/barriers_el0.zig");

//------------------------------------------------------------------------------
// RegionHeader - Standard SHM Region Header (32 bytes)
//------------------------------------------------------------------------------

pub const RegionHeader = extern struct {
    magic: u32,
    version: u32,
    creator_id: u16,
    peer_id: u16,
    state: u32,
    _reserved: [16]u8,

    pub const MAGIC: u32 = 0x4C4D5348; // "LMSH"
    pub const VERSION: u32 = 1;

    pub const STATE_UNINIT: u32 = 0;
    pub const STATE_READY: u32 = 1;
    pub const STATE_PEER_ATTACHED: u32 = 2;

    pub fn init(self: *volatile RegionHeader, creator: u16) void {
        self.magic = MAGIC;
        self.version = VERSION;
        self.creator_id = creator;
        self.peer_id = 0;
        self.state = STATE_UNINIT;
        self._reserved = [_]u8{0} ** 16;
        barriers.dataSyncBarrierInner();
        self.state = STATE_READY;
    }

    pub fn validate(self: *volatile RegionHeader) bool {
        if (self.magic != MAGIC) return false;
        if (self.version != VERSION) return false;
        return self.state >= STATE_READY;
    }

    pub fn attachPeer(self: *volatile RegionHeader, peer: u16) void {
        self.peer_id = peer;
        barriers.dataSyncBarrierInner();
        self.state = STATE_PEER_ATTACHED;
    }
};

comptime {
    if (@sizeOf(RegionHeader) != 32)
        @compileError("RegionHeader must be exactly 32 bytes");
}

//------------------------------------------------------------------------------
// SpscRing - Fixed-Entry Single-Producer/Single-Consumer Ring Buffer
//
// Capacity must be a power of 2. One slot is sacrificed to distinguish
// empty (head == tail) from full ((head + 1) & mask == tail).
// Usable capacity is (capacity - 1) entries.
//------------------------------------------------------------------------------

pub fn SpscRing(comptime Entry: type, comptime capacity: u32) type {
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0)
            @compileError("SpscRing capacity must be a power of 2");
        if (@sizeOf(Entry) == 0)
            @compileError("SpscRing Entry must have non-zero size");
    }

    const mask: u32 = capacity - 1;

    return extern struct {
        const Self = @This();

        head: u32 align(8),
        tail: u32,
        _pad: [8]u8,
        entries: [capacity]Entry,

        pub fn init(self: *volatile Self) void {
            self.head = 0;
            self.tail = 0;
            self._pad = [_]u8{0} ** 8;
        }

        pub fn hasData(self: *volatile Self) bool {
            return self.head != self.tail;
        }

        pub fn hasSpace(self: *volatile Self) bool {
            return ((self.head + 1) & mask) != self.tail;
        }

        pub fn available(self: *volatile Self) u32 {
            return (self.head -% self.tail) & mask;
        }

        pub fn freeSlots(self: *volatile Self) u32 {
            return capacity - 1 - self.available();
        }

        /// Write entry to the ring. Caller MUST check hasSpace() first.
        pub fn produce(self: *volatile Self, entry: Entry) void {
            const idx = self.head;
            self.entries[idx] = entry;
            barriers.dataMemoryBarrierInner();
            self.head = (idx + 1) & mask;
        }

        /// Read and remove entry from the ring. Caller MUST check hasData() first.
        pub fn consume(self: *volatile Self) Entry {
            const idx = self.tail;
            const entry = self.entries[idx];
            barriers.dataMemoryBarrierInner();
            self.tail = (idx + 1) & mask;
            return entry;
        }

        /// Read entry without removing. Caller MUST check hasData() first.
        pub fn peek(self: *volatile Self) Entry {
            return self.entries[self.tail];
        }

        /// Get mutable pointer to the next produce slot. Call commitProduce() after writing.
        pub fn beginProduce(self: *volatile Self) *volatile Entry {
            return &self.entries[self.head];
        }

        /// Commit a previously begun produce (barrier + advance head).
        pub fn commitProduce(self: *volatile Self) void {
            barriers.dataMemoryBarrierInner();
            self.head = (self.head + 1) & mask;
        }
    };
}

//------------------------------------------------------------------------------
// BufferPool - Bitmap-Based Buffer Allocator
//
// Manages up to 64 fixed-size buffers using a u64 bitmap.
// Bit set = free, bit clear = allocated. Uses @ctz for O(1) allocation.
//------------------------------------------------------------------------------

pub fn BufferPool(comptime buf_size: u32, comptime count: u32) type {
    comptime {
        if (count == 0) @compileError("BufferPool count must be > 0");
        if (count > 64) @compileError("BufferPool count must be <= 64");
        if (buf_size == 0) @compileError("BufferPool buf_size must be > 0");
    }

    return extern struct {
        const Self = @This();

        free_bitmap: u64,
        _pad: [8]u8,
        buffers: [count][buf_size]u8,

        pub fn init(self: *volatile Self) void {
            self.free_bitmap = if (count == 64)
                0xFFFFFFFFFFFFFFFF
            else
                (@as(u64, 1) << @intCast(count)) - 1;
            self._pad = [_]u8{0} ** 8;
        }

        pub fn alloc(self: *volatile Self) ?u16 {
            const bitmap = self.free_bitmap;
            if (bitmap == 0) return null;
            const idx: u6 = @intCast(@ctz(bitmap));
            if (idx >= count) return null;
            self.free_bitmap = bitmap & ~(@as(u64, 1) << idx);
            return @as(u16, idx);
        }

        pub fn free(self: *volatile Self, idx: u16) void {
            if (idx >= count) return;
            self.free_bitmap |= @as(u64, 1) << @as(u6, @intCast(idx));
        }

        pub fn getBuffer(self: *volatile Self, idx: u16) ?[*]volatile u8 {
            if (idx >= count) return null;
            return @ptrCast(&self.buffers[idx]);
        }

        pub fn freeCount(self: *volatile Self) u32 {
            return @intCast(@popCount(self.free_bitmap));
        }
    };
}

//------------------------------------------------------------------------------
// ByteRing - Variable-Length Byte Stream Ring Buffer
//
// Power-of-2 capacity with one byte sacrificed (usable = capacity - 1).
// Handles wrap-around transparently in two-segment copies.
//------------------------------------------------------------------------------

pub fn ByteRing(comptime capacity: u32) type {
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0)
            @compileError("ByteRing capacity must be a power of 2");
    }

    const mask: u32 = capacity - 1;

    return extern struct {
        const Self = @This();

        head: u32 align(8),
        tail: u32,
        _pad: [8]u8,
        data: [capacity]u8,

        pub fn init(self: *volatile Self) void {
            self.head = 0;
            self.tail = 0;
            self._pad = [_]u8{0} ** 8;
        }

        pub fn availableBytes(self: *volatile Self) u32 {
            return (self.head -% self.tail) & mask;
        }

        pub fn freeBytes(self: *volatile Self) u32 {
            return capacity - 1 - self.availableBytes();
        }

        pub fn isEmpty(self: *volatile Self) bool {
            return self.head == self.tail;
        }

        pub fn isFull(self: *volatile Self) bool {
            return ((self.head + 1) & mask) == self.tail;
        }

        /// Write bytes to the ring. Returns number of bytes actually written.
        pub fn write(self: *volatile Self, src: []const u8) u32 {
            const free = self.freeBytes();
            const to_write: u32 = @min(@as(u32, @intCast(src.len)), free);
            if (to_write == 0) return 0;

            const h = self.head;
            const first_len = @min(to_write, capacity - h);

            for (0..first_len) |i| {
                self.data[h + @as(u32, @intCast(i))] = src[i];
            }

            const second_len = to_write - first_len;
            for (0..second_len) |i| {
                self.data[i] = src[first_len + i];
            }

            barriers.dataMemoryBarrierInner();
            self.head = (h + to_write) & mask;
            return to_write;
        }

        /// Read bytes from the ring into dst. Returns number of bytes actually read.
        pub fn read(self: *volatile Self, dst: []u8) u32 {
            const avail = self.availableBytes();
            const to_read: u32 = @min(@as(u32, @intCast(dst.len)), avail);
            if (to_read == 0) return 0;

            const t = self.tail;
            const first_len = @min(to_read, capacity - t);

            for (0..first_len) |i| {
                dst[i] = self.data[t + @as(u32, @intCast(i))];
            }

            const second_len = to_read - first_len;
            for (0..second_len) |i| {
                dst[first_len + i] = self.data[i];
            }

            barriers.dataMemoryBarrierInner();
            self.tail = (t + to_read) & mask;
            return to_read;
        }

        /// Skip bytes without reading. Returns number of bytes actually skipped.
        pub fn skip(self: *volatile Self, n: u32) u32 {
            const avail = self.availableBytes();
            const to_skip = @min(n, avail);
            if (to_skip == 0) return 0;

            barriers.dataMemoryBarrierInner();
            self.tail = (self.tail + to_skip) & mask;
            return to_skip;
        }
    };
}
