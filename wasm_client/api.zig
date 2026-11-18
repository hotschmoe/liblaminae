//------------------------------------------------------------------------------
// Wasm Client -- RPC stub for the wasm3 runtime cell
//------------------------------------------------------------------------------
//
// Two callers today: `user/programs/test_wasm3.zig` and
// `user/services/shell/main.zig` (commands `wasm` and `wasm-d`). Both
// re-declared `WasmMsgTag` and hand-rolled the RPC dance; this module
// collapses both into a typed surface.
//
// Daemonized vs. shared instance:
//   - `connectShared()` -- lamina dynamic Connect to `wasm_prime`.
//   - `spawnDedicated(name)` -- spawn a fresh wasm3 and SET_NAME it.
// Both return a `Client` value that pins a peer ID; subsequent calls
// (`load`, `callFunc`, `ping`) use that pinned peer.
//
// Usage:
//   var client = try wasm.connectShared(.{ .ms = 5000 });
//   try client.load("/sys/wasm/hello");
//   const out = try client.callFunc("_start", &output_buf, .{ .ms = 30000 });
//
//------------------------------------------------------------------------------

const rpc = @import("../man/rpc.zig");
const channel = @import("../man/channel.zig");
const proto = @import("wasm_protocol");
const init_client = @import("../init_client/api.zig");
const sys = @import("../gen/syscalls.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Thin RPC client of the wasm3 driver -- bounded-timeout ICC for module
/// load/call. Peer-dependent, hence T2.
pub const tier: u8 = 2;

/// Re-export protocol vocabulary for callers that need raw constants.
pub const WasmMsgType = proto.WasmMsgType;
pub const MAX_PAYLOAD_STR = proto.MAX_PAYLOAD_STR;

pub const Error = error{
    DriverNotFound,
    SpawnFailed,
    SetNameFailed,
    LoadFailed,
    CallFailed,
    UnexpectedReply,
    /// L1.1 (the_law/adoption_plan.md): a `wasm_prime`-named peer answered
    /// but its protocol module's CONTRACT_HASH disagrees with ours.
    ContractMismatch,
} || rpc.RpcError;

/// One wired wasm3 bundle (L4: the channel IS the peer binding). A
/// `Client` is the typed alternative to the raw `(u16 cid, msg_type,
/// payload)` triple the shell and test were juggling.
pub const Client = struct {
    ch: channel.Channel,

    /// Generation-qualified identity of the wasm3 peer (raw | gen<<16).
    /// Never truncate to u16 -- that is the gen-0 wildcard hole.
    pub fn id(self: Client) u32 {
        return self.ch.peer;
    }

    /// Send PING, expect PONG. Bounded-timeout sanity check after spawn.
    pub fn ping(self: Client, timeout: rpc.Timeout) Error!void {
        _ = try mapCall(self.ch, proto.Ping, .{}, timeout);
    }

    /// SET_NAME -> SET_NAME_OK. Post-L4 this is a display name only (the
    /// bundle is the address; no namespace registration happens).
    pub fn setName(self: Client, name: []const u8, timeout: rpc.Timeout) Error!void {
        _ = mapCall(self.ch, proto.SetName, .{ .name = name }, timeout) catch |err|
            return if (err == Error.UnexpectedReply) Error.SetNameFailed else err;
    }

    /// LOAD_MODULE -> LOAD_RESULT { status, message }. On error, optional
    /// `err_buf` (if non-null) receives the driver's error string; returns
    /// `LoadFailed`.
    pub fn load(
        self: Client,
        path: []const u8,
        err_buf: ?[]u8,
        timeout: rpc.Timeout,
    ) Error!void {
        const reply = try mapCall(self.ch, proto.LoadModule, .{ .path = path }, timeout);
        switch (reply.status) {
            .ok => return,
            .err => {
                if (err_buf) |buf| _ = copySlice(buf, reply.message());
                return Error.LoadFailed;
            },
        }
    }

    /// CALL_FUNC -> CALL_RESULT { status, output }. On success, optional
    /// `out_buf` (if non-null) receives the captured stdout written by the
    /// wasm program; the returned slice is the populated prefix of `out_buf`.
    /// On error, returns `CallFailed`.
    pub fn callFunc(
        self: Client,
        name: []const u8,
        out_buf: ?[]u8,
        timeout: rpc.Timeout,
    ) Error![]u8 {
        const reply = try mapCall(self.ch, proto.CallFunc, .{ .name = name }, timeout);
        switch (reply.status) {
            .ok => {
                if (out_buf) |buf| return copySlice(buf, reply.output());
                return &.{};
            },
            .err => return Error.CallFailed,
        }
    }

    /// CALL_FUNC fire-and-forget. Used for daemonized wasm modules where
    /// the caller doesn't want a reply (the daemon's mailbox would otherwise
    /// fill with stale CALL_RESULT messages).
    pub fn callFuncCast(self: Client, name: []const u8) Error!void {
        channel.cast(self.ch, proto.CallFunc, .{ .name = name }) catch return Error.IccError;
    }

    /// UNLOAD fire-and-forget.
    pub fn unload(self: Client) Error!void {
        channel.cast(self.ch, proto.Unload, .{}) catch return Error.IccError;
    }
};

/// channel.call with the error set mapped into this client's vocabulary.
fn mapCall(ch: channel.Channel, comptime Spec: type, req: Spec.Request, timeout: rpc.Timeout) Error!Spec.Reply {
    return channel.call(ch, Spec, req, timeout) catch |err| switch (err) {
        channel.CallError.InvalidProtocol => Error.UnexpectedReply,
        channel.CallError.PeerClosed => Error.DriverNotFound,
        channel.CallError.TimedOut => Error.TimedOut,
        channel.CallError.IccError => Error.IccError,
    };
}

fn clientFromConnection(conn: init_client.Connection) Client {
    return .{ .ch = .{ .out = conn.out_tok, .in = conn.in_tok, .pair_id = 0, .peer = conn.provider } };
}

//------------------------------------------------------------------------------
// Constructors
//------------------------------------------------------------------------------

/// Acquire a bundle to the SHARED `wasm_prime` instance via lamina's
/// dynamic Connect (channel_contract.md 15.5): lamina spawns wasm3 on
/// demand, wires a fresh bundle, and delivers our half -- authorization is
/// this cell's manifest `.dynamic` requires entry. The old lookup/spawn/
/// ns_wait dance and the CONTRACT_HELLO handshake are gone (contract
/// agreement is the wire-time hash check).
pub fn connectShared(total_timeout: rpc.Timeout) Error!Client {
    _ = total_timeout; // lamina's Connect carries its own spawn budget
    const conn = init_client.connect(proto.NAMESPACE, false) catch |err| return switch (err) {
        init_client.ConnectError.SpawnFailed => Error.SpawnFailed,
        init_client.ConnectError.Unauthorized, init_client.ConnectError.NoProvider => Error.DriverNotFound,
        init_client.ConnectError.TimedOut => Error.TimedOut,
        else => Error.IccError,
    };
    return clientFromConnection(conn);
}

/// Spawn a fresh wasm3 instance and rename it to `daemon_name`. Returns a
/// `Client` pinned to the new cell's ID. Used by the shell's
/// `wasm-d <path>` command for one-off persistent daemons.
///
/// `setname_timeout` covers the SET_NAME RPC. Identity is the wired
/// bundle plus the SET_NAME payload -- there is no namespace registry.
pub fn spawnDedicated(
    daemon_name: []const u8,
    setname_timeout: rpc.Timeout,
) Error!Client {
    const conn = init_client.connect(proto.NAMESPACE, true) catch |err| return switch (err) {
        init_client.ConnectError.SpawnFailed => Error.SpawnFailed,
        else => Error.IccError,
    };
    const client = clientFromConnection(conn);
    // No startup race: the bundle's queue holds SET_NAME until the fresh
    // driver's serve loop drains it.
    try client.setName(daemon_name, setname_timeout);
    return client;
}

//------------------------------------------------------------------------------
// Helpers
//------------------------------------------------------------------------------

const ERROR_BASE: u64 = 0xFFFF_FFFF_0000_0000;

inline fn isErr(v: u64) bool {
    return v >= ERROR_BASE;
}

/// Copy a slice into `buf`, truncating if `buf` is shorter. Returns the
/// populated prefix of `buf`.
fn copySlice(buf: []u8, src: []const u8) []u8 {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}
