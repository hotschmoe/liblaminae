//------------------------------------------------------------------------------
// Network Stack Protocol Specification
//
// This defines the contract between:
//   - Network Stack Containers (c_lwIP, or any replacement)
//   - Application Containers (net_test, shell, browsers, etc.)
//
// IMPLEMENTERS: If you're building a network stack, implement all REQUIRED
// message handlers. OPTIONAL handlers should return ErrorCode.NOT_SUPPORTED.
//
// CONSUMERS: Use liblaminae.net_api for ergonomic wrappers, or send raw
// ICC messages using these types directly.
//
// DESIGN PRINCIPLE: Abstract commands (PING_GATEWAY, TEST_DNS) let consumers
// express intent without knowing network topology. The stack owns all config.
//------------------------------------------------------------------------------

const std = @import("std");

/// Protocol version - bump on breaking changes
pub const PROTOCOL_VERSION: u16 = 1;

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
    /// Payload: GenericResult
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
};

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

/// Maximum data bytes in a single SEND message (248 - 4 byte header)
pub const MAX_SEND_DATA: usize = 244;

/// Maximum data bytes in a single RECV response (248 - 8 byte header)
pub const MAX_RECV_DATA: usize = 240;

/// Maximum hostname length for DNS resolution
pub const MAX_HOSTNAME_LEN: usize = 240;

//------------------------------------------------------------------------------
// Payload Structures
//
// Pure Zig structs - C containers handle ABI translation internally.
// All multi-byte integers are native endian unless noted.
// IPv4 addresses are network byte order (big-endian).
//------------------------------------------------------------------------------

/// Socket handle type
pub const Socket = u16;

/// IPv4 address (network byte order)
pub const Ipv4 = u32;

// --- Socket Operations ---

pub const ConnectRequest = struct {
    ip: Ipv4,
    port: u16,
    protocol: Protocol,

    pub fn serialize(self: ConnectRequest, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU32(payload, 0, self.ip);
        writeU16(payload, 4, self.port);
        payload[6] = @intFromEnum(self.protocol);
    }

    pub fn deserialize(payload: *const [248]u8) ConnectRequest {
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

    pub fn serialize(self: ConnectResult, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.error_code);
    }

    pub fn deserialize(payload: *const [248]u8) ConnectResult {
        return .{
            .socket = readU16(payload, 0),
            .error_code = readU16(payload, 2),
        };
    }
};

pub const SendRequest = struct {
    socket: Socket,
    len: u16,

    pub fn serialize(self: SendRequest, payload: *[248]u8, data: []const u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        const actual_len: u16 = @intCast(@min(data.len, MAX_SEND_DATA));
        writeU16(payload, 2, actual_len);
        if (actual_len > 0) {
            @memcpy(payload[4 .. 4 + actual_len], data[0..actual_len]);
        }
    }

    pub fn deserialize(payload: *const [248]u8) struct { header: SendRequest, data: []const u8 } {
        const socket = readU16(payload, 0);
        const len = readU16(payload, 2);
        const actual_len = @min(len, MAX_SEND_DATA);
        return .{
            .header = .{ .socket = socket, .len = len },
            .data = payload[4 .. 4 + actual_len],
        };
    }
};

pub const SendResult = struct {
    socket: Socket,
    sent: u16,
    error_code: u16,

    pub fn serialize(self: SendResult, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.sent);
        writeU16(payload, 4, self.error_code);
    }

    pub fn deserialize(payload: *const [248]u8) SendResult {
        return .{
            .socket = readU16(payload, 0),
            .sent = readU16(payload, 2),
            .error_code = readU16(payload, 4),
        };
    }
};

pub const RecvRequest = struct {
    socket: Socket,
    max_len: u16,
    timeout_ms: u16,

    pub fn serialize(self: RecvRequest, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.max_len);
        writeU16(payload, 4, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [248]u8) RecvRequest {
        return .{
            .socket = readU16(payload, 0),
            .max_len = readU16(payload, 2),
            .timeout_ms = readU16(payload, 4),
        };
    }
};

pub const RecvResult = struct {
    socket: Socket,
    len: u16,
    error_code: u16,

    pub fn serialize(self: RecvResult, payload: *[248]u8, data: []const u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
        writeU16(payload, 2, self.len);
        writeU16(payload, 4, self.error_code);
        const actual_len = @min(data.len, MAX_RECV_DATA);
        if (actual_len > 0) {
            @memcpy(payload[8 .. 8 + actual_len], data[0..actual_len]);
        }
    }

    pub fn deserialize(payload: *const [248]u8) struct { header: RecvResult, data: []const u8 } {
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

pub const CloseRequest = struct {
    socket: Socket,

    pub fn serialize(self: CloseRequest, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.socket);
    }

    pub fn deserialize(payload: *const [248]u8) CloseRequest {
        return .{ .socket = readU16(payload, 0) };
    }
};

// --- DNS Operations ---

pub const DnsRequest = struct {
    hostname_len: u16,

    pub fn serialize(self: DnsRequest, payload: *[248]u8, hostname: []const u8) void {
        @memset(payload, 0);
        const actual_len: u16 = @intCast(@min(hostname.len, MAX_HOSTNAME_LEN));
        writeU16(payload, 0, actual_len);
        if (actual_len > 0) {
            @memcpy(payload[4 .. 4 + actual_len], hostname[0..actual_len]);
        }
        _ = self;
    }

    pub fn deserialize(payload: *const [248]u8) struct { len: u16, hostname: []const u8 } {
        const len = readU16(payload, 0);
        const actual_len = @min(len, MAX_HOSTNAME_LEN);
        return .{
            .len = len,
            .hostname = payload[4 .. 4 + actual_len],
        };
    }
};

pub const DnsResult = struct {
    error_code: u16,
    addr_count: u16,
    addr: Ipv4,

    pub fn serialize(self: DnsResult, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU16(payload, 2, self.addr_count);
        writeU32(payload, 4, self.addr);
    }

    pub fn deserialize(payload: *const [248]u8) DnsResult {
        return .{
            .error_code = readU16(payload, 0),
            .addr_count = readU16(payload, 2),
            .addr = readU32(payload, 4),
        };
    }
};

// --- Ping Operations ---

pub const PingRequest = struct {
    ip: Ipv4,
    seq: u16,
    timeout_ms: u16,

    pub fn serialize(self: PingRequest, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU32(payload, 0, self.ip);
        writeU16(payload, 4, self.seq);
        writeU16(payload, 6, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [248]u8) PingRequest {
        return .{
            .ip = readU32(payload, 0),
            .seq = readU16(payload, 4),
            .timeout_ms = readU16(payload, 6),
        };
    }
};

pub const PingResult = struct {
    error_code: u16,
    seq: u16,
    rtt_us: u32,
    ttl: u8,

    pub fn serialize(self: PingResult, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU16(payload, 2, self.seq);
        writeU32(payload, 4, self.rtt_us);
        payload[8] = self.ttl;
    }

    pub fn deserialize(payload: *const [248]u8) PingResult {
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
pub const PingGatewayRequest = struct {
    seq: u16,
    timeout_ms: u16,

    pub fn serialize(self: PingGatewayRequest, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.seq);
        writeU16(payload, 2, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [248]u8) PingGatewayRequest {
        return .{
            .seq = readU16(payload, 0),
            .timeout_ms = readU16(payload, 2),
        };
    }
};

/// Request to test DNS server connectivity
/// Behavior: Stack sends test query to its DNS server
pub const TestDnsRequest = struct {
    timeout_ms: u16,

    pub fn serialize(self: TestDnsRequest, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [248]u8) TestDnsRequest {
        return .{ .timeout_ms = readU16(payload, 0) };
    }
};

/// DNS test result
pub const TestDnsResult = struct {
    error_code: u16,
    dns_server: Ipv4,
    rtt_us: u32,

    pub fn serialize(self: TestDnsResult, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU32(payload, 2, self.dns_server);
        writeU32(payload, 6, self.rtt_us);
    }

    pub fn deserialize(payload: *const [248]u8) TestDnsResult {
        return .{
            .error_code = readU16(payload, 0),
            .dns_server = readU32(payload, 2),
            .rtt_us = readU32(payload, 6),
        };
    }
};

/// Request for network configuration (escape hatch)
pub const GetConfigRequest = struct {
    pub fn serialize(_: GetConfigRequest, payload: *[248]u8) void {
        @memset(payload, 0);
    }

    pub fn deserialize(_: *const [248]u8) GetConfigRequest {
        return .{};
    }
};

/// Network configuration response
pub const ConfigResult = struct {
    error_code: u16,
    ip: Ipv4,
    subnet_mask: Ipv4,
    gateway: Ipv4,
    dns_primary: Ipv4,
    dns_secondary: Ipv4,
    link_up: bool,

    pub fn serialize(self: ConfigResult, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        writeU32(payload, 4, self.ip);
        writeU32(payload, 8, self.subnet_mask);
        writeU32(payload, 12, self.gateway);
        writeU32(payload, 16, self.dns_primary);
        writeU32(payload, 20, self.dns_secondary);
        payload[24] = if (self.link_up) 1 else 0;
    }

    pub fn deserialize(payload: *const [248]u8) ConfigResult {
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
pub const TestConnectivityRequest = struct {
    timeout_ms: u16,

    pub fn serialize(self: TestConnectivityRequest, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.timeout_ms);
    }

    pub fn deserialize(payload: *const [248]u8) TestConnectivityRequest {
        return .{ .timeout_ms = readU16(payload, 0) };
    }
};

/// Connectivity test result
pub const TestConnectivityResult = struct {
    error_code: u16,
    link_up: bool,
    gateway_reachable: bool,
    dns_reachable: bool,

    pub fn serialize(self: TestConnectivityResult, payload: *[248]u8) void {
        @memset(payload, 0);
        writeU16(payload, 0, self.error_code);
        payload[2] = if (self.link_up) 1 else 0;
        payload[3] = if (self.gateway_reachable) 1 else 0;
        payload[4] = if (self.dns_reachable) 1 else 0;
    }

    pub fn deserialize(payload: *const [248]u8) TestConnectivityResult {
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

/// Format IPv4 address to buffer, returns slice of written bytes
pub fn formatIpv4(ip: Ipv4, buf: []u8) []u8 {
    var pos: usize = 0;
    inline for (0..4) |i| {
        const octet: u8 = @truncate(ip >> @intCast(i * 8));
        pos += formatDecimal(octet, buf[pos..]);
        if (i < 3 and pos < buf.len) {
            buf[pos] = '.';
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn formatDecimal(value: u8, buf: []u8) usize {
    if (buf.len == 0) return 0;
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    var digits: [3]u8 = undefined;
    var count: usize = 0;
    var v = value;
    while (v > 0) {
        digits[count] = @truncate((v % 10) + '0');
        count += 1;
        v /= 10;
    }
    var i: usize = 0;
    while (i < count and i < buf.len) : (i += 1) {
        buf[i] = digits[count - 1 - i];
    }
    return count;
}

/// Check if a message type is a socket API message (0x2000-0x2FFF)
pub fn isSocketMessage(msg_type: u16) bool {
    return msg_type >= 0x2000 and msg_type < 0x3000;
}

/// Check if a message type is an abstract operation (0x2040-0x205F)
pub fn isAbstractOperation(msg_type: u16) bool {
    return msg_type >= 0x2040 and msg_type < 0x2060;
}
