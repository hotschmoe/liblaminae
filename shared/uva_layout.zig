//------------------------------------------------------------------------------
// User Virtual Address Layout (TTBR0)
//------------------------------------------------------------------------------
// SINGLE SOURCE OF TRUTH for user-space VA regions. Both the kernel and
// the user-space library (`liblaminae`) import from this file. The kernel
// uses these constants to wire page-table mappings and validate syscall
// arguments; user code uses them to discover where heap/console/mmap live.
//
// SOURCE OF TRUTH: This file is copied verbatim to lib/shared/uva_layout.zig
// by `tools/gen_lib.zig` on every `zig build`. Do not hand-edit the lib copy.
//
// Layout (low -> high in TTBR0; canonical top-half is TTBR1 / kva_layout):
//
//   0x0000_0001_0000  code         (ELF load)
//   0x0000_1000_0000  console_ring (64KB, zero-syscall I/O)
//   0x0000_1001_0000  shared       (~256MB - 64KB, ICC buffers)
//   0x0000_2000_0000  device       (256MB, MMIO via sys_map_io)
//   0x0000_3000_0000  heap         (256MB, sys_brk)
//   0x0000_4000_0000  dma          (256MB, sys_alloc_dma)
//   0x0000_5000_0000  mmap         (512MB, anonymous mmap)
//   ...
//   0x7FFF_FF00_0000  user_stack_guard (1 page guard; usable stack continues above)
//
// HEAP is dynamic (grows/shrinks via sys_brk) but has a hard cap at heap.end()
// (= 0x4000_0000). The kernel refuses sys_brk requests beyond it. Tiling is
// proven gap-free and non-overlapping by the comptime block at the bottom of
// this file -- the historical "DMA at 0x3000_0000 collided with heap" bug
// class is caught at compile time.
//
// Future: these constants may be replaced by a kernel-provided Container
// Info Block. See docs/roadmap/later/container_info_block.md.
//
// Related: src/kernel/memory/kva_layout.zig holds kernel-space (TTBR1)
// regions. src/kernel/memory/layout.zig holds allocation parameters
// (initial heap size, stack sizes, etc.) -- not VA addresses.
//------------------------------------------------------------------------------

const va = @import("va_layout.zig");

/// User VA region type. Re-exported so consumers can write `uva.Range`
/// instead of `va_layout.VaRange(.user)` everywhere.
pub const Range = va.VaRange(.user);

/// Code/data segments (ELF load). Today no in-tree code reads this constant
/// -- load addresses come from the ELF header itself -- but it is declared
/// here for completeness and to anchor the tile from address 0x10000.
pub const code = Range.init(0x10000, 0x10000000 - 0x10000);

/// Per-container console ring buffer (Level 2 TTY, zero-syscall output).
/// Header is 64 bytes; data region is `size - 64`.
pub const console_ring = Range.init(0x10000000, 64 * 1024);

/// Shared-memory region for ICC buffers between containers. Starts at the
/// console ring's end so a misedit there shifts this one too, syntactically.
pub const shared = Range{ .base = console_ring.end(), .size = 0x10000000 - console_ring.size };

/// Device MMIO mappings for driver containers (`sys_map_io`).
pub const device = Range.init(0x20000000, 0x10000000);

/// Per-container dynamic heap. Containers call `sys_brk` to grow/shrink
/// inside this slot; user code discovers `heap_start` via `sys_brk(0)`
/// rather than reading this constant.
pub const heap = Range.init(0x30000000, 0x10000000);

/// DMA-coherent buffers for driver containers (`sys_alloc_dma`).
pub const dma = Range.init(0x40000000, 0x10000000);

/// Anonymous `sys_mmap` mappings (also backs Zig's page_allocator under
/// `liblaminae`).
pub const mmap = Range.init(0x50000000, 0x20000000);

/// Static guard page at the bottom of every container's user stack. Mapped
/// with PROT_NONE so EL0 access aborts (caught by the kernel fault handler
/// to produce a stack-overflow diagnostic). The usable stack continues above
/// `user_stack_guard.end()` and is sized per-container by `SpawnSpec`.
pub const user_stack_guard = Range.init(0x7FFFFF000000, va.PAGE_SIZE);

//------------------------------------------------------------------------------
// Comptime tiling invariant
//------------------------------------------------------------------------------
// Walk the low-half tile in declaration order and prove it is monotonic,
// gap-free, and non-overlapping. A misedit anywhere above produces a
// `@compileError` naming the offending region. Also asserts every base lies
// in the canonical low half (bit47 == 0) so a misplaced kernel-half value
// is caught at compile time too. The user-stack guard sits at the canonical
// top of TTBR0 and is checked independently.
comptime {
    const ordered = [_]Range{ code, console_ring, shared, device, heap, dma, mmap };
    const names = [_][]const u8{
        "code", "console_ring", "shared", "device", "heap", "dma", "mmap",
    };
    var prev: u64 = 0;
    for (ordered, names) |r, name| {
        const base_raw = r.base.raw();
        const end_raw = r.end().raw();
        if (base_raw >= end_raw) @compileError("VA region inverted/empty: " ++ name);
        if (base_raw < prev) @compileError("VA region overlaps prior region: " ++ name);
        if ((base_raw >> 47) != 0) @compileError("user VA region bit47 != 0: " ++ name);
        prev = end_raw;
    }
    if (user_stack_guard.base.raw() < prev) @compileError("user_stack_guard overlaps the low tile");
    if (user_stack_guard.size != va.PAGE_SIZE) @compileError("user_stack_guard must be exactly one page");
    if ((user_stack_guard.base.raw() >> 47) != 0) @compileError("user_stack_guard bit47 != 0");
}
