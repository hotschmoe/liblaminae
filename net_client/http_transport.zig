//------------------------------------------------------------------------------
// HTTP Transport — T2 client over `lib/net_client/`
//------------------------------------------------------------------------------
//
// The transport half of `lib/man/http.zig`. This module wires the parser to
// `lib/net_client/api.zig` (sockets) for the actual request/response cycle.
//
// Why split:
//   - `lib/man/http.zig` is pure, no peer dependency -- T1 vocabulary.
//   - This file is peer-dependent (zmoltcp via net_client) -- T2.
// Mixing them in one file made the whole thing T2 and forced anything
// reusing the parser to drag the network stack along.
//
// Re-exports the parser-side public surface (`Method`, `Status`, `Headers`,
// `Url`, etc.) so most callers can replace `const http = lib.http;` with
// `const http = lib.http_transport;` and keep working without two-name
// imports. Pure-parser users keep importing `lib.http`.
//
//------------------------------------------------------------------------------

const net = @import("api.zig");
const http = @import("../man/http.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
/// Built on net_api -- inherits T2 transitively (peer-dependent on
/// zmoltcp via socket ops).
pub const tier: u8 = 2;

//------------------------------------------------------------------------------
// Re-exports of the parser surface
//------------------------------------------------------------------------------

pub const Method = http.Method;
pub const Status = http.Status;
pub const Version = http.Version;
pub const Url = http.Url;
pub const UrlError = http.UrlError;
pub const Header = http.Header;
pub const Headers = http.Headers;
pub const MAX_HEADERS = http.MAX_HEADERS;
pub const Response = http.Response;
pub const RequestError = http.RequestError;
pub const ParseError = http.ParseError;
pub const ChunkError = http.ChunkError;

pub const parseUrl = http.parseUrl;
pub const percentEncode = http.percentEncode;
pub const buildRequest = http.buildRequest;
pub const parseResponse = http.parseResponse;
pub const decodeChunked = http.decodeChunked;
pub const findHeaderEnd = http.findHeaderEnd;
pub const parseIpv4String = http.parseIpv4String;

//------------------------------------------------------------------------------
// HTTP Client
//------------------------------------------------------------------------------

pub const ClientError = error{
    NetworkNotInitialized,
    DnsResolutionFailed,
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    ResponseParseFailed,
    BufferTooSmall,
    Timeout,
};

pub const ProgressFn = *const fn (bytes_received: usize) void;

pub const ClientOptions = struct {
    /// HTTP version to use
    version: Version = .http_1_0,

    /// Connection timeout in ms (0 = infinite)
    connect_timeout_ms: u32 = 10_000,

    /// Receive timeout in ms (0 = infinite)
    recv_timeout_ms: u32 = 30_000,

    /// Maximum response size
    max_response_size: usize = 64 * 1024,

    /// Follow redirects (not yet implemented)
    follow_redirects: bool = false,

    /// Max redirects to follow
    max_redirects: u8 = 5,

    /// Called periodically during recv with bytes received so far
    progress_fn: ?ProgressFn = null,
};

pub const Client = struct {
    options: ClientOptions,
    last_connect_error: ?net.SocketError = null,

    pub fn init() Client {
        return .{ .options = .{} };
    }

    pub fn initWithOptions(options: ClientOptions) Client {
        return .{ .options = options };
    }

    /// Perform an HTTP GET request.
    /// Resolves hostname, connects, sends request, receives response.
    /// Response body points into recv_buf (caller must keep buffer alive).
    pub fn get(
        self: *Client,
        url_str: []const u8,
        recv_buf: []u8,
    ) (ClientError || UrlError || net.SocketError)!Response {
        return self.request(.GET, url_str, null, null, recv_buf);
    }

    /// Perform an HTTP POST request with body.
    pub fn post(
        self: *Client,
        url_str: []const u8,
        body: []const u8,
        recv_buf: []u8,
    ) (ClientError || UrlError || net.SocketError)!Response {
        return self.request(.POST, url_str, null, body, recv_buf);
    }

    /// Perform an HTTP request with full control.
    pub fn request(
        self: *Client,
        method: Method,
        url_str: []const u8,
        headers: ?*const Headers,
        body: ?[]const u8,
        recv_buf: []u8,
    ) (ClientError || UrlError || net.SocketError)!Response {
        // Parse URL
        const url = try parseUrl(url_str);

        // Check if host is already an IP address (skip DNS)
        const ip = if (parseIpv4String(url.host)) |parsed_ip|
            parsed_ip
        else blk: {
            // Resolve hostname to IP
            break :blk net.resolve(url.host, self.options.connect_timeout_ms) catch |err| {
                if (err == net.SocketError.DnsError or err == net.SocketError.TimedOut) {
                    return ClientError.DnsResolutionFailed;
                }
                return err;
            };
        };

        // Connect
        const stream = net.connect(ip, url.port, .tcp, self.options.connect_timeout_ms) catch |err| {
            self.last_connect_error = err;
            if (err == net.SocketError.TimedOut) {
                return ClientError.Timeout;
            }
            return ClientError.ConnectionFailed;
        };

        // Build request
        var request_buf: [2048]u8 = undefined;
        const request_len = buildRequest(
            &request_buf,
            method,
            url,
            headers,
            body,
            self.options.version,
        ) catch return ClientError.BufferTooSmall;

        // Send request -- loop because stream.write returns short on partial
        // ring fills.
        var request_sent: usize = 0;
        while (request_sent < request_len) {
            const n = stream.write(request_buf[request_sent..request_len], 5_000) catch {
                stream.close();
                return ClientError.SendFailed;
            };
            if (n == 0) {
                stream.close();
                return ClientError.SendFailed;
            }
            request_sent += n;
        }

        // Receive response
        var total_received: usize = 0;
        var attempts: u32 = 0;
        const max_attempts: u32 = 500;

        while (attempts < max_attempts and total_received < recv_buf.len) : (attempts += 1) {
            const received = stream.read(
                recv_buf[total_received..],
                100,
            ) catch |err| {
                if (err == net.SocketError.WouldBlock) {
                    continue;
                }
                // ConnectionReset with data received = server closed connection
                if (err == net.SocketError.ConnectionReset and total_received > 0) {
                    break;
                }
                stream.close();
                return ClientError.ReceiveFailed;
            };

            if (received == 0) {
                // Check if we have complete response
                if (total_received > 0 and findHeaderEnd(recv_buf[0..total_received]) != null) {
                    break;
                }
                continue;
            }

            total_received += received;

            if (self.options.progress_fn) |pfn| {
                pfn(total_received);
            }

            // Check for complete response
            if (findHeaderEnd(recv_buf[0..total_received])) |header_end| {
                // Parse to check content-length or chunked
                const partial = parseResponse(recv_buf[0..total_received]) catch continue;
                if (partial.content_length) |cl| {
                    const expected = header_end + 4 + cl;
                    if (total_received >= expected) break;
                } else if (!partial.chunked) {
                    // HTTP/1.0 style: read until connection closes
                    // Continue reading...
                }
            }
        }

        stream.close();

        if (total_received == 0) {
            return ClientError.ReceiveFailed;
        }

        // Parse response
        var response = parseResponse(recv_buf[0..total_received]) catch {
            return ClientError.ResponseParseFailed;
        };

        // Handle chunked encoding
        if (response.chunked and response.body.len > 0) {
            // Need to decode in-place. Body slice points into recv_buf.
            const body_start = @intFromPtr(response.body.ptr) - @intFromPtr(recv_buf.ptr);
            const decoded_len = decodeChunked(recv_buf[body_start..total_received]) catch {
                return ClientError.ResponseParseFailed;
            };
            response.body = recv_buf[body_start..][0..decoded_len];
        }

        return response;
    }
};

//------------------------------------------------------------------------------
// Convenience Functions
//------------------------------------------------------------------------------

/// Simple GET request using default client options.
pub fn get(url: []const u8, buf: []u8) (ClientError || UrlError || net.SocketError)!Response {
    var client = Client.init();
    return client.get(url, buf);
}

/// Simple POST request using default client options.
pub fn post(url: []const u8, body: []const u8, buf: []u8) (ClientError || UrlError || net.SocketError)!Response {
    var client = Client.init();
    return client.post(url, body, buf);
}
