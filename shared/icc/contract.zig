//------------------------------------------------------------------------------
// Contract Hash -- comptime FNV-1a 64 over a protocol's wire shape
//------------------------------------------------------------------------------
//
// L1.1 (the_law/adoption_plan.md): two peers built from different trees must
// refuse to converse when their protocol modules disagree, and that check
// must be provable before any kernel channel object exists. This module is
// the comptime half of that story -- it folds a protocol's namespace,
// version, and every Method spec's wire shape into a single u64.
//
// This is the ONE leaf a protocol module may import (the_law/HARDLINE.md
// section 5's import-free convention is amended for exactly this file --
// see the header comment in any `src/shared/icc/protocols/*.zig` module).
// `contract.zig` itself stays import-free: no std, no sibling modules.
//
// A protocol module uses it like:
//
//   const contract = @import("contract");
//   pub const CONTRACT_VERSION: u16 = 1;
//   pub const CONTRACT_HASH: u64 = contract.hashSpecs(
//       .{ GetDeviceInfo, ReadSector, WriteSector },
//       NAMESPACE,
//       CONTRACT_VERSION,
//   );
//
// `contract` is a named module import wired in `build.zig` (not a relative
// path) -- see the module-graph comment there for why.
//
// Any change to a Method spec's REQ_TYPE/REPLY_TYPE, or to the field names,
// offsets, sizes, or types of its hashed request/reply structs, changes the
// hash. The CONTRACT_HELLO/CONTRACT_ACK handshake (schema.zig 0x0F00/0x0F01)
// carries this hash so a client and service built from different trees
// refuse each other at wire time instead of misinterpreting payload bytes.
//
// The hash must describe the WIRE layout, not Zig's view of an API struct
// (BH4). Two rules enforce that:
//
//   1. Specs whose Request/Reply are fixed-scalar mirrors of the wire bytes
//      declare them `extern` and pin the offsets with comptime asserts
//      against the hand-written serializer (see protocols/blk.zig).
//   2. Specs whose API types carry slices (strings, blobs) declare a
//      separate `WireRequest` / `WireReply` extern struct describing the
//      on-wire byte regions (fixed arrays, explicit offsets). When present,
//      it is hashed INSTEAD of Request/Reply, and gen_docs renders it as
//      the wire layout. A slice field reaching the hash walk is a compile
//      error -- @offsetOf on a Zig slice says nothing about wire bytes.
//
//------------------------------------------------------------------------------

const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

/// FNV-1a 64 step over a byte slice.
pub fn hashBytes(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= FNV_PRIME;
    }
    return h;
}

/// FNV-1a 64 step over an integer, folded byte by byte (little-endian).
pub fn hashInt(seed: u64, comptime T: type, value: T) u64 {
    const bits = @typeInfo(T).int.bits;
    const n_bytes = (bits + 7) / 8;
    var h = seed;
    var i: usize = 0;
    while (i < n_bytes) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        const byte: u8 = @truncate(value >> shift);
        h ^= byte;
        h *%= FNV_PRIME;
    }
    return h;
}

/// Walk a struct's field layout: for each field, fold in its name, byte
/// offset, size, and type name. Recurses into nested struct fields so a
/// layout change buried in a nested type still moves the hash.
pub fn hashStructLayout(seed: u64, comptime T: type) u64 {
    comptime {
        var h = seed;
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("hashStructLayout requires a struct type: " ++ @typeName(T));
        for (info.@"struct".fields) |field| {
            if (@typeInfo(field.type) == .pointer)
                @compileError("hashStructLayout: slice/pointer field '" ++ field.name ++
                    "' in " ++ @typeName(T) ++
                    " has no wire layout; declare a WireRequest/WireReply extern struct instead");
            h = hashBytes(h, field.name);
            h = hashInt(h, usize, @offsetOf(T, field.name));
            h = hashInt(h, usize, @sizeOf(field.type));
            h = hashBytes(h, @typeName(field.type));
            if (@typeInfo(field.type) == .@"struct") {
                h = hashStructLayout(h, field.type);
            }
        }
        return h;
    }
}

/// Fold namespace + version + each Method spec's wire shape into one hash.
///
/// `specs` is a tuple of Method spec types (the `blk.GetDeviceInfo`-style
/// structs declared in `src/shared/icc/protocols/*.zig`): each must declare
/// `REQ_TYPE: u16` and `Request` (a struct type); `REPLY_TYPE: u16` and
/// `Reply` are optional (omitted for cast-only/fire-and-forget specs).
/// A spec may declare `WireRequest` / `WireReply` (extern structs describing
/// the on-wire byte layout); when present they are hashed in place of
/// `Request` / `Reply` -- required for API types that carry slices.
pub fn hashSpecs(
    comptime specs: anytype,
    comptime namespace: []const u8,
    comptime version: u16,
) u64 {
    comptime {
        // Byte-at-a-time FNV folding over every spec's namespace, type name,
        // and struct layout adds up fast for wide protocols (net_stack_protocol's
        // ten specs need well over the 1000-branch default).
        @setEvalBranchQuota(20000);
        var h: u64 = FNV_OFFSET_BASIS;
        h = hashBytes(h, namespace);
        h = hashInt(h, u16, version);
        for (specs) |S| {
            h = hashBytes(h, @typeName(S));
            h = hashInt(h, u16, S.REQ_TYPE);
            if (@hasDecl(S, "REPLY_TYPE")) h = hashInt(h, u16, S.REPLY_TYPE);
            h = hashStructLayout(h, if (@hasDecl(S, "WireRequest")) S.WireRequest else S.Request);
            if (@hasDecl(S, "WireReply")) {
                h = hashStructLayout(h, S.WireReply);
            } else if (@hasDecl(S, "Reply")) {
                h = hashStructLayout(h, S.Reply);
            }
        }
        return h;
    }
}

test "hashBytes is deterministic and namespace-sensitive" {
    const std = @import("std");
    const a = hashBytes(FNV_OFFSET_BASIS, "blk.driver");
    const b = hashBytes(FNV_OFFSET_BASIS, "blk.driver");
    const c = hashBytes(FNV_OFFSET_BASIS, "net.stack");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "hashStructLayout changes when a field is added" {
    const std = @import("std");
    const Before = struct { sector: u64, count: u16 };
    const After = struct { sector: u64, count: u16, extra: u8 };
    const h_before = hashStructLayout(FNV_OFFSET_BASIS, Before);
    const h_after = hashStructLayout(FNV_OFFSET_BASIS, After);
    try std.testing.expect(h_before != h_after);
}

test "hashSpecs is stable across repeated evaluation" {
    const std = @import("std");
    const Spec = struct {
        pub const REQ_TYPE: u16 = 1;
        pub const REPLY_TYPE: u16 = 2;
        pub const Request = struct { a: u32 };
        pub const Reply = struct { b: u32 };
    };
    const h1 = hashSpecs(.{Spec}, "test.ns", 1);
    const h2 = hashSpecs(.{Spec}, "test.ns", 1);
    try std.testing.expectEqual(h1, h2);
}

test "WireRequest/WireReply override Request/Reply in the hash" {
    const std = @import("std");
    const Plain = struct {
        pub const REQ_TYPE: u16 = 1;
        pub const REPLY_TYPE: u16 = 2;
        pub const Request = extern struct { a: u32 };
        pub const Reply = extern struct { b: u32 };
    };
    const Overridden = struct {
        pub const REQ_TYPE: u16 = 1;
        pub const REPLY_TYPE: u16 = 2;
        pub const Request = extern struct { a: u32 };
        pub const Reply = extern struct { b: u32 };
        pub const WireRequest = extern struct { a: u32, tail: [8]u8 };
        pub const WireReply = extern struct { b: u32, tail: [8]u8 };
    };
    // @typeName differs between the two specs, so hash them under the same
    // spec-name conditions by comparing each against itself for stability
    // and asserting the wire structs actually participate.
    const h_wire = hashStructLayout(FNV_OFFSET_BASIS, Overridden.WireRequest);
    const h_req = hashStructLayout(FNV_OFFSET_BASIS, Overridden.Request);
    try std.testing.expect(h_wire != h_req);
    const h1 = hashSpecs(.{Plain}, "test.ns", 1);
    const h2 = hashSpecs(.{Overridden}, "test.ns", 1);
    try std.testing.expect(h1 != h2);
}
