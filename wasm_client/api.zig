//------------------------------------------------------------------------------
// Wasm Client — RPC stub for the wasm3 runtime container
//------------------------------------------------------------------------------
//
// Two callers today: `user/programs/test_wasm3.zig` and
// `user/services/shell/main.zig` (commands `wasm` and `wasm-d`). Both
// re-declared `WasmMsgTag` and hand-rolled the RPC dance; this module
// collapses both into a typed surface.
//
// Daemonized vs. shared instance:
//   - `connectShared()` -- ns_lookup `wasm_prime`, lazily spawn if missing.
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
} || rpc.RpcError;

/// Pinned peer handle for one wasm3 instance. A `Client` is the typed
/// alternative to the raw `(u16 cid, msg_type, payload)` triple the shell
/// and test were juggling.
pub const Client = struct {
    peer: rpc.PeerHandle,

    pub fn id(self: Client) u16 {
        return self.peer.id;
    }

    /// Send PING, expect PONG. Bounded-timeout sanity check after spawn.
    pub fn ping(self: Client, timeout: rpc.Timeout) Error!void {
        _ = try rpc.call(self.peer, proto.Ping, .{}, timeout);
    }

    /// SET_NAME -> SET_NAME_OK.
    pub fn setName(self: Client, name: []const u8, timeout: rpc.Timeout) Error!void {
        _ = rpc.call(self.peer, proto.SetName, .{ .name = name }, timeout) catch |err|
            return if (err == rpc.RpcError.InvalidProtocol) Error.SetNameFailed else err;
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
        const reply = try rpc.call(self.peer, proto.LoadModule, .{ .path = path }, timeout);
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
        const reply = try rpc.call(self.peer, proto.CallFunc, .{ .name = name }, timeout);
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
        try sendRequest(self.peer, proto.CallFunc, .{ .name = name });
    }

    /// UNLOAD fire-and-forget.
    pub fn unload(self: Client) Error!void {
        rpc.cast(self.peer, proto.Unload, .{}) catch return Error.IccError;
    }
};

//------------------------------------------------------------------------------
// Constructors
//------------------------------------------------------------------------------

/// Look up the shared `wasm_prime` instance; if not registered, ask lamina
/// to spawn `/sys/drivers/wasm3` and wait `total_timeout` for the registry
/// entry to appear. Caller-supplied timeout covers the worst case (spawn
/// + driver init); the shell uses 5s.
pub fn connectShared(total_timeout: rpc.Timeout) Error!Client {
    if (rpc.PeerHandle.lookup(proto.NAMESPACE)) |peer| return .{ .peer = peer } else |_| {}
    _ = init_client.spawn("/sys/drivers/wasm3") catch return Error.SpawnFailed;
    return waitForNamespace(proto.NAMESPACE, total_timeout);
}

/// Spawn a fresh wasm3 instance and rename it to `daemon_name`. Returns a
/// `Client` pinned to the new container's ID. Used by the shell's
/// `wasm-d <path>` command for one-off persistent daemons.
///
/// `setname_timeout` covers the SET_NAME RPC. The function does **not**
/// register `daemon_name` in the namespace itself -- the wasm3 driver
/// does that on receiving SET_NAME.
pub fn spawnDedicated(
    daemon_name: []const u8,
    setname_timeout: rpc.Timeout,
) Error!Client {
    const id = init_client.spawn("/sys/drivers/wasm3") catch return Error.SpawnFailed;
    // Brief yields give the freshly-spawned driver time to reach its
    // icc_recv loop before SET_NAME arrives. Without this, SET_NAME can
    // race the driver's startup and the test program sees a SetNameFailed
    // even though the driver is healthy.
    _ = sys.yield();
    _ = sys.yield();
    const client: Client = .{ .peer = rpc.PeerHandle.fixed(@truncate(id)) };
    try client.setName(daemon_name, setname_timeout);
    return client;
}

/// Construct a `Client` over an already-resolved peer ID (e.g. a caller
/// who did their own `ns_lookup`).
pub fn fromPeerId(peer_id: u16) Client {
    return .{ .peer = rpc.PeerHandle.fixed(peer_id) };
}

//------------------------------------------------------------------------------
// Helpers
//------------------------------------------------------------------------------

const ERROR_BASE: u64 = 0xFFFF_FFFF_0000_0000;

inline fn isErr(v: u64) bool {
    return v >= ERROR_BASE;
}

fn sendRequest(
    peer: rpc.PeerHandle,
    comptime Spec: type,
    req: Spec.Request,
) Error!void {
    var msg: sys.Message = undefined;
    msg.msg_type = Spec.REQ_TYPE;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    Spec.serialize(req, &msg.payload);
    if (isErr(sys.icc_send(peer.id, &msg))) return Error.IccError;
}

fn waitForNamespace(name: []const u8, timeout: rpc.Timeout) Error!Client {
    const r = sys.ns_wait(@ptrCast(name.ptr), name.len, timeout.toRaw());
    if (isErr(r) or r == 0xFFFF) return Error.DriverNotFound;
    return .{ .peer = rpc.PeerHandle.fixed(@truncate(r)) };
}

/// Copy a slice into `buf`, truncating if `buf` is shorter. Returns the
/// populated prefix of `buf`.
fn copySlice(buf: []u8, src: []const u8) []u8 {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}
