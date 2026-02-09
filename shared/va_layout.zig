//------------------------------------------------------------------------------
// User Virtual Address Layout Constants
//------------------------------------------------------------------------------
// This file is the SINGLE SOURCE OF TRUTH for user VA regions (TTBR0).
// Both kernel and user-space import these constants.
//
// SOURCE OF TRUTH: This file is copied to lib/shared/ by gen-lib.
// Do not edit lib/shared/va_layout.zig directly.
//
// User VA Layout (TTBR0):
//   0x00010000 - 0x0FFFFFFF: Code/data segments (ELF load)
//   0x10000000 - 0x1000FFFF: Console ring (64KB, zero-syscall output)
//   0x10010000 - 0x1FFFFFFF: Shared memory regions (ICC buffers)
//   0x20000000 - 0x2FFFFFFF: Device MMIO mappings (drivers)
//   0x30000000 - 0x3FFFFFFF: Heap (256MB max, grows via sys_brk)
//   0x40000000 - 0x4FFFFFFF: DMA buffers (256MB, driver containers)
//   0x7FFFFF000000:          Stack (grows down)
//
// NOTE: Heap is dynamic (grows/shrinks via sys_brk) but has a HARD CAP
// at HEAP_VA_MAX (0x40000000). The kernel refuses sys_brk requests that
// would exceed this, preventing overlap with DMA region.
//
// Future: These constants may be replaced by a kernel-provided
// Container Info Block. See docs/roadmap/later/container_info_block.md
//
// Related: src/kernel/memory/layout.zig has kernel-space (TTBR1) layout
// and allocation parameters (initial heap size, stack sizes, etc.)
//------------------------------------------------------------------------------

/// Console ring buffer virtual address.
/// Kernel maps a per-container ring buffer here. User-space writes directly.
/// This enables zero-syscall console output (Level 2 TTY).
pub const CONSOLE_RING_VA: u64 = 0x10000000;

/// Console ring buffer size (64KB per container).
/// Header is 64 bytes, data region is capacity - 64 bytes.
pub const CONSOLE_RING_SIZE: u64 = 64 * 1024;

/// Number of pages for console ring.
pub const CONSOLE_RING_PAGES: u64 = CONSOLE_RING_SIZE / PAGE_SIZE;

/// Shared memory region base (starts after console ring).
/// Used for ICC shared buffers between containers.
pub const SHARED_VA_BASE: u64 = CONSOLE_RING_VA + CONSOLE_RING_SIZE; // 0x10010000

/// Shared memory region size (256MB - 64KB).
pub const SHARED_VA_SIZE: u64 = 0x10000000 - CONSOLE_RING_SIZE;

/// Device MMIO mapping base (for driver containers).
/// Drivers use sys_map_io to map device registers into this region.
pub const DEVICE_VA_BASE: u64 = 0x20000000;

/// Device MMIO region size (256MB).
pub const DEVICE_VA_SIZE: u64 = 0x10000000;

/// Heap region base (per-container dynamic allocation).
/// Containers call sys_brk to grow/shrink within this region.
/// User-space discovers heap_start via sys_brk(0), not this constant.
pub const HEAP_VA_BASE: u64 = 0x30000000;

/// Heap region maximum (hard limit enforced by kernel).
/// sys_brk requests exceeding this are refused.
pub const HEAP_VA_MAX: u64 = 0x40000000;

/// Maximum heap size per container (256MB).
pub const HEAP_VA_SIZE: u64 = HEAP_VA_MAX - HEAP_VA_BASE;

/// DMA buffer mapping base (for driver containers).
/// Drivers use sys_alloc_dma to allocate DMA-coherent memory here.
/// Starts at HEAP_VA_MAX to avoid overlap with heap.
pub const DMA_VA_BASE: u64 = 0x40000000;

/// DMA buffer region size (256MB).
pub const DMA_VA_SIZE: u64 = 0x10000000;

/// Page size constant (must match kernel).
pub const PAGE_SIZE: u64 = 4096;
