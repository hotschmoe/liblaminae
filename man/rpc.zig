//------------------------------------------------------------------------------
// RPC Vocabulary -- shared timeout + error types for channel RPC clients
//------------------------------------------------------------------------------
//
// What remains of the Break 6 mailbox RPC generic after the L4 migration.
// The transport spine (PeerHandle / lookup / call / cast / recv / recvFrom
// and the CONTRACT_HELLO handshake) died with the ambient mailbox: the wired
// endpoint is the peer binding now, and `channel.call` / `channel.cast`
// (lib/man/channel.zig) are the RPC spine. The wire-time hash check (CH.5)
// replaced the runtime handshake -- refusal lives at wire time (LAW 2).
//
// This module keeps the two vocabulary types every T2 client still shares,
// so per-client error sets and timeout constants stay uniform across peers.
//
//------------------------------------------------------------------------------

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Pure vocabulary: no syscalls, no fixed peer.
pub const tier: u8 = 1;

/// Bounded timeout for RPC calls. `.never` is the explicit "wait forever"
/// escape hatch -- T1.3 of the tier contract forbids indefinite blocking in
/// vocabulary code, so callers that pass `.never` are opting into T2 semantics
/// at the call site (and the tag is grep-auditable).
pub const Timeout = union(enum) {
    ns: u64,
    ms: u32,
    never,

    pub fn toRaw(self: Timeout) u64 {
        return switch (self) {
            .ns => |n| n,
            .ms => |m| @as(u64, m) * 1_000_000,
            .never => 0xFFFF_FFFF_FFFF_FFFF,
        };
    }
};

/// Errors common to every RPC call. Per-method error sets compose with this.
///
/// `ForgedReply` survives for source compatibility with error sets that
/// composed it, but the channel plane cannot produce it: a reply in-endpoint
/// is wired 1:1 to its provider, so there is no impostor to attribute a
/// timeout to.
pub const RpcError = error{ IccError, TimedOut, InvalidProtocol, ForgedReply };
