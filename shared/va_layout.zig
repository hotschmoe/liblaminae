//------------------------------------------------------------------------------
// Virtual Address Layout -- TYPES ONLY
//------------------------------------------------------------------------------
// This file holds the vocabulary for ARM64 virtual-address typing. The
// per-space constants live in:
//
//   src/shared/uva_layout.zig         -- TTBR0 (user)   constants
//   src/kernel/memory/kva_layout.zig  -- TTBR1 (kernel) constants
//
// Phantom-typing by `AddressSpace` makes `VirtAddr(.user)` and
// `VirtAddr(.kernel)` distinct compile-time types backed by the same
// `enum(u64)`. Mixing them at `VaRange.contains` or `BumpAllocator.alloc`
// boundaries is a type error, not a runtime panic.
//
// SOURCE OF TRUTH: This file is copied verbatim to lib/shared/va_layout.zig
// by `tools/gen_lib.zig` on every `zig build`. Do not hand-edit the lib copy.
//
//------------------------------------------------------------------------------

const std = @import("std");

/// Canonical PAGE_SIZE for AArch64 4KB granule. Bumping to 16K also requires
/// updating TCR_EL1 TG0/TG1 in `src/arch/aarch64/common/mmu.zig`.
pub const PAGE_SIZE: u64 = 4096;

/// Which translation regime a VA lives in. TTBR0 carries `.user` (low half,
/// bit47 == 0); TTBR1 carries `.kernel` (high half, bit47 == 1). The enum is
/// a comptime discriminator -- it never appears in a register or struct
/// field at runtime.
pub const AddressSpace = enum { user, kernel };

/// A typed virtual address. `space` is a comptime parameter, so
/// `VirtAddr(.user)` and `VirtAddr(.kernel)` are distinct types that cannot
/// be assigned to one another without an explicit conversion at the
/// uaccess boundary.
///
/// Backed by `enum(u64) { _ }` so no field accessors, no struct padding,
/// and `@intFromEnum` / `@enumFromInt` are the only ways in or out -- the
/// raw u64 stays explicit at the boundary.
///
/// Pointer conversion (`toPtr`/`fromPtr`) is provided so kernel code can
/// dereference kernel VAs and capture VAs from `&symbol`-style addresses
/// without an `@intFromEnum`/`@ptrFromInt` dance at every site. The space
/// tag travels with the value, so `VirtAddr(.kernel).toPtr(*T)` cannot be
/// accidentally written from a TTBR0 value.
pub fn VirtAddr(comptime space: AddressSpace) type {
    return enum(u64) {
        _,
        pub const addr_space: AddressSpace = space;

        pub inline fn raw(self: @This()) u64 {
            return @intFromEnum(self);
        }

        pub inline fn fromRaw(v: u64) @This() {
            return @enumFromInt(v);
        }

        pub inline fn offset(self: @This(), bytes: u64) @This() {
            return @enumFromInt(@intFromEnum(self) +% bytes);
        }

        /// Offset with overflow detection. Returns `null` if `raw() + bytes`
        /// would overflow `u64`. Use when adding caller-supplied byte counts
        /// where the upper bound isn't statically known.
        pub inline fn tryOffset(self: @This(), bytes: u64) ?@This() {
            const sum, const overflow = @addWithOverflow(@intFromEnum(self), bytes);
            if (overflow != 0) return null;
            return @enumFromInt(sum);
        }

        /// Round forward to the next multiple of `alignment` (which must be
        /// a power of two). Wraps via `std.mem.alignForward`.
        pub inline fn alignForward(self: @This(), alignment: u64) @This() {
            return @enumFromInt(std.mem.alignForward(u64, @intFromEnum(self), alignment));
        }

        pub inline fn isAligned(self: @This(), alignment: u64) bool {
            return std.mem.isAligned(@intFromEnum(self), alignment);
        }

        /// AArch64 canonical-form check (48-bit VA, T0SZ/T1SZ=16). Bits
        /// 63..47 must all match bit 47: either all-zero (TTBR0 / user
        /// half) or all-one (TTBR1 / kernel half). Non-canonical VAs
        /// translation-fault on dereference.
        pub inline fn isCanonical(self: @This()) bool {
            const upper = @intFromEnum(self) >> 47;
            return upper == 0 or upper == 0x1FFFF;
        }

        /// Convert to a pointer. `T` must be a pointer type; a non-pointer
        /// `T` would otherwise produce a confusing `@ptrFromInt` error deep
        /// inside a generic monomorphization.
        pub inline fn toPtr(self: @This(), comptime T: type) T {
            comptime {
                if (@typeInfo(T) != .pointer) {
                    @compileError("VirtAddr.toPtr: T must be a pointer type, got " ++ @typeName(T));
                }
            }
            return @ptrFromInt(@intFromEnum(self));
        }

        /// Capture a pointer as a typed VA. `ptr` must be a pointer; passing
        /// a non-pointer (e.g. integer) is almost always an accidental call
        /// and would produce a confusing `@intFromPtr` error otherwise.
        pub inline fn fromPtr(ptr: anytype) @This() {
            comptime {
                const PtrType = @TypeOf(ptr);
                if (@typeInfo(PtrType) != .pointer) {
                    @compileError("VirtAddr.fromPtr: argument must be a pointer, got " ++ @typeName(PtrType));
                }
            }
            return @enumFromInt(@intFromPtr(ptr));
        }
    };
}

/// A contiguous half-open `[base, base+size)` slot in virtual address
/// space, tagged with the space it lives in. `VaRange(.user)` and
/// `VaRange(.kernel)` are distinct types: `contains(va)` requires the
/// matching `VirtAddr(space)`, so passing a TTBR1 VA into a TTBR0 range
/// (or vice versa) is a compile error.
///
/// `base` is itself a typed `VirtAddr(space)` so callers can pass
/// `uva_layout.heap.base` directly into typed-VA function parameters
/// without an `UVA.fromRaw(...)` wrap. Use `Range.init(base_raw, size)`
/// for compact constant declarations.
pub fn VaRange(comptime space: AddressSpace) type {
    return struct {
        base: VA,
        size: u64,

        pub const addr_space: AddressSpace = space;
        pub const VA = VirtAddr(space);

        /// Compact constructor for region-table declarations:
        ///     pub const heap = Range.init(0x30000000, 0x10000000);
        /// Equivalent to `Range{ .base = VA.fromRaw(b), .size = s }`.
        pub fn init(base_raw: u64, size_bytes: u64) @This() {
            return .{ .base = VA.fromRaw(base_raw), .size = size_bytes };
        }

        pub fn end(s: @This()) VA {
            return s.base.offset(s.size);
        }

        pub fn contains(s: @This(), va: VA) bool {
            const v = va.raw();
            const base_raw = s.base.raw();
            return v >= base_raw and v < base_raw + s.size;
        }

        /// True iff `[va, va+len)` fits entirely inside the range.
        /// Zero-length spans are accepted iff `va` itself is in-range; the
        /// overflow check rejects requests where `va + len` wraps.
        pub fn containsRange(s: @This(), va: VA, len: u64) bool {
            const v = va.raw();
            const base_raw = s.base.raw();
            if (v < base_raw) return false;
            const tail = v +% len;
            if (tail < v) return false; // u64 overflow
            return tail <= base_raw + s.size;
        }

        pub fn pageCount(s: @This()) u64 {
            return s.size / PAGE_SIZE;
        }
    };
}

/// Monotonic bump allocator over a comptime-bound `VaRange(space)`. The
/// space is inferred from the range, so `alloc()` returns the matching
/// `?VirtAddr(space)` -- handing the result to a function expecting the
/// wrong space is a compile error.
///
/// `range` is `anytype` so callers can pass either `VaRange(.user)` or
/// `VaRange(.kernel)` values without naming the type at the call site.
/// `next` defaults to `range.base` so `.{}` yields a ready-to-use
/// allocator with no init() call. Callers page-align `len` before calling
/// `alloc`; there is no free.
pub fn BumpAllocator(comptime range: anytype) type {
    const Range = @TypeOf(range);
    const space: AddressSpace = Range.addr_space;
    const VA = VirtAddr(space);

    return struct {
        next: u64 = range.base.raw(),

        pub fn alloc(self: *@This(), len: u64) ?VA {
            const cur = VA.fromRaw(self.next);
            if (!range.containsRange(cur, len)) return null;
            self.next += len;
            return cur;
        }
    };
}
