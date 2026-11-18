//------------------------------------------------------------------------------
// Network API - Socket-like Interface for Applications
//
// Provides TCP/UDP connectivity for user cells via ICC + SHM to a
// network stack cell (zmoltcp).
//
// Architecture:
//   App Cell --ICC + SHM--> Network Stack --packets--> HW Driver
//
// Surface:
//   `connect(...)` returns a `SocketStream` value that owns the socket id,
//   the (optional) per-socket SHM region, and the kernel handle for that
//   region. `read` / `write` / `close` are methods on `SocketStream`.
//
//   When the network stack offers SHM (zmoltcp post-C8.13a), the data
//   path is T1 ring access + `wait_event` notifications. When it doesn't
//   (UDP, offer race lost, future stacks), the path falls back to ICC
//   RPC unchanged. Callers don't see the difference except in tail
//   latency.
//
// Timeout Convention:
//   All blocking ops accept a `timeout_ms`:
//     0 = wait forever (no timeout)
//     N = timeout in milliseconds
//
// Usage:
//   const lib = @import("liblaminae");
//   const net = lib.net_client;
//
//   try net.init();
//   var stream = try net.connect(ip, port, .tcp, 5000);
//   defer stream.close();
//   _ = try stream.write(data, 0);
//   const n = try stream.read(buf, 1000);
//
// Abstract Operations (stack handles topology):
//   const result = try net.pingGateway(1, 3000);
//   const config = try net.getConfig(0);
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const errors = @import("../gen/errors.zig");
const protocol = @import("net_stack_protocol");
const socket_shm = @import("../man/socket_shm.zig");
const socket_stream = @import("../man/socket_stream.zig");
const channel = @import("../man/channel.zig");
const init_client = @import("../init_client/api.zig");

pub const ReadStream = socket_stream.ReadStream;
pub const WriteStream = socket_stream.WriteStream;

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Bounded-timeout ICC RPC fallback + SHM fast path. Peer-dependent on
/// the network stack cell, hence T2 not T1.
pub const tier: u8 = 2;

// Re-export protocol types for convenience
pub const MsgType = protocol.MsgType;
pub const ErrorCode = protocol.ErrorCode;
pub const SocketError = protocol.SocketError;
pub const Protocol = protocol.Protocol;
pub const Socket = protocol.Socket;
pub const Ipv4 = protocol.Ipv4;
pub const INVALID_SOCKET = protocol.INVALID_SOCKET;

pub const ConnectRequest = protocol.ConnectRequest;
pub const ConnectResult = protocol.ConnectResult;
pub const SendRequest = protocol.SendRequest;
pub const SendResult = protocol.SendResult;
pub const RecvRequest = protocol.RecvRequest;
pub const RecvResult = protocol.RecvResult;
pub const CloseRequest = protocol.CloseRequest;
pub const DnsRequest = protocol.DnsRequest;
pub const DnsResult = protocol.DnsResult;
pub const PingRequest = protocol.PingRequest;
pub const PingResult = protocol.PingResult;
pub const PingGatewayRequest = protocol.PingGatewayRequest;
pub const TestDnsRequest = protocol.TestDnsRequest;
pub const TestDnsResult = protocol.TestDnsResult;
pub const GetConfigRequest = protocol.GetConfigRequest;
pub const ConfigResult = protocol.ConfigResult;
pub const TestConnectivityRequest = protocol.TestConnectivityRequest;
pub const TestConnectivityResult = protocol.TestConnectivityResult;

pub const makeIpv4 = protocol.makeIpv4;
pub const formatIpv4 = protocol.formatIpv4;

//------------------------------------------------------------------------------
// Timeout Constants
//------------------------------------------------------------------------------

/// Wait forever (no timeout)
pub const TIMEOUT_INFINITE: u32 = 0;

/// Kernel INFINITE sentinel (chan_recv timeout_ns). Distinct from
/// TIMEOUT_INFINITE, which is the u32-ms public API meaning of 0.
const INFINITE: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// Convert milliseconds to nanoseconds, handling infinite case
fn toNanoseconds(timeout_ms: u32) u64 {
    if (timeout_ms == 0) return INFINITE;
    return @as(u64, timeout_ms) * 1_000_000;
}

//------------------------------------------------------------------------------
// State
//------------------------------------------------------------------------------

/// The network stack's packed gen-qualified identity (raw | gen<<16), kept
/// for the fields that still carry a peer id (SHM plane peer_id). The peer
/// BINDING is the wired bundle below -- the endpoint is the authenticator,
/// not this value.
var network_manager_identity: u32 = 0xFFFF;

/// The net.stack bundle (L4). Folded in at spawn for boot consumers;
/// acquired via lamina's dynamic Connect for on-demand callers (session
/// shells).
var stack_ch: ?channel.Channel = null;

//------------------------------------------------------------------------------
// Initialization
//------------------------------------------------------------------------------

/// L1.1 (the_law/adoption_plan.md): `ContractMismatch` means zmoltcp is
/// reachable but its protocol module's CONTRACT_HASH disagrees with ours.
pub const InitError = error{ StackNotFound, ContractMismatch };

/// Network stack contract namespace (the manifest key lamina's Connect
/// resolves).
pub const NAMESPACE: []const u8 = "net.stack";

/// Initialize the network API by discovering the network stack via namespace.
/// Must be called before any network operations.
pub fn init() InitError!void {
    if (stack_ch != null) return;
    _ = channel.reclaimClosed(protocol.CONTRACT_HASH);
    // Boot consumers find their spawn-folded bundle; dynamic callers
    // (session shells) fall through to lamina's Connect, authorized by
    // their manifest's .dynamic requires.
    const ch = channel.requiredChannel(protocol.CONTRACT_HASH) catch blk: {
        const conn = init_client.connect(NAMESPACE, false) catch return InitError.StackNotFound;
        break :blk channel.Channel{ .out = conn.out_tok, .in = conn.in_tok, .pair_id = 0, .peer = conn.provider };
    };
    stack_ch = ch;
    network_manager_identity = ch.peer;
}

/// Point the client at a stack by bare CID (generation-0 wildcard).
/// Test/bring-up path; production goes via `init`.
pub fn setNetworkManager(id: u16) void {
    network_manager_identity = id;
}

pub fn getNetworkManager() u16 {
    return @truncate(network_manager_identity);
}

//------------------------------------------------------------------------------
// Internal Helpers
//------------------------------------------------------------------------------

/// Send a request to the network stack and wait for the matching typed reply
/// on the wired bundle. The endpoint IS the peer binding (channel_contract.md
/// 15.2): a reply in-end is wired 1:1 to the stack, so no sender filtering is
/// needed -- a mistyped message is a protocol interleaving, not an impostor.
fn sendAndRecv(msg: *sys.Message, expected_reply: u16, timeout_ns: u64) SocketError!void {
    const ch = stack_ch orelse return SocketError.IccError;
    const sr = sys.chan_send(ch.out, msg);
    if (sr.x0 != 0) return SocketError.IccError;

    // One outstanding request per bundle; deferred results (CONNECT_RESULT
    // resolved by zmoltcp's pending machinery) land on the same in-end.
    // Mistyped interleavings are drained past (bounded), not fatal.
    const deadline = sys.get_time() +| timeout_ns;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const now = sys.get_time();
        if (timeout_ns != INFINITE and now >= deadline) return SocketError.TimedOut;
        const wait_ns: u64 = if (timeout_ns == INFINITE) INFINITE else deadline -| now;
        const r = sys.chan_recv(ch.in, msg, wait_ns);
        if (r.x0 == 1) {
            stack_ch = null; // stack died; re-acquire via init()
            return SocketError.IccError;
        }
        if (r.x0 != 0) return SocketError.TimedOut;
        if (msg.msg_type == expected_reply) return;
    }
    return SocketError.TimedOut;
}

//------------------------------------------------------------------------------
// SocketStream -- connected socket value
//------------------------------------------------------------------------------

/// Owns a connected socket: the stack-side socket id, the peer cell
/// id (for ICC), and the two per-socket SHM regions (recv + send, post-C8.17
/// split). When both regions are non-null, `read` and `write` use the T1
/// ring fast path; otherwise they fall back to T2 ICC RPC.
pub const SocketStream = struct {
    socket: Socket,
    peer_identity: u32,

    recv_region: ?*volatile socket_shm.RecvShmRegion = null,
    recv_token: u32 = 0, // per-attach token from map_attach; 0 if no SHM

    send_region: ?*volatile socket_shm.SendShmRegion = null,
    send_token: u32 = 0,

    /// Read up to `buf.len` bytes. Returns when >= 1 byte is available or
    /// the deadline elapses. `timeout_ms == 0` means non-blocking.
    pub fn read(self: SocketStream, buf: []u8, timeout_ms: u32) SocketError!usize {
        if (buf.len == 0) return 0;

        if (self.recv_region) |region| {
            const stream = ReadStream.fromRegion(region, self.recv_token);
            if (timeout_ms == 0) {
                const n = stream.readNonBlocking(buf);
                if (n > 0) return n;
                // Data-first EOF ordering, same as the blocking path: only
                // report EndOfStream once the ring is drained. Without this a
                // non-blocking reader (telnetd polls at timeout 0) sees a
                // peer FIN as perpetual WouldBlock and never runs its hangup
                // path -- the session only ends if a later write happens to
                // fail.
                if (region.eof != 0) return SocketError.EndOfStream;
                return SocketError.WouldBlock;
            }
            return stream.read(buf, timeout_ms) catch |err| switch (err) {
                socket_stream.ReadError.WouldBlock => SocketError.WouldBlock,
                socket_stream.ReadError.TimedOut => SocketError.TimedOut,
                socket_stream.ReadError.EndOfStream => SocketError.EndOfStream,
            };
        }

        return self.recvIcc(buf, timeout_ms);
    }

    /// Write up to `buf.len` bytes. Returns when >= 1 byte is queued or the
    /// deadline elapses. `timeout_ms == 0` means non-blocking. Caller loops
    /// for "send all" semantics.
    pub fn write(self: SocketStream, buf: []const u8, timeout_ms: u32) SocketError!usize {
        if (buf.len == 0) return 0;

        if (self.send_region) |region| {
            const stream = WriteStream.from(region, self.send_token, if (stack_ch) |ch| ch.out else 0, self.socket);
            if (timeout_ms == 0) {
                const n = stream.writeNonBlocking(buf);
                return if (n == 0) SocketError.WouldBlock else n;
            }
            return stream.write(buf, timeout_ms) catch |err| switch (err) {
                socket_stream.WriteError.WouldBlock => SocketError.WouldBlock,
                socket_stream.WriteError.TimedOut => SocketError.TimedOut,
                socket_stream.WriteError.Empty => 0,
            };
        }

        return self.sendIcc(buf, timeout_ms);
    }

    /// Close the socket. Detaches both SHM regions (if mapped) and waits for
    /// the stack's CLOSE ACK to keep the ICC mailbox clean.
    pub fn close(self: SocketStream) void {
        if (self.recv_token != 0) _ = sys.map_detach(self.recv_token);
        if (self.send_token != 0) _ = sys.map_detach(self.send_token);

        var msg: sys.Message = undefined;
        msg.msg_type = MsgType.CLOSE;
        msg.flags = 0;
        (CloseRequest{ .socket = self.socket }).serialize(&msg.payload);

        // Channel round trip on the stack bundle; a dead stack just means
        // nothing to close against.
        if (stack_ch) |ch| {
            const sr = sys.chan_send(ch.out, &msg);
            if (sr.x0 == 0) {
                var guard: u8 = 0;
                while (guard < 8) : (guard += 1) {
                    const r = sys.chan_recv(ch.in, &msg, 2_000_000_000);
                    if (r.x0 != 0) break;
                    if (msg.msg_type == MsgType.CLOSE_RESULT) break;
                }
            }
        }
    }

    /// Borrow a T1-only `ReadStream` for callers that need to compose
    /// strictly within T1 (e.g. a streaming parser classified T1). Returns
    /// null if no recv-side SHM is mapped.
    pub fn readStream(self: SocketStream) ?ReadStream {
        const region = self.recv_region orelse return null;
        return ReadStream.fromRegion(region, self.recv_token);
    }

    /// Borrow a T1-only `WriteStream`. Returns null if no send-side SHM is mapped.
    pub fn writeStream(self: SocketStream) ?WriteStream {
        const region = self.send_region orelse return null;
        return WriteStream.from(region, self.send_token, self.peer_identity, self.socket);
    }

    fn recvIcc(self: SocketStream, buf: []u8, timeout_ms: u32) SocketError!usize {
        var msg: sys.Message = undefined;
        msg.msg_type = MsgType.RECV;
        msg.flags = 0;
        (RecvRequest{
            .socket = self.socket,
            .max_len = @intCast(@min(buf.len, protocol.MAX_RECV_DATA)),
            .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
        }).serialize(&msg.payload);

        const ipc_timeout = if (timeout_ms == 0)
            toNanoseconds(0)
        else
            toNanoseconds(timeout_ms) + 1_000_000_000; // +1s overhead

        try sendAndRecv(&msg, MsgType.RECV_RESULT, ipc_timeout);

        const parsed = RecvResult.deserialize(&msg.payload);
        if (parsed.header.error_code != ErrorCode.SUCCESS) {
            return ErrorCode.toError(parsed.header.error_code) orelse SocketError.Unknown;
        }

        const copy_len = @min(parsed.data.len, buf.len);
        if (copy_len > 0) @memcpy(buf[0..copy_len], parsed.data[0..copy_len]);
        return copy_len;
    }

    fn sendIcc(self: SocketStream, data: []const u8, timeout_ms: u32) SocketError!usize {
        var msg: sys.Message = undefined;
        msg.msg_type = MsgType.SEND;
        msg.flags = 0;
        (SendRequest{
            .socket = self.socket,
            .len = @intCast(@min(data.len, protocol.MAX_SEND_DATA)),
        }).serialize(&msg.payload, data);

        try sendAndRecv(&msg, MsgType.SEND_RESULT, toNanoseconds(timeout_ms));

        const result = SendResult.deserialize(&msg.payload);
        if (result.error_code != ErrorCode.SUCCESS) {
            return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
        }
        return result.sent;
    }
};

//------------------------------------------------------------------------------
// Socket Operations
//------------------------------------------------------------------------------

/// Connect to a remote host. Returns a `SocketStream` value that owns the
/// connection. If the stack offers per-socket SHM, this function attaches
/// it before returning so the first `read` / `write` already see the fast
/// path.
pub fn connect(ip: Ipv4, port: u16, proto: Protocol, timeout_ms: u32) SocketError!SocketStream {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.CONNECT;
    msg.flags = 0;
    (ConnectRequest{ .ip = ip, .port = port, .protocol = proto }).serialize(&msg.payload);

    try sendAndRecv(&msg, MsgType.CONNECT_RESULT, toNanoseconds(timeout_ms));

    const result = ConnectResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }

    var stream = SocketStream{
        .socket = result.socket,
        .peer_identity = network_manager_identity,
    };

    // SHM handles travel inside CONNECT_RESULT (no separate offer message,
    // no race). Either handle being 0 means no SHM on that direction (UDP,
    // or stack chose not to offer); read/write fall back to ICC. In practice
    // the stack offers both or neither. attachShm() failure leaves `stream`
    // in ICC-fallback mode unchanged.
    if (result.recv_shm_handle != 0 and result.send_shm_handle != 0) {
        attachShm(&stream, result.recv_shm_handle, result.send_shm_handle) catch {};
    }

    return stream;
}

/// How often Listener.accept re-polls the stack while waiting.
const ACCEPT_POLL_MS: u32 = 20;

pub const AcceptedConnection = struct {
    stream: SocketStream,
    remote_ip: Ipv4,
    remote_port: u16,
};

/// A listener group on one local TCP port. Value type -- the state lives
/// in the stack; this is just the port key.
pub const Listener = struct {
    port: u16,

    /// Accept one inbound connection. `timeout_ms == 0` is a single
    /// non-blocking probe; otherwise polls the stack until the wall-clock
    /// budget is spent (SocketError.WouldBlock). The stack replies to every
    /// ACCEPT immediately, so the inner recv is bounded well under the poll
    /// interval -- the budget is honored to ~ACCEPT_POLL_MS granularity
    /// rather than being blown by a fixed per-poll block.
    pub fn accept(self: Listener, timeout_ms: u32) SocketError!AcceptedConnection {
        const start_ns = sys.get_time();
        const budget_ns: u64 = @as(u64, timeout_ms) * 1_000_000;
        while (true) {
            // Drain stale notifications (e.g. a prior socket's write-ready
            // pokes) so a long-lived listener cannot fill its 16-slot
            // mailbox across many sessions and starve future replies.
            drainStaleMessages();

            var msg: sys.Message = undefined;
            msg.msg_type = MsgType.ACCEPT;
            msg.flags = 0;
            (protocol.AcceptRequest{ .port = self.port }).serialize(&msg.payload);

            try sendAndRecv(&msg, MsgType.ACCEPT_RESULT, ACCEPT_POLL_MS * 1_000_000);

            const result = protocol.AcceptResult.deserialize(&msg.payload);
            if (result.error_code == ErrorCode.SUCCESS) {
                var stream = SocketStream{
                    .socket = result.socket,
                    .peer_identity = network_manager_identity,
                };
                if (result.recv_shm_handle != 0 and result.send_shm_handle != 0) {
                    attachShm(&stream, result.recv_shm_handle, result.send_shm_handle) catch {};
                }
                return .{
                    .stream = stream,
                    .remote_ip = result.remote_ip,
                    .remote_port = result.remote_port,
                };
            }
            if (result.error_code != ErrorCode.WOULD_BLOCK) {
                return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
            }
            if (sys.get_time() - start_ns >= budget_ns) return SocketError.WouldBlock;
            _ = sys.wait_event(0, 0, @as(u64, ACCEPT_POLL_MS) * 1_000_000);
        }
    }
};

/// Non-blocking flush of any stale queued replies on the stack bundle.
/// Used by the accept poll so late results from a prior op cannot be
/// mistaken for the next reply.
fn drainStaleMessages() void {
    const ch = stack_ch orelse return;
    var msg: sys.Message = undefined;
    var guard: u8 = 0;
    while (guard < 16) : (guard += 1) {
        const r = sys.chan_recv(ch.in, &msg, 0);
        if (r.x0 != 0) return;
    }
}

/// Open a listener group on `port`. Idempotent for the same owner; another
/// cell holding the port yields AddressInUse. `backlog` is clamped by the
/// stack (small -- listeners share the 8-socket TCP pool).
pub fn listen(port: u16, backlog: u16) SocketError!Listener {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.LISTEN;
    msg.flags = 0;
    (protocol.ListenRequest{ .port = port, .backlog = backlog }).serialize(&msg.payload);

    try sendAndRecv(&msg, MsgType.LISTEN_RESULT, toNanoseconds(2000));

    const result = protocol.ListenResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return .{ .port = port };
}

const AttachShmError = error{ MapAttachFailed, ValidateFailed };

fn attachShm(stream: *SocketStream, recv_handle: u64, send_handle: u64) AttachShmError!void {
    const ch = stack_ch orelse return AttachShmError.MapAttachFailed;
    const recv_ref: u32 = @truncate(recv_handle);
    const send_ref: u32 = @truncate(send_handle);
    if (recv_ref == 0 or send_ref == 0) return AttachShmError.MapAttachFailed;

    const recv_result = sys.map_attach(ch.in, recv_ref, 1);
    if (errors.isError(recv_result)) return AttachShmError.MapAttachFailed;
    const recv_token = sys.MapResult.token(recv_result);
    errdefer _ = sys.map_detach(recv_token);

    const recv_region: *volatile socket_shm.RecvShmRegion = @ptrFromInt(sys.MapResult.va(recv_result));
    if (!recv_region.validate()) return AttachShmError.ValidateFailed;

    const send_result = sys.map_attach(ch.in, send_ref, 1);
    if (errors.isError(send_result)) return AttachShmError.MapAttachFailed;
    const send_token = sys.MapResult.token(send_result);
    errdefer _ = sys.map_detach(send_token);

    const send_region: *volatile socket_shm.SendShmRegion = @ptrFromInt(sys.MapResult.va(send_result));
    if (!send_region.validate()) return AttachShmError.ValidateFailed;

    stream.recv_region = recv_region;
    stream.recv_token = recv_token;
    stream.send_region = send_region;
    stream.send_token = send_token;

    // Acknowledge so the stack flips its slot to "active" and starts draining.
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.SOCKET_SHM_ACCEPT;
    msg.flags = 0;
    @memset(&msg.payload, 0);
    msg.payload[0] = @truncate(stream.socket);
    msg.payload[1] = @truncate(stream.socket >> 8);
    _ = sys.chan_send(ch.out, &msg);
}

//------------------------------------------------------------------------------
// DNS Operations
//------------------------------------------------------------------------------

/// Resolve a hostname to an IP address.
pub fn resolve(hostname: []const u8, timeout_ms: u32) SocketError!Ipv4 {
    if (hostname.len == 0 or hostname.len > protocol.MAX_HOSTNAME_LEN) {
        return SocketError.InvalidArgument;
    }

    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.DNS_RESOLVE;
    msg.flags = 0;
    (DnsRequest{ .hostname_len = @intCast(hostname.len) }).serialize(&msg.payload, hostname);

    try sendAndRecv(&msg, MsgType.DNS_RESULT, toNanoseconds(timeout_ms));

    const result = DnsResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) return SocketError.DnsError;
    return result.addr;
}

//------------------------------------------------------------------------------
// Ping Operations
//------------------------------------------------------------------------------

pub const PingResponse = struct {
    rtt_us: u32,
    ttl: u8,
};

/// Ping a specific IP address.
pub fn ping(ip: Ipv4, seq: u16, timeout_ms: u32) SocketError!PingResponse {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.PING;
    msg.flags = 0;
    (PingRequest{
        .ip = ip,
        .seq = seq,
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    }).serialize(&msg.payload);

    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000;

    try sendAndRecv(&msg, MsgType.PING_RESULT, ipc_timeout);

    const result = PingResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return .{ .rtt_us = result.rtt_us, .ttl = result.ttl };
}

//------------------------------------------------------------------------------
// Abstract Operations - Stack handles network topology
//------------------------------------------------------------------------------

/// Ping the network stack's configured default gateway.
pub fn pingGateway(seq: u16, timeout_ms: u32) SocketError!PingResponse {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.PING_GATEWAY;
    msg.flags = 0;
    (PingGatewayRequest{
        .seq = seq,
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    }).serialize(&msg.payload);

    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000;

    try sendAndRecv(&msg, MsgType.PING_GATEWAY_RESULT, ipc_timeout);

    const result = PingResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return .{ .rtt_us = result.rtt_us, .ttl = result.ttl };
}

/// Test DNS server connectivity.
pub fn testDns(timeout_ms: u32) SocketError!TestDnsResult {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.TEST_DNS;
    msg.flags = 0;
    (TestDnsRequest{
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    }).serialize(&msg.payload);

    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000;

    try sendAndRecv(&msg, MsgType.TEST_DNS_RESULT, ipc_timeout);

    const result = TestDnsResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result;
}

/// Query the network stack's configuration.
pub fn getConfig(timeout_ms: u32) SocketError!ConfigResult {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.GET_CONFIG;
    msg.flags = 0;
    (GetConfigRequest{}).serialize(&msg.payload);

    try sendAndRecv(&msg, MsgType.CONFIG_RESULT, toNanoseconds(timeout_ms));

    const result = ConfigResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result;
}

/// Test overall network connectivity.
pub fn testConnectivity(timeout_ms: u32) SocketError!TestConnectivityResult {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.TEST_CONNECTIVITY;
    msg.flags = 0;
    (TestConnectivityRequest{
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    }).serialize(&msg.payload);

    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000;

    try sendAndRecv(&msg, MsgType.TEST_CONNECTIVITY_RESULT, ipc_timeout);

    const result = TestConnectivityResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result;
}
