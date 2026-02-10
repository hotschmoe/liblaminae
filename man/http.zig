//------------------------------------------------------------------------------
// HTTP Client Library for Laminae
//
// Provides HTTP/1.1 client functionality for freestanding targets.
// Built on top of net_api for socket operations.
//
// Features:
//   - URL parsing (http:// only, no TLS)
//   - HTTP/1.0 and HTTP/1.1 requests
//   - Chunked transfer-encoding support
//   - Header parsing
//
// Usage:
//   const lib = @import("liblaminae");
//   const http = lib.http;
//   const net = lib.net_api;
//
//   try net.init();
//   var client = http.Client.init();
//   const response = try client.get("http://example.com/path", &buf);
//
//------------------------------------------------------------------------------

const net = @import("net_api.zig");

//------------------------------------------------------------------------------
// HTTP Types
//------------------------------------------------------------------------------

/// HTTP request methods
pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .HEAD => "HEAD",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .OPTIONS => "OPTIONS",
        };
    }
};

/// HTTP status codes
pub const Status = enum(u16) {
    // 1xx Informational
    @"continue" = 100,
    switching_protocols = 101,

    // 2xx Success
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,

    // 3xx Redirection
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,

    // 4xx Client Errors
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    too_many_requests = 429,

    // 5xx Server Errors
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,

    // Unknown
    unknown = 0,

    pub fn fromCode(code: u16) Status {
        return @enumFromInt(code);
    }

    pub fn phrase(self: Status) []const u8 {
        return switch (self) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .no_content => "No Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .too_many_requests => "Too Many Requests",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .unknown => "Unknown",
        };
    }

    pub fn isSuccess(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 200 and code < 300;
    }

    pub fn isRedirect(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 300 and code < 400;
    }

    pub fn isClientError(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 400 and code < 500;
    }

    pub fn isServerError(self: Status) bool {
        const code = @intFromEnum(self);
        return code >= 500 and code < 600;
    }
};

/// HTTP version
pub const Version = enum {
    http_1_0,
    http_1_1,

    pub fn toString(self: Version) []const u8 {
        return switch (self) {
            .http_1_0 => "HTTP/1.0",
            .http_1_1 => "HTTP/1.1",
        };
    }
};

//------------------------------------------------------------------------------
// URL Parsing
//------------------------------------------------------------------------------

pub const Url = struct {
    scheme: []const u8, // "http"
    host: []const u8, // "example.com"
    port: u16, // 80
    path: []const u8, // "/foo/bar" or "/"

    /// Raw URL string for reference
    raw: []const u8,
};

pub const UrlError = error{
    InvalidUrl,
    UnsupportedScheme,
    MissingHost,
    InvalidPort,
    UrlTooLong,
};

/// Parse a URL string into components.
/// Only supports http:// scheme (no TLS in freestanding).
pub fn parseUrl(url: []const u8) UrlError!Url {
    if (url.len > 2048) return UrlError.UrlTooLong;

    var result = Url{
        .scheme = "",
        .host = "",
        .port = 80,
        .path = "/",
        .raw = url,
    };

    var remaining = url;

    // Parse scheme
    if (startsWith(remaining, "http://")) {
        result.scheme = "http";
        remaining = remaining[7..];
    } else if (startsWith(remaining, "https://")) {
        return UrlError.UnsupportedScheme; // No TLS support
    } else {
        // No scheme, assume http
        result.scheme = "http";
    }

    // Find end of host (either :port, /path, or end of string)
    var host_end: usize = 0;
    var port_start: ?usize = null;

    for (remaining, 0..) |c, i| {
        if (c == ':') {
            host_end = i;
            port_start = i + 1;
            break;
        } else if (c == '/') {
            host_end = i;
            break;
        }
        host_end = i + 1;
    }

    if (host_end == 0) return UrlError.MissingHost;
    result.host = remaining[0..host_end];

    // Parse port if present
    if (port_start) |ps| {
        var port_end = ps;
        while (port_end < remaining.len and remaining[port_end] != '/') {
            port_end += 1;
        }
        if (port_end > ps) {
            result.port = parsePort(remaining[ps..port_end]) orelse return UrlError.InvalidPort;
        }
        remaining = remaining[port_end..];
    } else {
        remaining = remaining[host_end..];
    }

    // Rest is path
    if (remaining.len > 0) {
        result.path = remaining;
    }

    return result;
}

fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 5) return null;
    var port: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        port = port * 10 + (c - '0');
        if (port > 65535) return null;
    }
    return @truncate(port);
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return eql(haystack[0..needle.len], needle);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

/// Try to parse a string as an IPv4 address (e.g., "10.0.2.2").
/// Returns the IP in little-endian form matching makeIpv4() convention
/// (first octet in LSB), or null if not an IP.
fn parseIpv4String(host: []const u8) ?u32 {
    if (host.len == 0 or host.len > 15) return null;

    var octets: [4]u8 = undefined;
    var octet_idx: usize = 0;
    var current: u32 = 0;
    var digit_count: usize = 0;

    for (host) |c| {
        if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            digit_count += 1;
            if (current > 255 or digit_count > 3) return null;
        } else if (c == '.') {
            if (digit_count == 0 or octet_idx >= 3) return null;
            octets[octet_idx] = @truncate(current);
            octet_idx += 1;
            current = 0;
            digit_count = 0;
        } else {
            return null;
        }
    }

    if (octet_idx != 3 or digit_count == 0) return null;
    octets[3] = @truncate(current);

    // Match makeIpv4() convention: first octet in LSB
    return @as(u32, octets[0]) |
        (@as(u32, octets[1]) << 8) |
        (@as(u32, octets[2]) << 16) |
        (@as(u32, octets[3]) << 24);
}

//------------------------------------------------------------------------------
// HTTP Headers
//------------------------------------------------------------------------------

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Maximum headers we track
pub const MAX_HEADERS = 32;

pub const Headers = struct {
    items: [MAX_HEADERS]Header,
    count: usize,

    pub fn init() Headers {
        return .{
            .items = undefined,
            .count = 0,
        };
    }

    pub fn add(self: *Headers, name: []const u8, value: []const u8) bool {
        if (self.count >= MAX_HEADERS) return false;
        self.items[self.count] = .{ .name = name, .value = value };
        self.count += 1;
        return true;
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.items[0..self.count]) |h| {
            if (eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn slice(self: *const Headers) []const Header {
        return self.items[0..self.count];
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

//------------------------------------------------------------------------------
// HTTP Response
//------------------------------------------------------------------------------

pub const Response = struct {
    version: Version,
    status: Status,
    status_code: u16,
    headers: Headers,

    /// Points into the receive buffer (valid only while buffer is valid)
    body: []const u8,

    /// Total bytes consumed from input (headers + body)
    bytes_consumed: usize,

    /// Transfer encoding
    chunked: bool,

    /// Content-Length if present, null otherwise
    content_length: ?usize,
};

//------------------------------------------------------------------------------
// HTTP Request Building
//------------------------------------------------------------------------------

pub const RequestError = error{
    BufferTooSmall,
    InvalidMethod,
};

/// Build an HTTP request into the provided buffer.
/// Returns the number of bytes written.
pub fn buildRequest(
    buf: []u8,
    method: Method,
    url: Url,
    headers: ?*const Headers,
    body: ?[]const u8,
    version: Version,
) RequestError!usize {
    var pos: usize = 0;

    // Request line: METHOD /path HTTP/1.1\r\n
    pos = appendStr(buf, pos, method.toString()) orelse return RequestError.BufferTooSmall;
    pos = appendStr(buf, pos, " ") orelse return RequestError.BufferTooSmall;
    pos = appendStr(buf, pos, url.path) orelse return RequestError.BufferTooSmall;
    pos = appendStr(buf, pos, " ") orelse return RequestError.BufferTooSmall;
    pos = appendStr(buf, pos, version.toString()) orelse return RequestError.BufferTooSmall;
    pos = appendStr(buf, pos, "\r\n") orelse return RequestError.BufferTooSmall;

    // Host header (required for HTTP/1.1)
    pos = appendStr(buf, pos, "Host: ") orelse return RequestError.BufferTooSmall;
    pos = appendStr(buf, pos, url.host) orelse return RequestError.BufferTooSmall;
    if (url.port != 80) {
        pos = appendStr(buf, pos, ":") orelse return RequestError.BufferTooSmall;
        pos = appendDecimal(buf, pos, url.port) orelse return RequestError.BufferTooSmall;
    }
    pos = appendStr(buf, pos, "\r\n") orelse return RequestError.BufferTooSmall;

    // Custom headers
    if (headers) |hdrs| {
        for (hdrs.items[0..hdrs.count]) |h| {
            pos = appendStr(buf, pos, h.name) orelse return RequestError.BufferTooSmall;
            pos = appendStr(buf, pos, ": ") orelse return RequestError.BufferTooSmall;
            pos = appendStr(buf, pos, h.value) orelse return RequestError.BufferTooSmall;
            pos = appendStr(buf, pos, "\r\n") orelse return RequestError.BufferTooSmall;
        }
    }

    // Content-Length for body
    if (body) |b| {
        pos = appendStr(buf, pos, "Content-Length: ") orelse return RequestError.BufferTooSmall;
        pos = appendDecimal(buf, pos, b.len) orelse return RequestError.BufferTooSmall;
        pos = appendStr(buf, pos, "\r\n") orelse return RequestError.BufferTooSmall;
    }

    // End of headers
    pos = appendStr(buf, pos, "\r\n") orelse return RequestError.BufferTooSmall;

    // Body
    if (body) |b| {
        if (pos + b.len > buf.len) return RequestError.BufferTooSmall;
        @memcpy(buf[pos..][0..b.len], b);
        pos += b.len;
    }

    return pos;
}

fn appendStr(buf: []u8, pos: usize, s: []const u8) ?usize {
    if (pos + s.len > buf.len) return null;
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn appendDecimal(buf: []u8, pos: usize, value: usize) ?usize {
    var tmp: [20]u8 = undefined;
    var v = value;
    var len: usize = 0;

    if (v == 0) {
        if (pos >= buf.len) return null;
        buf[pos] = '0';
        return pos + 1;
    }

    while (v > 0) {
        tmp[len] = @truncate((v % 10) + '0');
        v /= 10;
        len += 1;
    }

    if (pos + len > buf.len) return null;

    // Reverse into buffer
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[pos + i] = tmp[len - 1 - i];
    }

    return pos + len;
}

//------------------------------------------------------------------------------
// HTTP Response Parsing
//------------------------------------------------------------------------------

pub const ParseError = error{
    InvalidResponse,
    HeadersTooLarge,
    InvalidChunk,
    IncompleteResponse,
    TooManyHeaders,
};

/// Parse an HTTP response from a buffer.
/// Returns the parsed response with body slice pointing into the buffer.
pub fn parseResponse(buf: []const u8) ParseError!Response {
    var response = Response{
        .version = .http_1_1,
        .status = .unknown,
        .status_code = 0,
        .headers = Headers.init(),
        .body = &[_]u8{},
        .bytes_consumed = 0,
        .chunked = false,
        .content_length = null,
    };

    // Find end of headers (\r\n\r\n)
    const header_end = findHeaderEnd(buf) orelse return ParseError.IncompleteResponse;

    // Parse status line
    const status_line_end = findLineEnd(buf) orelse return ParseError.InvalidResponse;
    const status_line = buf[0..status_line_end];

    // "HTTP/1.x NNN reason"
    if (status_line.len < 12) return ParseError.InvalidResponse;
    if (!startsWith(status_line, "HTTP/1.")) return ParseError.InvalidResponse;

    if (status_line[7] == '0') {
        response.version = .http_1_0;
    } else if (status_line[7] == '1') {
        response.version = .http_1_1;
    } else {
        return ParseError.InvalidResponse;
    }

    // Parse status code
    if (status_line[8] != ' ') return ParseError.InvalidResponse;
    response.status_code = parseStatusCode(status_line[9..12]) orelse return ParseError.InvalidResponse;
    response.status = Status.fromCode(response.status_code);

    // Parse headers
    var line_start = status_line_end + 2; // Skip \r\n
    while (line_start < header_end) {
        const line_end = findLineEndFrom(buf, line_start) orelse break;
        if (line_end == line_start) break; // Empty line = end of headers

        const line = buf[line_start..line_end];
        const colon = indexOf(line, ':') orelse {
            line_start = line_end + 2;
            continue;
        };

        const name = line[0..colon];
        var value_start = colon + 1;
        // Skip leading whitespace
        while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) {
            value_start += 1;
        }
        const value = line[value_start..];

        if (!response.headers.add(name, value)) {
            return ParseError.TooManyHeaders;
        }

        // Check for special headers
        if (eqlIgnoreCase(name, "transfer-encoding")) {
            if (containsIgnoreCase(value, "chunked")) {
                response.chunked = true;
            }
        } else if (eqlIgnoreCase(name, "content-length")) {
            response.content_length = parseContentLength(value);
        }

        line_start = line_end + 2;
    }

    // Body starts after headers
    const body_start = header_end + 4; // After \r\n\r\n
    response.body = buf[body_start..];
    response.bytes_consumed = buf.len;

    return response;
}

fn findHeaderEnd(buf: []const u8) ?usize {
    if (buf.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and
            buf[i + 2] == '\r' and buf[i + 3] == '\n')
        {
            return i;
        }
    }
    return null;
}

fn findLineEnd(buf: []const u8) ?usize {
    return findLineEndFrom(buf, 0);
}

fn findLineEndFrom(buf: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n') return i;
    }
    return null;
}

fn parseStatusCode(s: []const u8) ?u16 {
    if (s.len != 3) return null;
    var code: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        code = code * 10 + (c - '0');
    }
    return code;
}

fn indexOf(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn parseContentLength(s: []const u8) ?usize {
    var result: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') {
            if (c == ' ' or c == '\t') continue; // Skip whitespace
            return null;
        }
        result = result * 10 + (c - '0');
    }
    return result;
}

//------------------------------------------------------------------------------
// Chunked Transfer Decoding
//------------------------------------------------------------------------------

pub const ChunkError = error{
    InvalidChunk,
    IncompleteChunk,
    BufferTooSmall,
};

/// Decode chunked transfer encoding in-place.
/// Returns the decoded length.
pub fn decodeChunked(buf: []u8) ChunkError!usize {
    var read_pos: usize = 0;
    var write_pos: usize = 0;

    while (read_pos < buf.len) {
        // Parse chunk size (hex)
        const size_end = findLineEndFrom(buf, read_pos) orelse return ChunkError.IncompleteChunk;
        const chunk_size = parseHex(buf[read_pos..size_end]) orelse return ChunkError.InvalidChunk;

        read_pos = size_end + 2; // Skip \r\n

        if (chunk_size == 0) {
            // Final chunk
            break;
        }

        // Check we have enough data
        if (read_pos + chunk_size + 2 > buf.len) return ChunkError.IncompleteChunk;

        // Copy chunk data
        if (write_pos + chunk_size > buf.len) return ChunkError.BufferTooSmall;

        // Move data down if needed
        if (write_pos != read_pos) {
            var i: usize = 0;
            while (i < chunk_size) : (i += 1) {
                buf[write_pos + i] = buf[read_pos + i];
            }
        }

        write_pos += chunk_size;
        read_pos += chunk_size + 2; // Skip chunk data + \r\n
    }

    return write_pos;
}

fn parseHex(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var result: usize = 0;
    for (s) |c| {
        const digit: usize = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else if (c == ' ' or c == '\t')
            continue
        else
            return null;
        result = result * 16 + digit;
    }
    return result;
}

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
        const socket = net.connect(ip, url.port, .tcp, self.options.connect_timeout_ms) catch |err| {
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

        // Send request
        _ = net.send(socket, request_buf[0..request_len], 0) catch {
            net.close(socket);
            return ClientError.SendFailed;
        };

        // Receive response
        var total_received: usize = 0;
        var attempts: u32 = 0;
        const max_attempts: u32 = 500;

        while (attempts < max_attempts and total_received < recv_buf.len) : (attempts += 1) {
            const received = net.recv(
                socket,
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
                net.close(socket);
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

        net.close(socket);

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
