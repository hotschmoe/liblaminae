//------------------------------------------------------------------------------
// Network Stack Protocol Specification
//
// This defines the contract between:
//   - Network Stack Cells (zmoltcp, or any replacement)
//   - Application Cells (net_test, shell, browsers, etc.)
//
// IMPLEMENTERS: If you're building a network stack, implement all REQUIRED
// message handlers. OPTIONAL handlers should return ErrorCode.NOT_SUPPORTED.
//
// CONSUMERS: Use liblaminae.net_api for ergonomic wrappers, or send raw
// ICC messages using these types directly.
//
// DESIGN PRINCIPLE: Abstract commands (PING_GATEWAY, TEST_DNS) let consumers
// express intent without knowing network topology. The stack owns all config.
//
// Import-free by design (the_law/HARDLINE.md section 5), amended by L1.1
// (the_law/adoption_plan.md) to allow exactly one leaf import beyond `std`:
// `src/shared/icc/contract.zig`, itself import-free. It supplies the
// CONTRACT_HASH computation near the bottom of this file (the "Contract
// hash" section wraps the existing Request/Result struct pairs in
// Method-spec-shaped types purely for the hash walk -- the wire encoding
// and the `net_client`/zmoltcp call sites are unchanged). BH4 (2026-07-16)
// converted those Request/Result structs to `extern` so their layout IS
// the wire layout; the two replies with compact-unaligned integers declare
// a separate `WireReply` extern struct hashed in their place.
//------------------------------------------------------------------------------

const std = @import("std");
const contract = @import("contract");

/// Channel-message payload size. Mirrors `src/shared/icc/schema.zig` PAYLOAD_SIZE --
/// this module is import-free by design; lib/root.zig asserts the mirror.
pub const PAYLOAD_SIZE = 248;

/// Protocol version - bump on breaking changes
pub const PROTOCOL_VERSION: u16 = 1;

/// Namespace name registered by the network stack at boot (`lib/net_client/
/// api.zig`'s `NAMESPACE`; duplicated here as the CONTRACT_HASH descriptor
/// input since this module predates the client/protocol split).
pub const NAMESPACE: []const u8 = "net.stack";

//------------------------------------------------------------------------------
// Serialization Helpers
//------------------------------------------------------------------------------

fn writeU16(payload: []u8, offset: usize, value: u16) void {
    payload[offset] = @truncate(value);
    payload[offset + 1] = @truncate(value >> 8);
}

fn writeU32(payload: []u8, offset: usize, value: u32) void {
    payload[offset] = @truncate(value);
    payload[offset + 1] = @truncate(value >> 8);
    payload[offset + 2] = @truncate(value >> 16);
    payload[offset + 3] = @truncate(value >> 24);
}

fn readU16(payload: []const u8, offset: usize) u16 {
    return @as(u16, payload[offset]) | (@as(u16, payload[offset + 1]) << 8);
}

fn readU32(payload: []const u8, offset: usize) u32 {
    return @as(u32, payload[offset]) |
        (@as(u32, payload[offset + 1]) << 8) |
        (@as(u32, payload[offset + 2]) << 16) |
        (@as(u32, payload[offset + 3]) << 24);
}

fn writeU64(payload: []u8, offset: usize, value: u64) void {
    inline for (0..8) |i| {
        payload[offset + i] = @truncate(value >> @as(u6, @truncate(i * 8)));
    }
}

fn readU64(payload: []const u8, offset: usize) u64 {
    var result: u64 = 0;
    inline for (0..8) |i| {
        result |= @as(u64, payload[offset + i]) << @as(u6, @truncate(i * 8));
    }
    return result;
}

//------------------------------------------------------------------------------
// Message Types (app <-> network stack)
//
// Ranges:
//   0x2000-0x203F: Socket operations (existing)
//   0x2040-0x205F: Abstract network operations (new)
//------------------------------------------------------------------------------

pub const MsgType = struct {
    // === Socket Operations (REQUIRED) ===

    /// TCP/UDP connect request
    /// Direction: app -> stack
    /// Payload: ConnectRequest
    /// Response: CONNECT_RESULT
    pub const CONNECT: u16 = 0x2000;

    /// Connect response
    /// Direction: stack -> app
    /// Payload: ConnectResult
    pub const CONNECT_RESULT: u16 = 0x2001;

    /// Send data on socket
    /// Direction: app -> stack
    /// Payload: SendRequest (header) + data bytes
    /// Response: SEND_RESULT
    pub const SEND: u16 = 0x2002;

    /// Send completion
    /// Direction: stack -> app
    /// Payload: SendResult
    pub const SEND_RESULT: u16 = 0x2003;

    /// Receive data from socket
    /// Direction: app -> stack
    /// Payload: RecvRequest
    /// Response: RECV_RESULT
    pub const RECV: u16 = 0x2004;

    /// Receive response with data
    /// Direction: stack -> app
    /// Payload: RecvResult (header) + data bytes
    pub const RECV_RESULT: u16 = 0x2005;

    /// Close socket
    /// Direction: app -> stack
    /// Payload: CloseRequest
    /// Response: CLOSE_RESULT
    pub const CLOSE: u16 = 0x2006;

    /// Close response
    /// Direction: stack -> app
    /// Payload: GenericResult
    pub const CLOSE_RESULT: u16 = 0x2007;

    /// Bind socket to local port
    /// Direction: app -> stack
    /// Payload: BindRequest
    /// Response: BIND_RESULT
    pub const BIND: u16 = 0x2008;

    /// Bind response
    /// Direction: stack -> app
    /// Payload: GenericResult
    pub const BIND_RESULT: u16 = 0x2009;

    /// Listen on socket
    /// Direction: app -> stack
    /// Payload: ListenRequest
    /// Response: LISTEN_RESULT
    pub const LISTEN: u16 = 0x200A;

    /// Listen response
    /// Direction: stack -> app
    /// Payload: ListenResult
    pub const LISTEN_RESULT: u16 = 0x200B;

    /// Accept connection
    /// Direction: app -> stack
    /// Payload: AcceptRequest
    /// Response: ACCEPT_RESULT
    pub const ACCEPT: u16 = 0x200C;

    /// Accept response with new socket
    /// Direction: stack -> app
    /// Payload: AcceptResult
    pub const ACCEPT_RESULT: u16 = 0x200D;

    /// Resolve hostname to IP
    /// Direction: app -> stack
    /// Payload: DnsRequest (header) + hostname bytes
    /// Response: DNS_RESULT
    pub const DNS_RESOLVE: u16 = 0x2010;

    /// DNS resolution result
    /// Direction: stack -> app
    /// Payload: DnsResult
    pub const DNS_RESULT: u16 = 0x2011;

    /// Query socket status
    /// Direction: app -> stack
    /// Payload: StatusRequest
    /// Response: STATUS_RESULT
    pub const GET_STATUS: u16 = 0x2020;

    /// Socket status response
    /// Direction: stack -> app
    /// Payload: StatusResult
    pub const STATUS_RESULT: u16 = 0x2021;

    /// ICMP ping to specific IP
    /// Direction: app -> stack
    /// Payload: PingRequest
    /// Response: PING_RESULT
    pub const PING: u16 = 0x2030;

    /// Ping result
    /// Direction: stack -> app
    /// Payload: PingResult
    pub const PING_RESULT: u16 = 0x2031;

    // === Abstract Network Operations (REQUIRED for v1) ===
    //
    // These commands let consumers express intent without knowing topology.
    // The stack uses its internal configuration to execute.

    /// Ping the stack's configured default gateway
    /// Direction: app -> stack
    /// Payload: PingGatewayRequest
    /// Response: PING_GATEWAY_RESULT
    /// Behavior: Stack MUST ping its configured gateway IP
    ///           If no gateway configured, return NOT_CONFIGURED
    pub const PING_GATEWAY: u16 = 0x2040;

    /// Gateway ping result
    /// Direction: stack -> app
    /// Payload: PingResult (same as PING_RESULT)
    pub const PING_GATEWAY_RESULT: u16 = 0x2041;

    /// Test DNS server connectivity
    /// Direction: app -> stack
    /// Payload: TestDnsRequest
    /// Response: TEST_DNS_RESULT
    /// Behavior: Stack MUST send a test query to its configured DNS server
    ///           Success = server responded (regardless of query result)
    ///           If no DNS configured, return NOT_CONFIGURED
    pub const TEST_DNS: u16 = 0x2042;

    /// DNS test result
    /// Direction: stack -> app
    /// Payload: TestDnsResult
    pub const TEST_DNS_RESULT: u16 = 0x2043;

    /// Query network stack configuration
    /// Direction: app -> stack
    /// Payload: GetConfigRequest
    /// Response: CONFIG_RESULT
    /// Behavior: Stack MUST return its current IP, gateway, DNS config
    ///           This is the escape hatch for apps that genuinely need raw IPs
    pub const GET_CONFIG: u16 = 0x2044;

    /// Network configuration response
    /// Direction: stack -> app
    /// Payload: ConfigResult
    pub const CONFIG_RESULT: u16 = 0x2045;

    /// Test general network connectivity
    /// Direction: app -> stack
    /// Payload: TestConnectivityRequest
    /// Response: TEST_CONNECTIVITY_RESULT
    /// Behavior: Stack performs basic connectivity check (implementation-defined)
    ///           Typically: gateway reachable AND link is up
    pub const TEST_CONNECTIVITY: u16 = 0x2046;

    /// Connectivity test result
    /// Direction: stack -> app
    /// Payload: TestConnectivityResult
    pub const TEST_CONNECTIVITY_RESULT: u16 = 0x2047;

    // === Socket SHM Data Plane (0x2060-0x206F) ===
    //
    // Note: there used to be a SOCKET_SHM_OFFER (0x2060) message sent
    // separately after CONNECT_RESULT. It had an inherent race -- the
    // client had to poll for it within a narrow window after CONNECT_
    // RESULT, and missed offers leaked SHM regions while poisoning the
    // mailbox. The handle now travels in CONNECT_RESULT.shm_handle
    // directly. 0x2060 is reserved for backwards-incompat detection.

    /// SHM accept (app attached to region)
    /// Direction: app -> stack
    /// Payload: [0:1]=socket_id
    pub const SOCKET_SHM_ACCEPT: u16 = 0x2061;

    // 0x2062 RETIRED -- was SOCKET_DATA_READY (stack -> app, "data in recv_ring").
    // M2c migrated the recv-direction wake to ring-event (sys_ring_wake) on the
    // app's per-attach token. The id is intentionally not reused.

    /// SHM channel teardown
    /// Direction: either side
    /// Payload: [0:1]=socket_id
    pub const SOCKET_SHM_DETACH: u16 = 0x2063;

    /// Data queued in SHM send ring -- stack should drain into TCP TX.
    /// Direction: app -> stack (fire-and-forget eager-drain wake).
    /// Payload: [0:1]=socket_id, [2:5]=bytes_available (u32).
    /// Post-C8.17 the alternative (stack arming the send region's
    /// consumer_waiter every iter) loses the very first wake before the
    /// stack's mainLoop reaches the arm site, costing a poll-timeout (50ms)
    /// on the request's hot path. The mailbox notification remains as the
    /// proven eager-drain path; M2d will revisit ring-event symmetry once
    /// the stack mainLoop supports multi-ring arm timing without that race.
    pub const SOCKET_SEND_READY: u16 = 0x2064;

    /// Send ring drained -- write space available.
    /// Direction: stack -> app (wake from backpressure wait).
    /// Payload: [0:1]=socket_id, [2:5]=bytes_free (u32).
    /// C8.17 split SocketShmRegion so the app's WriteStream can also park
    /// on the send region's producer_waiter (direction=1, sys_ring_arm) for
    /// pure ring-event backpressure -- the mailbox path is the lower-
    /// latency fallback when the producer hasn't parked yet.
    pub const SOCKET_WRITE_READY: u16 = 0x2065;
};

//------------------------------------------------------------------------------
// Mailbox disposition (C8.18 Option C)
//
// `SocketWakeMsg` is a typed enum of the socket-range message ids that may
// appear at head-of-mailbox in a `ReadStream` / `WriteStream` loop after
// `sys_wait_event` returns `.icc`. The `dispositionOf` switch is exhaustive
// over this enum: adding a new wake-class socket message requires extending
// `SocketWakeMsg` AND adding an explicit `MailboxDisposition` arm, or the
// build fails.
//
// This closes the C8.18 class-of-bug ("`drainOwnWake` swallows by default,
// silently consuming any future message a contributor forgot to classify").
// Unknown msg_types are still swallowed at the call site (`drainOwnWake`)
// for defensive reasons (stale ICC traffic from torn-down sockets), but the
// branch is now explicit and commented rather than emergent.
//------------------------------------------------------------------------------

/// Disposition for messages that may sit at head-of-mailbox during a
/// `ReadStream` / `WriteStream` wait loop.
pub const MailboxDisposition = enum {
    /// Consumer must process. Leave at head-of-mailbox.
    deliver,
    /// Idempotent wake signal. Caller may swallow when addressed to it;
    /// must leave queued when addressed to a peer (see `drainOwnWake`).
    wake_only,
};

/// Wake-class socket messages that `drainOwnWake` must classify. Adding a
/// new variant forces a disposition arm in `dispositionOf`. The wire value
/// matches `MsgType.*`.
pub const SocketWakeMsg = enum(u16) {
    send_ready = MsgType.SOCKET_SEND_READY,
    write_ready = MsgType.SOCKET_WRITE_READY,
};

/// Compile-time-exhaustive disposition table. New `SocketWakeMsg` variants
/// must add an arm here -- the absence of an `else` makes this a build error.
pub fn dispositionOf(msg: SocketWakeMsg) MailboxDisposition {
    return switch (msg) {
        .send_ready, .write_ready => .wake_only,
    };
}

/// Decode a wire u16 into the typed wake enum. Returns null for msg_types
/// not in the wake set; callers treat null as "outside our classification"
/// (the current behavior: defensively swallow at `drainOwnWake`).
/// Extending `SocketWakeMsg` extends this decoder automatically.
pub fn socketWakeMsgFromU16(v: u16) ?SocketWakeMsg {
    inline for (std.meta.tags(SocketWakeMsg)) |t| {
        if (@intFromEnum(t) == v) return t;
    }
    return null;
}

//------------------------------------------------------------------------------
// Error Codes
//
// Shared across all operations. Stack implementations MUST use these codes.
//------------------------------------------------------------------------------

pub const ErrorCode = struct {
    pub const SUCCESS: u16 = 0;
    pub const CONNECTION_REFUSED: u16 = 1;
    pub const TIMED_OUT: u16 = 2;
    pub const NOT_CONNECTED: u16 = 3;
    pub const BAD_SOCKET: u16 = 4;
    pub const ADDRESS_IN_USE: u16 = 5;
    pub const WOULD_BLOCK: u16 = 6;
    pub const CONNECTION_RESET: u16 = 7;
    pub const NETWORK_UNREACHABLE: u16 = 8;
    pub const HOST_UNREACHABLE: u16 = 9;
    pub const OUT_OF_MEMORY: u16 = 10;
    pub const INVALID_ARGUMENT: u16 = 11;
    pub const DNS_ERROR: u16 = 12;
    pub const NOT_SUPPORTED: u16 = 13;
    pub const NOT_CONFIGURED: u16 = 14;
    pub const LINK_DOWN: u16 = 15;

    pub fn toError(code: u16) ?SocketError {
        return switch (code) {
            SUCCESS => null,
            CONNECTION_REFUSED => SocketError.ConnectionRefused,
            TIMED_OUT => SocketError.TimedOut,
            NOT_CONNECTED => SocketError.NotConnected,
            BAD_SOCKET => SocketError.InvalidSocket,
            ADDRESS_IN_USE => SocketError.AddressInUse,
            WOULD_BLOCK => SocketError.WouldBlock,
            CONNECTION_RESET => SocketError.ConnectionReset,
            NETWORK_UNREACHABLE => SocketError.NetworkUnreachable,
            HOST_UNREACHABLE => SocketError.HostUnreachable,
            OUT_OF_MEMORY => SocketError.OutOfMemory,
            INVALID_ARGUMENT => SocketError.InvalidArgument,
            DNS_ERROR => SocketError.DnsError,
            NOT_SUPPORTED => SocketError.NotSupported,
            NOT_CONFIGURED => SocketError.NotConfigured,
            LINK_DOWN => SocketError.LinkDown,
            else => SocketError.Unknown,
        };
    }
};

//------------------------------------------------------------------------------
// Socket Error Type (for Zig error handling)
//------------------------------------------------------------------------------

pub const SocketError = error{
    ConnectionRefused,
    TimedOut,
    NotConnected,
    InvalidSocket,
    AddressInUse,
    WouldBlock,
    ConnectionReset,
    NetworkUnreachable,
    HostUnreachable,
    OutOfMemory,
    InvalidArgument,
    DnsError,
    NotSupported,
    NotConfigured,
    LinkDown,
    IccError,
    /// Peer half-closed: TCP FIN received. recv_ring has been fully
    /// drained; further reads keep returning `EndOfStream`. Caller
    /// should close the socket.
    EndOfStream,
    Unknown,
};

//------------------------------------------------------------------------------
// Protocol Constants
//------------------------------------------------------------------------------

pub const Protocol = enum(u8) {
    tcp = 6,
    udp = 17,
};

pub const INVALID_SOCKET: u16 = 0xFFFF;

/// Maximum data bytes in a single SEND message (payload minus 4-byte header)
pub const MAX_SEND_DATA: usize = PAYLOAD_SIZE - 4;

/// Maximum data bytes in a single RECV response (payload minus 8-byte header)
pub const MAX_RECV_DATA: usize = PAYLOAD_SIZE - 8;

/// Maximum hostname length for DNS resolution
pub const MAX_HOSTNAME_LEN: usize = 240;

//------------------------------------------------------------------------------
// Payload Structures
//
// Pure Zig structs - C cells handle ABI translation internally.
// All multi-byte integers are native endian unless noted.
// IPv4 addresses are network byte order (big-endian).
//------------------------------------------------------------------------------

/// Socket handle type
pub const Socket = u16;

/// IPv4 address (network byte order)
pub const Ipv4 = u32;

// --- Socket Operations ---

pub const ConnectRequest = extern struct {
    ip: Ipv4,
    port: u16,
    protocol: Protocol,

    pub fn serialize(self: ConnectRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU32(payload, 0, self.ip);
        writeU16(payload, 4, self.port);
        payload[6] = @intFromEnum(self.protocol);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) ConnectRequest {
        return .{
            .ip = readU32(payload, 0),
            .port = readU16(payload, 4),
            .protocol = @enumFromInt(payload[6]),
        };
    }
};

pub const ConnectResult = struct {
    socket: Socket,
    error_code: u16,
    /// Kernel handles for the per-socket SHM regions the stack allocated for
    /// this connection. C8.17 split the bundled SocketShmRegion into two
    /// single-ring regions so each gets its own SPSC waiter pair.
    /// Either handle being 0 means no SHM on that direction (UDP, or the
    /// stack chose not to offer); the client falls back to ICC RECV/SEND.
    /// In practice both are 0 or both are non-zero.
    recv_shm_handle: u64,
    send_shm_handle: u64,

    pub fn serialize(self: ConnectResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.error_code);
        writeU64(payload, 4, self.recv_shm_handle);
        writeU64(payload, 12, self.send_shm_handle);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) ConnectResult {
        return .{
            .socket = readU16(payload, 0),
            .error_code = readU16(payload, 2),
            .recv_shm_handle = readU64(payload, 4),
            .send_shm_handle = readU64(payload, 12),
        };
    }
};

/// LISTEN: open `backlog` passive sockets on `port` (any local address).
/// zmoltcp has no separate accept-socket -- each listener transitions in
/// place to established; ACCEPT harvests established ones and the stack
/// re-arms a fresh listener to keep the backlog depth.
pub const ListenRequest = extern struct {
    port: u16,
    backlog: u16,

    pub fn serialize(self: ListenRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.port);
        writeU16(payload, 2, self.backlog);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) ListenRequest {
        return .{
            .port = readU16(payload, 0),
            .backlog = readU16(payload, 2),
        };
    }
};

pub const ListenResult = extern struct {
    port: u16,
    error_code: u16,

    pub fn serialize(self: ListenResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.port);
        writeU16(payload, 2, self.error_code);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) ListenResult {
        return .{
            .port = readU16(payload, 0),
            .error_code = readU16(payload, 2),
        };
    }
};

/// ACCEPT: harvest one established connection from the caller's listener
/// group on `port`. Result WOULD_BLOCK when none is ready -- callers poll.
pub const AcceptRequest = extern struct {
    port: u16,

    pub fn serialize(self: AcceptRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.port);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) AcceptRequest {
        return .{ .port = readU16(payload, 0) };
    }
};

/// ACCEPT_RESULT: mirrors ConnectResult (same per-socket SHM handle
/// contract, same client attach + SOCKET_SHM_ACCEPT dance) plus the remote
/// endpoint identity.
pub const AcceptResult = struct {
    socket: Socket,
    error_code: u16,
    remote_ip: Ipv4,
    remote_port: u16,
    recv_shm_handle: u64,
    send_shm_handle: u64,

    pub fn serialize(self: AcceptResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.error_code);
        writeU32(payload, 4, self.remote_ip);
        writeU16(payload, 8, self.remote_port);
        writeU64(payload, 10, self.recv_shm_handle);
        writeU64(payload, 18, self.send_shm_handle);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) AcceptResult {
        return .{
            .socket = readU16(payload, 0),
            .error_code = readU16(payload, 2),
            .remote_ip = readU32(payload, 4),
            .remote_port = readU16(payload, 8),
            .recv_shm_handle = readU64(payload, 10),
            .send_shm_handle = readU64(payload, 18),
        };
    }
};

pub const SendRequest = extern struct {
    socket: Socket,
    len: u16,

    pub fn serialize(self: SendRequest, payload: *[PAYLOAD_SIZE]u8, data: []const u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        const actual_len: u16 = @intCast(@min(data.len, MAX_SEND_DATA));
        writeU16(payload, 2, actual_len);
        if (actual_len > 0) {
            @memcpy(payload[4 .. 4 + actual_len], data[0..actual_len]);
        }
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) struct { header: SendRequest, data: []const u8 } {
        const socket = readU16(payload, 0);
        const len = readU16(payload, 2);
        const actual_len = @min(len, MAX_SEND_DATA);
        return .{
            .header = .{ .socket = socket, .len = len },
            .data = payload[4 .. 4 + actual_len],
        };
    }
};

pub const SendResult = extern struct {
    socket: Socket,
    sent: u16,
    error_code: u16,

    pub fn serialize(self: SendResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.sent);
        writeU16(payload, 4, self.error_code);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) SendResult {
        return .{
            .socket = readU16(payload, 0),
            .sent = readU16(payload, 2),
            .error_code = readU16(payload, 4),
        };
    }
};

pub const RecvRequest = extern struct {
    socket: Socket,
    max_len: u16,
    timeout_ms: u16,

    pub fn serialize(self: RecvRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.max_len);
        writeU16(payload, 4, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) RecvRequest {
        return .{
            .socket = readU16(payload, 0),
            .max_len = readU16(payload, 2),
            .timeout_ms = readU16(payload, 4),
        };
    }
};

pub const RecvResult = extern struct {
    socket: Socket,
    len: u16,
    error_code: u16,

    pub fn serialize(self: RecvResult, payload: *[PAYLOAD_SIZE]u8, data: []const u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.len);
        writeU16(payload, 4, self.error_code);
        const actual_len = @min(data.len, MAX_RECV_DATA);
        if (actual_len > 0) {
            @memcpy(payload[8 .. 8 + actual_len], data[0..actual_len]);
        }
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) struct { header: RecvResult, data: []const u8 } {
        const socket = readU16(payload, 0);
        const len = readU16(payload, 2);
        const error_code = readU16(payload, 4);
        const actual_len = @min(len, MAX_RECV_DATA);
        return .{
            .header = .{ .socket = socket, .len = len, .error_code = error_code },
            .data = payload[8 .. 8 + actual_len],
        };
    }
};

pub const CloseRequest = extern struct {
    socket: Socket,

    pub fn serialize(self: CloseRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) CloseRequest {
        return .{ .socket = readU16(payload, 0) };
    }
};

// --- DNS Operations ---

pub const DnsRequest = extern struct {
    hostname_len: u16,

    pub fn serialize(self: DnsRequest, payload: *[PAYLOAD_SIZE]u8, hostname: []const u8) void {
        @memset(payload, 0);
        const actual_len: u16 = @intCast(@min(hostname.len, MAX_HOSTNAME_LEN));
        writeU16(payload, 0, actual_len);
        if (actual_len > 0) {
            @memcpy(payload[4 .. 4 + actual_len], hostname[0..actual_len]);
        }
        _ = self;
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) struct { len: u16, hostname: []const u8 } {
        const len = readU16(payload, 0);
        const actual_len = @min(len, MAX_HOSTNAME_LEN);
        return .{
            .len = len,
            .hostname = payload[4 .. 4 + actual_len],
        };
    }
};

pub const DnsResult = extern struct {
    error_code: u16,
    addr_count: u16,
    addr: Ipv4,

    pub fn serialize(self: DnsResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU16(payload, 2, self.addr_count);
        writeU32(payload, 4, self.addr);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) DnsResult {
        return .{
            .error_code = readU16(payload, 0),
            .addr_count = readU16(payload, 2),
            .addr = readU32(payload, 4),
        };
    }
};

// --- Ping Operations ---

pub const PingRequest = extern struct {
    ip: Ipv4,
    seq: u16,
    timeout_ms: u16,

    pub fn serialize(self: PingRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU32(payload, 0, self.ip);
        writeU16(payload, 4, self.seq);
        writeU16(payload, 6, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) PingRequest {
        return .{
            .ip = readU32(payload, 0),
            .seq = readU16(payload, 4),
            .timeout_ms = readU16(payload, 6),
        };
    }
};

pub const PingResult = extern struct {
    error_code: u16,
    seq: u16,
    rtt_us: u32,
    ttl: u8,

    pub fn serialize(self: PingResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU16(payload, 2, self.seq);
        writeU32(payload, 4, self.rtt_us);
        payload[8] = self.ttl;
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) PingResult {
        return .{
            .error_code = readU16(payload, 0),
            .seq = readU16(payload, 2),
            .rtt_us = readU32(payload, 4),
            .ttl = payload[8],
        };
    }
};

// --- Abstract Operations (New in Protocol v1) ---

/// Request to ping the stack's configured gateway
/// Behavior: Stack pings its own gateway IP, returns same result as PING
pub const PingGatewayRequest = extern struct {
    seq: u16,
    timeout_ms: u16,

    pub fn serialize(self: PingGatewayRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.seq);
        writeU16(payload, 2, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) PingGatewayRequest {
        return .{
            .seq = readU16(payload, 0),
            .timeout_ms = readU16(payload, 2),
        };
    }
};

/// Request to test DNS server connectivity
/// Behavior: Stack sends test query to its DNS server
pub const TestDnsRequest = extern struct {
    timeout_ms: u16,

    pub fn serialize(self: TestDnsRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) TestDnsRequest {
        return .{ .timeout_ms = readU16(payload, 0) };
    }
};

/// DNS test result
pub const TestDnsResult = struct {
    error_code: u16,
    dns_server: Ipv4,
    rtt_us: u32,

    pub fn serialize(self: TestDnsResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU32(payload, 2, self.dns_server);
        writeU32(payload, 6, self.rtt_us);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) TestDnsResult {
        return .{
            .error_code = readU16(payload, 0),
            .dns_server = readU32(payload, 2),
            .rtt_us = readU32(payload, 6),
        };
    }
};

/// Request for network configuration (escape hatch)
pub const GetConfigRequest = extern struct {
    pub fn serialize(_: GetConfigRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
    }

    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) GetConfigRequest {
        return .{};
    }
};

/// Network configuration response
pub const ConfigResult = extern struct {
    error_code: u16,
    ip: Ipv4,
    subnet_mask: Ipv4,
    gateway: Ipv4,
    dns_primary: Ipv4,
    dns_secondary: Ipv4,
    link_up: bool,

    pub fn serialize(self: ConfigResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU32(payload, 4, self.ip);
        writeU32(payload, 8, self.subnet_mask);
        writeU32(payload, 12, self.gateway);
        writeU32(payload, 16, self.dns_primary);
        writeU32(payload, 20, self.dns_secondary);
        payload[24] = if (self.link_up) 1 else 0;
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) ConfigResult {
        return .{
            .error_code = readU16(payload, 0),
            .ip = readU32(payload, 4),
            .subnet_mask = readU32(payload, 8),
            .gateway = readU32(payload, 12),
            .dns_primary = readU32(payload, 16),
            .dns_secondary = readU32(payload, 20),
            .link_up = payload[24] != 0,
        };
    }
};

/// Request for general connectivity test
pub const TestConnectivityRequest = extern struct {
    timeout_ms: u16,

    pub fn serialize(self: TestConnectivityRequest, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) TestConnectivityRequest {
        return .{ .timeout_ms = readU16(payload, 0) };
    }
};

/// Connectivity test result
pub const TestConnectivityResult = extern struct {
    error_code: u16,
    link_up: bool,
    gateway_reachable: bool,
    dns_reachable: bool,

    pub fn serialize(self: TestConnectivityResult, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        payload[2] = if (self.link_up) 1 else 0;
        payload[3] = if (self.gateway_reachable) 1 else 0;
        payload[4] = if (self.dns_reachable) 1 else 0;
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) TestConnectivityResult {
        return .{
            .error_code = readU16(payload, 0),
            .link_up = payload[2] != 0,
            .gateway_reachable = payload[3] != 0,
            .dns_reachable = payload[4] != 0,
        };
    }
};

//------------------------------------------------------------------------------
// Utility Functions
//------------------------------------------------------------------------------

/// Create IPv4 address from octets (a.b.c.d)
pub fn makeIpv4(a: u8, b: u8, c: u8, d: u8) Ipv4 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

/// Check if a message type is a socket API message (0x2000-0x2FFF)
pub fn isSocketMessage(msg_type: u16) bool {
    return msg_type >= 0x2000 and msg_type < 0x3000;
}

/// Check if a message type is an abstract operation (0x2040-0x205F)
pub fn isAbstractOperation(msg_type: u16) bool {
    return msg_type >= 0x2040 and msg_type < 0x2060;
}

/// Check if a message type is a socket SHM message (0x2060-0x206F)
pub fn isSocketShmMessage(msg_type: u16) bool {
    return msg_type >= 0x2060 and msg_type < 0x2070;
}

// --- Socket SHM Serialization ---
// Note: ShmOfferPayload removed -- SHM handle now travels in
// ConnectResult.recv_shm_handle / .send_shm_handle (C8.17 split),
// eliminating the separate-offer-message race.

pub const ShmDataReadyPayload = struct {
    socket_id: u16,
    bytes_available: u32,

    pub fn serialize(self: ShmDataReadyPayload, payload: *[PAYLOAD_SIZE]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket_id);
        writeU32(payload, 2, self.bytes_available);
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) ShmDataReadyPayload {
        return .{
            .socket_id = readU16(payload, 0),
            .bytes_available = readU32(payload, 2),
        };
    }
};

//------------------------------------------------------------------------------
// Contract hash (L1.1) -- wire-time refusal between mismatched trees.
//
// This protocol predates the `lib/man/rpc.zig` Method-spec convention (its
// serialize/deserialize signatures vary per-op -- some take an extra `data`
// slice, some don't -- so `net_client`/zmoltcp keep calling the existing
// Request/Result types directly). The wrappers below exist ONLY to give
// `contract.hashSpecs` a uniform REQ_TYPE/REPLY_TYPE/Request/Reply shape to
// walk; they carry no serialize/deserialize logic of their own and nothing
// else references them. Per BH4 the walked types describe WIRE bytes: the
// Request/Result structs are `extern` (asserts below pin their @offsetOf to
// the hand serializers), and Connect/TestDns -- whose replies pack u64/u32
// at unaligned wire offsets -- declare `align(1)` WireReply extern structs
// hashed in place of their Reply.
//------------------------------------------------------------------------------

const Connect = struct {
    pub const REQ_TYPE: u16 = MsgType.CONNECT;
    pub const REPLY_TYPE: u16 = MsgType.CONNECT_RESULT;
    pub const Request = ConnectRequest;
    pub const Reply = ConnectResult;

    /// Wire layout of ConnectResult.serialize(): the two u64 SHM handles sit
    /// at compact offsets 4/12 (not the naturally-aligned 8/16 an extern
    /// ConnectResult would report), so `align(1)` pins them to the bytes.
    pub const WireReply = extern struct {
        socket: u16,
        error_code: u16,
        recv_shm_handle: u64 align(1),
        send_shm_handle: u64 align(1),
    };
};

const Send = struct {
    pub const REQ_TYPE: u16 = MsgType.SEND;
    pub const REPLY_TYPE: u16 = MsgType.SEND_RESULT;
    pub const Request = SendRequest;
    pub const Reply = SendResult;
};

const Recv = struct {
    pub const REQ_TYPE: u16 = MsgType.RECV;
    pub const REPLY_TYPE: u16 = MsgType.RECV_RESULT;
    pub const Request = RecvRequest;
    pub const Reply = RecvResult;
};

const Close = struct {
    pub const REQ_TYPE: u16 = MsgType.CLOSE;
    pub const Request = CloseRequest;
};

const DnsResolve = struct {
    pub const REQ_TYPE: u16 = MsgType.DNS_RESOLVE;
    pub const REPLY_TYPE: u16 = MsgType.DNS_RESULT;
    pub const Request = DnsRequest;
    pub const Reply = DnsResult;
};

const Ping = struct {
    pub const REQ_TYPE: u16 = MsgType.PING;
    pub const REPLY_TYPE: u16 = MsgType.PING_RESULT;
    pub const Request = PingRequest;
    pub const Reply = PingResult;
};

const PingGateway = struct {
    pub const REQ_TYPE: u16 = MsgType.PING_GATEWAY;
    pub const REPLY_TYPE: u16 = MsgType.PING_GATEWAY_RESULT;
    pub const Request = PingGatewayRequest;
    pub const Reply = PingResult;
};

const TestDns = struct {
    pub const REQ_TYPE: u16 = MsgType.TEST_DNS;
    pub const REPLY_TYPE: u16 = MsgType.TEST_DNS_RESULT;
    pub const Request = TestDnsRequest;
    pub const Reply = TestDnsResult;

    /// Wire layout of TestDnsResult.serialize(): dns_server/rtt_us are packed
    /// at compact offsets 2/6 (not the aligned 4/8 an extern TestDnsResult
    /// would report), so `align(1)` pins them to the bytes.
    pub const WireReply = extern struct {
        error_code: u16,
        dns_server: u32 align(1),
        rtt_us: u32 align(1),
    };
};

const GetConfig = struct {
    pub const REQ_TYPE: u16 = MsgType.GET_CONFIG;
    pub const REPLY_TYPE: u16 = MsgType.CONFIG_RESULT;
    pub const Request = GetConfigRequest;
    pub const Reply = ConfigResult;
};

const TestConnectivity = struct {
    pub const REQ_TYPE: u16 = MsgType.TEST_CONNECTIVITY;
    pub const REPLY_TYPE: u16 = MsgType.TEST_CONNECTIVITY_RESULT;
    pub const Request = TestConnectivityRequest;
    pub const Reply = TestConnectivityResult;
};

pub const CONTRACT_VERSION: u16 = PROTOCOL_VERSION;

/// Method specs in wire order. Single source for both the CONTRACT_HASH walk
/// and `tools/gen_docs.zig`'s contract reference (docs/api/contracts.md).
pub const SPECS = .{ Connect, Send, Recv, Close, DnsResolve, Ping, PingGateway, TestDns, GetConfig, TestConnectivity };

pub const CONTRACT_HASH: u64 = contract.hashSpecs(SPECS, NAMESPACE, CONTRACT_VERSION);

// The contract hash and gen_docs derive field offsets via @offsetOf while
// serialize()/deserialize() hand-write byte offsets. The hashed structs are
// `extern` (or the Connect/TestDns WireReply overrides for the compact-
// unaligned replies) so their layout is defined; these asserts pin the two
// views together -- offset drift is a compile error, not a doc lie (BH4).
comptime {
    if (@offsetOf(ConnectRequest, "ip") != 0 or
        @offsetOf(ConnectRequest, "port") != 4 or
        @offsetOf(ConnectRequest, "protocol") != 6)
        @compileError("net: ConnectRequest layout drifted from serialize()");
    if (@offsetOf(Connect.WireReply, "socket") != 0 or
        @offsetOf(Connect.WireReply, "error_code") != 2 or
        @offsetOf(Connect.WireReply, "recv_shm_handle") != 4 or
        @offsetOf(Connect.WireReply, "send_shm_handle") != 12)
        @compileError("net: Connect.WireReply layout drifted from ConnectResult.serialize()");
    if (@offsetOf(SendRequest, "socket") != 0 or
        @offsetOf(SendRequest, "len") != 2)
        @compileError("net: SendRequest layout drifted from serialize()");
    if (@offsetOf(SendResult, "socket") != 0 or
        @offsetOf(SendResult, "sent") != 2 or
        @offsetOf(SendResult, "error_code") != 4)
        @compileError("net: SendResult layout drifted from serialize()");
    if (@offsetOf(RecvRequest, "socket") != 0 or
        @offsetOf(RecvRequest, "max_len") != 2 or
        @offsetOf(RecvRequest, "timeout_ms") != 4)
        @compileError("net: RecvRequest layout drifted from serialize()");
    if (@offsetOf(RecvResult, "socket") != 0 or
        @offsetOf(RecvResult, "len") != 2 or
        @offsetOf(RecvResult, "error_code") != 4)
        @compileError("net: RecvResult layout drifted from serialize()");
    if (@offsetOf(CloseRequest, "socket") != 0)
        @compileError("net: CloseRequest layout drifted from serialize()");
    if (@offsetOf(DnsRequest, "hostname_len") != 0)
        @compileError("net: DnsRequest layout drifted from serialize()");
    if (@offsetOf(DnsResult, "error_code") != 0 or
        @offsetOf(DnsResult, "addr_count") != 2 or
        @offsetOf(DnsResult, "addr") != 4)
        @compileError("net: DnsResult layout drifted from serialize()");
    if (@offsetOf(PingRequest, "ip") != 0 or
        @offsetOf(PingRequest, "seq") != 4 or
        @offsetOf(PingRequest, "timeout_ms") != 6)
        @compileError("net: PingRequest layout drifted from serialize()");
    if (@offsetOf(PingResult, "error_code") != 0 or
        @offsetOf(PingResult, "seq") != 2 or
        @offsetOf(PingResult, "rtt_us") != 4 or
        @offsetOf(PingResult, "ttl") != 8)
        @compileError("net: PingResult layout drifted from serialize()");
    if (@offsetOf(PingGatewayRequest, "seq") != 0 or
        @offsetOf(PingGatewayRequest, "timeout_ms") != 2)
        @compileError("net: PingGatewayRequest layout drifted from serialize()");
    if (@offsetOf(TestDnsRequest, "timeout_ms") != 0)
        @compileError("net: TestDnsRequest layout drifted from serialize()");
    if (@offsetOf(TestDns.WireReply, "error_code") != 0 or
        @offsetOf(TestDns.WireReply, "dns_server") != 2 or
        @offsetOf(TestDns.WireReply, "rtt_us") != 6)
        @compileError("net: TestDns.WireReply layout drifted from TestDnsResult.serialize()");
    if (@offsetOf(ConfigResult, "error_code") != 0 or
        @offsetOf(ConfigResult, "ip") != 4 or
        @offsetOf(ConfigResult, "subnet_mask") != 8 or
        @offsetOf(ConfigResult, "gateway") != 12 or
        @offsetOf(ConfigResult, "dns_primary") != 16 or
        @offsetOf(ConfigResult, "dns_secondary") != 20 or
        @offsetOf(ConfigResult, "link_up") != 24)
        @compileError("net: ConfigResult layout drifted from serialize()");
    if (@offsetOf(TestConnectivityRequest, "timeout_ms") != 0)
        @compileError("net: TestConnectivityRequest layout drifted from serialize()");
    if (@offsetOf(TestConnectivityResult, "error_code") != 0 or
        @offsetOf(TestConnectivityResult, "link_up") != 2 or
        @offsetOf(TestConnectivityResult, "gateway_reachable") != 3 or
        @offsetOf(TestConnectivityResult, "dns_reachable") != 4)
        @compileError("net: TestConnectivityResult layout drifted from serialize()");
}
