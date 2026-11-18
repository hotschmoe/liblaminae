//------------------------------------------------------------------------------
// Channel acquisition + RPC-over-channels (channel_contract.md 15.2 / 15.3)
//------------------------------------------------------------------------------
//
// L4 vocabulary for the channel control plane. An RPC relationship is a
// bidirectional BUNDLE of two wired endpoint pairs -- a request channel
// (my out -> peer in) and a reply channel (peer out -> my in) -- carried as
// the lib-level `Channel{out, in}`; the kernel stays unidirectional.
//
// Wiring recipe (the orchestrator's side, for reference): per edge,
// chan_create pair C (consumer half) and pair P (provider half), then
// chan_wire(C.out, P.in) and chan_wire(P.out, C.in). Each SIDE then holds
// the two endpoints of ONE chan_create pair, so a holder pairs its own
// out<->in by `pair_id` -- never by (hash, direction), which mis-pairs a
// provider serving N clients of one contract (review R1 finding 6).
//
// Discovery is self-snapshot (15.3): no namespace, no mailbox bootstrap.
// The wire-time hash check (CH.5) already enforced contract agreement, so
// there is no CONTRACT_HELLO on this path -- refusal lives at wire time
// (LAW 2).
//
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const rpc = @import("rpc.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Vocabulary primitive: T0 syscalls only (chan_*, get_cell_id), no fixed
/// peer -- the peer binding is the wired endpoint itself.
pub const tier: u8 = 1;

/// Re-exported so channel clients need one import for timeouts.
pub const Timeout = rpc.Timeout;

const ERROR_BASE: u64 = 0xFFFF_FFFF_0000_0000;

/// Kernel Icc.PeerClosed errno -- what chan_send returns into a dead peer
/// (chan_recv uses OUTCOME_PEER_CLOSED = 1 instead; the two planes differ).
/// Mirrors lib/gen/errors.zig, asserted below so it cannot drift.
const PEER_CLOSED_ERRNO: u64 = 0xFFFF_FFFF_FFFF_0026;
comptime {
    const gen_errors = @import("../gen/errors.zig");
    if (@intFromEnum(gen_errors.Icc.PeerClosed) != PEER_CLOSED_ERRNO)
        @compileError("PEER_CLOSED_ERRNO mirror drifted from lib/gen/errors.zig");
}

inline fn isErr(v: u64) bool {
    return v >= ERROR_BASE;
}

/// chan_recv / chan_send x0 outcomes (channel_contract.md 10.4).
const OUTCOME_MESSAGE: u64 = 0;
const OUTCOME_PEER_CLOSED: u64 = 1;

/// A bidirectional RPC bundle: `out` sends requests, `in` receives replies
/// (consumer view) -- or `in` receives requests and `out` sends replies
/// (provider view). Both tokens belong to one chan_create pair of THIS
/// holder's half of the bundle.
pub const Channel = struct {
    out: u32,
    in: u32,
    /// The pair_id both tokens share -- stable per bundle, useful as a
    /// client key on the provider side.
    pair_id: u32,
    /// Packed gen-qualified CellId of the wired peer (the out end's
    /// peer_holder at discovery time) -- the provider's identity for
    /// callers that need it (diagnostics, respawn detection).
    peer: u32,
};

/// A cell can hold at most cap/2 pairs, hence at most cap/2 bundles.
pub const MAX_CHANNELS: usize = sys.MAX_ENDPOINTS_PER_CELL / 2;

pub const DiscoverError = error{ Missing, Ambiguous, SnapshotFailed };

/// All bundles of `contract_hash` this cell holds, paired by pair_id
/// (provider / multi-instance side). A pair_id group only forms a Channel
/// when the cell holds BOTH its out and its in and both are WIRED --
/// half-bundles (e.g. a lone granted in-endpoint) are not RPC channels and
/// are skipped. No allocation; results land in `buf`.
pub fn heldChannels(contract_hash: u64, buf: []Channel) error{SnapshotFailed}![]Channel {
    var snap: sys.EndpointSnapshot = undefined;
    if (isErr(sys.chan_snapshot(sys.get_cell_id(), &snap))) return error.SnapshotFailed;

    var n: usize = 0;
    var i: u32 = 0;
    while (i < snap.count) : (i += 1) {
        const out_e = snap.entries[i];
        if (out_e.contract_hash != contract_hash) continue;
        if (out_e.direction != 0) continue; // anchor each bundle on its out end
        if (out_e.state != 1) continue; // wired only
        var j: u32 = 0;
        while (j < snap.count) : (j += 1) {
            const in_e = snap.entries[j];
            if (in_e.pair_id != out_e.pair_id) continue;
            if (in_e.direction != 1 or in_e.state != 1) continue;
            if (n < buf.len) {
                buf[n] = .{ .out = out_e.token, .in = in_e.token, .pair_id = out_e.pair_id, .peer = out_e.peer_holder };
                n += 1;
            }
            break;
        }
    }
    return buf[0..n];
}

/// The UNIQUE bundle for `contract_hash` -- the single-provider CONSUMER
/// helper. `error.Ambiguous` (more than one bundle of this hash) steers
/// provider / .any-multi-instance callers to `heldChannels`. The channel
/// replacement for the Break 6 checked namespace lookup:
///
///   const ch = try channel.requiredChannel(proto.CONTRACT_HASH);
pub fn requiredChannel(contract_hash: u64) DiscoverError!Channel {
    var buf: [MAX_CHANNELS]Channel = undefined;
    const chans = try heldChannels(contract_hash, &buf);
    if (chans.len == 0) return error.Missing;
    if (chans.len > 1) return error.Ambiguous;
    return chans[0];
}

/// Errors from RPC over a channel. `PeerClosed` is LAW 3 surfacing through
/// the call: the wired peer died or closed; the caller re-acquires
/// (re-`requiredChannel` after the orchestrator re-wires) and retries.
pub const CallError = error{ IccError, TimedOut, InvalidProtocol, PeerClosed };

/// Send a request on `ch.out` and wait for the matching reply on `ch.in`.
/// `Spec` shape: REQ_TYPE/REPLY_TYPE/serialize/deserialize, as declared by
/// the protocol modules (src/shared/icc/protocols/*.zig).
///
/// NO sender-identity filtering (15.2): a reply in-endpoint is wired 1:1 to
/// exactly one provider, so any message on it is that provider's -- the
/// endpoint IS the peer binding. One outstanding request per channel keeps
/// FIFO reply matching unambiguous. A mistyped message on the reply
/// endpoint is a protocol break, not an impostor: fail InvalidProtocol.
pub fn call(
    ch: Channel,
    comptime Spec: type,
    req: Spec.Request,
    timeout: Timeout,
) CallError!Spec.Reply {
    var msg: sys.Message = undefined;
    msg.msg_type = Spec.REQ_TYPE;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    Spec.serialize(req, &msg.payload);

    const s = sys.chan_send(ch.out, &msg);
    // Send-side death is the ERRNO, not the recv-outcome tag (post-land
    // review, codex round-2 finding 1): mapping it to IccError left client
    // caches stale across a provider respawn.
    if (s.x0 == PEER_CLOSED_ERRNO) return CallError.PeerClosed;
    if (isErr(s.x0)) return CallError.IccError;

    const r = sys.chan_recv(ch.in, &msg, timeout.toRaw());
    if (r.x0 == OUTCOME_PEER_CLOSED) return CallError.PeerClosed;
    if (isErr(r.x0)) return CallError.TimedOut;
    if (msg.msg_type != Spec.REPLY_TYPE) return CallError.InvalidProtocol;
    return Spec.deserialize(&msg.payload);
}

/// Fire-and-forget send on `ch.out`. No reply expected.
pub fn cast(
    ch: Channel,
    comptime Spec: type,
    req: Spec.Request,
) CallError!void {
    var msg: sys.Message = undefined;
    msg.msg_type = Spec.REQ_TYPE;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    Spec.serialize(req, &msg.payload);
    const s = sys.chan_send(ch.out, &msg);
    if (s.x0 == PEER_CLOSED_ERRNO) return CallError.PeerClosed;
    if (isErr(s.x0)) return CallError.IccError;
}

/// Close every held endpoint of `contract_hash` whose state is PEER_CLOSED
/// -- the provider-side reclaim of dead clients' bundles (LAW 3: closure IS
/// the death notice). Returns the number closed. heldChannels deliberately
/// surfaces only WIRED bundles, so without this sweep at the serve-loop top
/// a provider's dead-client pairs leak until the per-cell budget wall
/// (found live: lamina hit EP_BUDGET 32 during a sequential test burst).
/// Undrained requests from a dead client are dropped with the pair -- there
/// is no one left to answer.
pub fn reclaimClosed(contract_hash: u64) usize {
    var snap: sys.EndpointSnapshot = undefined;
    if (isErr(sys.chan_snapshot(sys.get_cell_id(), &snap))) return 0;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < snap.count) : (i += 1) {
        const e = snap.entries[i];
        if (e.contract_hash != contract_hash) continue;
        if (e.state != 2) continue; // 2 = peer_closed
        _ = sys.chan_close(e.token);
        n += 1;
    }
    return n;
}

/// Flatten the in-endpoints of `chans` into `buf` for `wait_event_chan`
/// (15.6). The provider loop: heldChannels -> inTokens -> wait_event_chan
/// -> drain/serve whichever is ready -> re-derive on a payload-0 re-scan.
pub fn inTokens(chans: []const Channel, buf: []u32) []u32 {
    const n = @min(chans.len, buf.len);
    for (chans[0..n], 0..) |ch, i| buf[i] = ch.in;
    return buf[0..n];
}
