//------------------------------------------------------------------------------
// Cell identity helpers
//
// The kernel identifies a cell by (raw slot, generation): spawn /
// get_cell_id / cell_list and the channel-plane identity fields
// (EndpointView.peer_holder/closed_peer, chan_send's x1 dead-peer report,
// Message source_id + source_gen) all use the packed form
// `raw | generation << 16`. Live incarnations always carry generation >= 1;
// generation 0 is the "route to whoever holds this raw slot now" wildcard,
// an explicit opt-in.
//
// The lifecycle syscalls (kill / wait_for_exit) take the SAME packed
// identity and gen-gate it: a non-zero generation binds to that exact
// incarnation (a stale handle bounces -ESRCH and never touches the reused
// slot's occupant), while generation 0 is the route-to-current-occupant
// wildcard. So the full packed value is the right thing to pass through --
// pass the raw slot (generation 0) only when you deliberately want the
// current occupant.
//
// Every identity-carrying client needs the same moves -- split a packed
// identity, keep the FULL value for respawn detection and gen-gated
// kill / wait -- and until now each one hand-rolled the shifts. This module
// is that bit math, named.
//
// Usage:
//   const identity = @import("liblaminae").identity;
//
//   const id = identity.fromPacked(ch.peer);
//   // id.raw for the wildcard forms, full/packed for gen-gated compares
//   if (identity.fromPacked(re_resolved).generation != id.generation) {
//       // provider respawned onto the same slot -- rebind
//   }
//------------------------------------------------------------------------------

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Pure bit math -- no syscalls, no peer ICC.
pub const tier: u8 = 1;

/// A cell identity as the kernel sees it: a reusable raw slot index plus
/// the incarnation generation that makes reuse detectable.
pub const CellIdentity = struct {
    raw: u16,
    generation: u16,

    /// Pack into the wire form (`raw | generation << 16`) used by spawn
    /// returns, channel peer fields, and the gen-gated lifecycle syscalls.
    pub fn pack(self: CellIdentity) u32 {
        return @as(u32, self.raw) | (@as(u32, self.generation) << 16);
    }
};

/// Split a packed identity (the low 32 bits of a spawn result, or a channel
/// peer field) into (raw, generation).
pub fn fromPacked(v: u32) CellIdentity {
    return .{ .raw = @truncate(v), .generation = @truncate(v >> 16) };
}

/// The raw slot index of a packed identity -- the gen==0 wildcard form the
/// lifecycle syscalls (wait_for_exit, kill) treat as "the current occupant."
/// Pass the full packed value instead to gen-gate to a specific incarnation.
/// Messages carry the full identity (source_id + source_gen; see
/// IccMessage.sourceIdentity()).
pub fn rawOf(v: u32) u16 {
    return @truncate(v);
}

/// The incarnation generation of a packed identity. 0 only for the
/// wildcard/bare-raw form; live cells are always >= 1.
pub fn generationOf(v: u32) u16 {
    return @truncate(v >> 16);
}

const testing = @import("std").testing;

test "fromPacked splits raw and generation" {
    const id = fromPacked(0x0020_0007);
    try testing.expectEqual(@as(u16, 7), id.raw);
    try testing.expectEqual(@as(u16, 0x20), id.generation);
    try testing.expectEqual(@as(u32, 0x0020_0007), id.pack());
}

test "bare raw id has generation zero" {
    try testing.expectEqual(@as(u16, 0), generationOf(0x0007));
    try testing.expectEqual(@as(u16, 7), rawOf(0x0007));
}
