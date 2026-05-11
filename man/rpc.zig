//------------------------------------------------------------------------------
// Generic RPC Client Primitive — T1 vocabulary for T2 client modules
//------------------------------------------------------------------------------
//
// `rpc.call(peer, Spec, req, timeout)` collapses the load-bearing spine of
// every T2 RPC client (build IccMessage -> icc_send -> icc_recv -> assert
// reply type -> deserialize) into a single comptime-typed call.
//
// Per-peer schemas live in `src/shared/icc/protocols/<peer>.zig` and declare
// `Method`-shaped specs:
//
//   pub const Spawn = struct {
//       pub const REQ_TYPE: u16 = 0x3000;
//       pub const REPLY_TYPE: u16 = 0x3001;     // omit for `cast`-only specs
//       pub const Request = struct { ... };
//       pub const Reply = struct { ... };       // omit for `cast`-only specs
//       pub fn serialize(req: Request, payload: *[248]u8) void { ... }
//       pub fn deserialize(payload: *const [248]u8) Reply { ... } // for `call` specs
//   };
//
// This module is itself T1: it makes only T0 syscalls (icc_send, icc_recv,
// ns_lookup) and has no fixed peer. Each *instantiation* (a per-peer client
// module that pins a `PeerHandle`) is T2.
//
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Vocabulary primitive: parameterizes over peer; no fixed dependency.
pub const tier: u8 = 1;

const ERROR_BASE: u64 = 0xFFFF_FFFF_0000_0000;

inline fn isErr(v: u64) bool {
    return v >= ERROR_BASE;
}

/// A handle to a peer container. Construct via `fixed(id)` for compile-time
/// peer IDs (e.g. lamina = 1) or `lookup(name)` for namespace-resolved peers.
pub const PeerHandle = struct {
    id: u16,

    pub fn fixed(id: u16) PeerHandle {
        return .{ .id = id };
    }

    pub fn lookup(name: []const u8) error{NotFound}!PeerHandle {
        const r = sys.ns_lookup(@ptrCast(name.ptr), name.len);
        if (r == 0xFFFF or isErr(r)) return error.NotFound;
        return .{ .id = @truncate(r) };
    }
};

/// Bounded timeout for RPC calls. `.never` is the explicit "wait forever"
/// escape hatch — T1.3 of the tier contract forbids indefinite blocking in
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
pub const RpcError = error{ IccError, TimedOut, InvalidProtocol };

/// Send a request and wait for the matching reply.
///
/// Returns `Spec.Reply` on success; the per-method client wrapper is
/// responsible for inspecting reply fields and mapping to high-level errors.
/// This keeps the generic uniform across every reply shape (some replies have
/// an `err` discriminant byte, some have multiple status enums, some have
/// payload-overlapping unions). Callers do ~3-5 lines of error mapping.
///
/// Uses `sys.icc_recv_typed` so unrelated mailbox traffic (e.g. delayed
/// CONSOLE_SWITCH_RESULT from a prior shell command, or a stale message
/// from a previously-spawned child) cannot be mistaken for the reply.
/// The kernel walks the mailbox FIFO, extracts the slot whose `msg_type`
/// matches `Spec.REPLY_TYPE`, and leaves unrelated slots in place for the
/// right handler to consume.
pub fn call(
    peer: PeerHandle,
    comptime Spec: type,
    req: Spec.Request,
    timeout: Timeout,
) RpcError!Spec.Reply {
    var msg: sys.Message = undefined;
    msg.msg_type = Spec.REQ_TYPE;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    Spec.serialize(req, &msg.payload);

    if (isErr(sys.icc_send(peer.id, &msg))) return RpcError.IccError;
    if (isErr(sys.icc_recv_typed(&msg, Spec.REPLY_TYPE, timeout.toRaw()))) return RpcError.TimedOut;
    return Spec.deserialize(&msg.payload);
}

/// Fire-and-forget send. No reply expected; the kernel's mailbox semantics
/// guarantee delivery if `icc_send` returns success.
pub fn cast(
    peer: PeerHandle,
    comptime Spec: type,
    req: Spec.Request,
) error{IccError}!void {
    var msg: sys.Message = undefined;
    msg.msg_type = Spec.REQ_TYPE;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    Spec.serialize(req, &msg.payload);
    if (isErr(sys.icc_send(peer.id, &msg))) return error.IccError;
}

/// Receive primitive. For clients composing complex wire patterns
/// (e.g. opportunistic side-channel drains) on top of the generic.
pub fn recv(out: *sys.Message, timeout: Timeout) error{TimedOut}!void {
    if (isErr(sys.icc_recv(out, timeout.toRaw()))) return error.TimedOut;
}
