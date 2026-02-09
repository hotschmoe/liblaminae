//------------------------------------------------------------------------------
// User-Space Heap Allocator
//------------------------------------------------------------------------------
// Bump allocator backed by sys_brk for dynamic memory allocation.
//
// Design:
// - Simple bump allocator (no free, grows monotonically)
// - Uses sys_brk to request pages from kernel
// - Thread-unsafe (single container, single execution context)
// - Suitable for containers that need dynamic allocation
//
// Usage:
//   const heap = @import("liblaminae").heap;
//   const ptr = heap.alloc(1024) orelse return error.OutOfMemory;
//   // use ptr...
//   // free is a no-op for bump allocator
//
// Memory Layout:
//   heap_start: 0x30000000 (from kernel)
//   heap_break: grows upward via sys_brk
//   heap_max:   0x40000000 (256MB limit)
//------------------------------------------------------------------------------

const syscalls = @import("../gen/syscalls.zig");

/// Heap state - initialized by init() or lazily on first alloc
var heap_start: usize = 0;
var heap_break: usize = 0;
var heap_max: usize = 0;
var initialized: bool = false;

/// Alignment for all allocations (8 bytes for 64-bit)
const ALIGNMENT: usize = 8;

/// Page size (must match kernel)
const PAGE_SIZE: usize = 4096;

/// Maximum heap size (256MB)
const MAX_HEAP_SIZE: usize = 256 * 1024 * 1024;

//------------------------------------------------------------------------------
// Public API
//------------------------------------------------------------------------------

/// Initialize the heap by querying current break from kernel.
/// Called automatically on first alloc if not already initialized.
pub fn init() void {
    if (initialized) return;

    // Query current heap break from kernel
    const current_break = syscalls.brk(0);
    if (current_break == 0) {
        // No heap allocated - this shouldn't happen if kernel sets up initial heap
        return;
    }

    heap_start = current_break;
    heap_break = current_break;
    heap_max = heap_start + MAX_HEAP_SIZE;
    initialized = true;
}

/// Allocate size bytes from heap.
/// Returns null if allocation fails or heap exhausted.
pub fn alloc(size: usize) ?[*]u8 {
    return alignedAlloc(size, ALIGNMENT);
}

/// Allocate size bytes with specific alignment.
pub fn alignedAlloc(size: usize, alignment: usize) ?[*]u8 {
    if (size == 0) return null;

    // Lazy initialization
    if (!initialized) {
        init();
        if (!initialized) return null;
    }

    // Align current break
    const aligned_start = alignUp(heap_break, alignment);
    const new_break = aligned_start + size;

    // Check if we need to grow heap
    if (new_break > heap_max) {
        return null; // Would exceed max heap size
    }

    // Request more memory from kernel if needed
    if (new_break > heap_break) {
        const result = syscalls.brk(new_break);
        if (result < new_break) {
            return null; // Kernel refused to grow heap
        }
        heap_break = result;
    }

    return @ptrFromInt(aligned_start);
}

/// Free memory (no-op for bump allocator).
/// Included for API compatibility.
pub fn free(_: [*]u8) void {
    // Bump allocator doesn't support individual frees
}

/// Reset heap to initial state (frees all allocations).
/// Use with caution - invalidates all previously allocated pointers.
pub fn reset() void {
    if (!initialized) return;

    // Shrink heap back to start
    _ = syscalls.brk(heap_start);
    heap_break = heap_start;
}

/// Get current heap usage in bytes.
pub fn usage() usize {
    if (!initialized) return 0;
    return heap_break - heap_start;
}

/// Get remaining heap capacity in bytes.
pub fn remaining() usize {
    if (!initialized) return MAX_HEAP_SIZE;
    return heap_max - heap_break;
}

//------------------------------------------------------------------------------
// Zig Allocator Interface
//------------------------------------------------------------------------------

const std = @import("std");

/// Zig allocator interface for the heap.
/// Allows using heap with std.ArrayList, std.StringHashMap, etc.
pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &vtable,
};

const vtable = std.mem.Allocator.VTable{
    .alloc = zigAlloc,
    .resize = zigResize,
    .free = zigFree,
};

fn zigAlloc(_: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
    return alignedAlloc(len, @as(usize, 1) << @intCast(ptr_align));
}

fn zigResize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
    // Bump allocator doesn't support resize
    return false;
}

fn zigFree(_: *anyopaque, _: []u8, _: u8, _: usize) void {
    // Bump allocator doesn't support free
}

//------------------------------------------------------------------------------
// Internal Helpers
//------------------------------------------------------------------------------

fn alignUp(addr: usize, alignment: usize) usize {
    return (addr + alignment - 1) & ~(alignment - 1);
}
