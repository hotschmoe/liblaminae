//------------------------------------------------------------------------------
// Network API - Socket-like Interface for Applications
//
// Provides TCP/UDP connectivity for user containers via ICC to network stack.
//
// Architecture:
//   App Container --ICC--> Network Stack (c_lwIP) --packets--> HW Driver --hw--> Network
//
// Timeout Convention:
//   All blocking operations accept a timeout_ms parameter:
//   - 0 = wait forever (no timeout)
//   - Any other value = timeout in milliseconds
//
// Usage:
//   const lib = @import("liblaminae");
//   const net = lib.net_api;
//
//   try net.init();
//   const sock = try net.connect(ip, port, .tcp, 0);       // Wait forever
//   const sock = try net.connect(ip, port, .tcp, 5000);    // 5 second timeout
//   _ = try net.send(sock, data, 0);
//   const n = try net.recv(sock, buf, 1000);
//   net.close(sock);
//
// Abstract Operations (stack handles topology):
//   const result = try net.pingGateway(1, 3000);
//   const config = try net.getConfig(0);
//   const conn = try net.testConnectivity(5000);
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const protocol = @import("net_stack_protocol");

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

/// Convert milliseconds to nanoseconds, handling infinite case
fn toNanoseconds(timeout_ms: u32) u64 {
    if (timeout_ms == 0) return 0xFFFF_FFFF_FFFF_FFFF; // INFINITE
    return @as(u64, timeout_ms) * 1_000_000;
}

//------------------------------------------------------------------------------
// State
//------------------------------------------------------------------------------

var network_manager_id: u16 = 0xFFFF;

//------------------------------------------------------------------------------
// Initialization
//------------------------------------------------------------------------------

pub const InitError = error{StackNotFound};

/// Initialize the network API by discovering the network stack via namespace.
/// Must be called before any network operations.
pub fn init() InitError!void {
    const name = "net.stack";
    const result = sys.ns_lookup(@ptrCast(name.ptr), name.len);
    if (result == 0xFFFF or result >= 0xFFFF_FFFF_0000_0000) {
        return InitError.StackNotFound;
    }
    network_manager_id = @truncate(result);
}

pub fn setNetworkManager(id: u16) void {
    network_manager_id = id;
}

pub fn getNetworkManager() u16 {
    return network_manager_id;
}

//------------------------------------------------------------------------------
// Internal Helpers
//------------------------------------------------------------------------------

fn sendAndRecv(msg: *sys.Message, timeout_ns: u64) SocketError!void {
    const send_result = sys.icc_send(network_manager_id, msg);
    if (send_result >= 0xFFFF_FFFF_0000_0000) return SocketError.IccError;

    const recv_result = sys.icc_recv(msg, timeout_ns);
    if (recv_result >= 0xFFFF_FFFF_0000_0000) return SocketError.TimedOut;
}

//------------------------------------------------------------------------------
// Socket Operations
//------------------------------------------------------------------------------

/// Connect to a remote host.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn connect(ip: Ipv4, port: u16, proto: Protocol, timeout_ms: u32) SocketError!Socket {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.CONNECT;
    msg.flags = 0;

    const req = ConnectRequest{ .ip = ip, .port = port, .protocol = proto };
    req.serialize(&msg.payload);

    try sendAndRecv(&msg, toNanoseconds(timeout_ms));

    if (msg.msg_type != MsgType.CONNECT_RESULT) return SocketError.IccError;

    const result = ConnectResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result.socket;
}

/// Send data on a socket.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn send(socket: Socket, data: []const u8, timeout_ms: u32) SocketError!usize {
    if (data.len == 0) return 0;

    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.SEND;
    msg.flags = 0;

    const req = SendRequest{
        .socket = socket,
        .len = @intCast(@min(data.len, protocol.MAX_SEND_DATA)),
    };
    req.serialize(&msg.payload, data);

    try sendAndRecv(&msg, toNanoseconds(timeout_ms));

    if (msg.msg_type != MsgType.SEND_RESULT) return SocketError.IccError;

    const result = SendResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result.sent;
}

/// Receive data from a socket.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn recv(socket: Socket, buf: []u8, timeout_ms: u32) SocketError!usize {
    if (buf.len == 0) return 0;

    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.RECV;
    msg.flags = 0;

    const req = RecvRequest{
        .socket = socket,
        .max_len = @intCast(@min(buf.len, protocol.MAX_RECV_DATA)),
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    };
    req.serialize(&msg.payload);

    // IPC timeout = recv timeout + buffer for IPC overhead
    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 1_000_000_000; // +1s overhead

    try sendAndRecv(&msg, ipc_timeout);

    if (msg.msg_type != MsgType.RECV_RESULT) return SocketError.IccError;

    const parsed = RecvResult.deserialize(&msg.payload);
    if (parsed.header.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(parsed.header.error_code) orelse SocketError.Unknown;
    }

    const copy_len = @min(parsed.data.len, buf.len);
    if (copy_len > 0) {
        @memcpy(buf[0..copy_len], parsed.data[0..copy_len]);
    }
    return copy_len;
}

/// Close a socket. Waits for ACK to avoid leaving stale messages in IPC queue.
pub fn close(socket: Socket) void {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.CLOSE;
    msg.flags = 0;

    const req = CloseRequest{ .socket = socket };
    req.serialize(&msg.payload);

    _ = sys.icc_send(network_manager_id, &msg);
    // Wait for ACK - must complete before next operation to avoid stale messages
    _ = sys.icc_recv(&msg, 2_000_000_000); // 2 seconds
}

//------------------------------------------------------------------------------
// DNS Operations
//------------------------------------------------------------------------------

/// Resolve a hostname to an IP address.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn resolve(hostname: []const u8, timeout_ms: u32) SocketError!Ipv4 {
    if (hostname.len == 0 or hostname.len > protocol.MAX_HOSTNAME_LEN) {
        return SocketError.InvalidArgument;
    }

    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.DNS_RESOLVE;
    msg.flags = 0;

    const req = DnsRequest{ .hostname_len = @intCast(hostname.len) };
    req.serialize(&msg.payload, hostname);

    try sendAndRecv(&msg, toNanoseconds(timeout_ms));

    if (msg.msg_type != MsgType.DNS_RESULT) return SocketError.IccError;

    const result = DnsResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return SocketError.DnsError;
    }
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
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn ping(ip: Ipv4, seq: u16, timeout_ms: u32) SocketError!PingResponse {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.PING;
    msg.flags = 0;

    const req = PingRequest{
        .ip = ip,
        .seq = seq,
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    };
    req.serialize(&msg.payload);

    // IPC timeout = ping timeout + buffer
    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000; // +2s overhead

    try sendAndRecv(&msg, ipc_timeout);

    if (msg.msg_type != MsgType.PING_RESULT) return SocketError.IccError;

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
/// The app doesn't need to know the gateway IP - the stack owns that config.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn pingGateway(seq: u16, timeout_ms: u32) SocketError!PingResponse {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.PING_GATEWAY;
    msg.flags = 0;

    const req = PingGatewayRequest{
        .seq = seq,
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    };
    req.serialize(&msg.payload);

    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000;

    try sendAndRecv(&msg, ipc_timeout);

    if (msg.msg_type != MsgType.PING_GATEWAY_RESULT) return SocketError.IccError;

    const result = PingResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return .{ .rtt_us = result.rtt_us, .ttl = result.ttl };
}

/// Test DNS server connectivity.
/// The app doesn't need to know the DNS server IP - the stack owns that config.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn testDns(timeout_ms: u32) SocketError!TestDnsResult {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.TEST_DNS;
    msg.flags = 0;

    const req = TestDnsRequest{
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    };
    req.serialize(&msg.payload);

    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000;

    try sendAndRecv(&msg, ipc_timeout);

    if (msg.msg_type != MsgType.TEST_DNS_RESULT) return SocketError.IccError;

    const result = TestDnsResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result;
}

/// Query the network stack's configuration.
/// Escape hatch for apps that genuinely need to know network topology.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn getConfig(timeout_ms: u32) SocketError!ConfigResult {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.GET_CONFIG;
    msg.flags = 0;

    const req = GetConfigRequest{};
    req.serialize(&msg.payload);

    try sendAndRecv(&msg, toNanoseconds(timeout_ms));

    if (msg.msg_type != MsgType.CONFIG_RESULT) return SocketError.IccError;

    const result = ConfigResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result;
}

/// Test overall network connectivity.
/// Returns link status, gateway reachability, and DNS reachability.
/// timeout_ms: 0 = wait forever, otherwise timeout in milliseconds
pub fn testConnectivity(timeout_ms: u32) SocketError!TestConnectivityResult {
    var msg: sys.Message = undefined;
    msg.msg_type = MsgType.TEST_CONNECTIVITY;
    msg.flags = 0;

    const req = TestConnectivityRequest{
        .timeout_ms = if (timeout_ms > 0xFFFF) 0xFFFF else @truncate(timeout_ms),
    };
    req.serialize(&msg.payload);

    const ipc_timeout = if (timeout_ms == 0)
        toNanoseconds(0)
    else
        toNanoseconds(timeout_ms) + 2_000_000_000;

    try sendAndRecv(&msg, ipc_timeout);

    if (msg.msg_type != MsgType.TEST_CONNECTIVITY_RESULT) return SocketError.IccError;

    const result = TestConnectivityResult.deserialize(&msg.payload);
    if (result.error_code != ErrorCode.SUCCESS) {
        return ErrorCode.toError(result.error_code) orelse SocketError.Unknown;
    }
    return result;
}
