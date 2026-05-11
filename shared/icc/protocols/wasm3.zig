//------------------------------------------------------------------------------
// Wasm3 Driver Protocol -- Method specs for `lib/wasm_client/`
//------------------------------------------------------------------------------
//
// Single source of truth for the wasm3 runtime container's ICC message
// format. The client lib (`lib/wasm_client/api.zig`) imports this; the
// driver (`user/drivers/wasm3_runtime/main.zig`) imports this; no one else.
//
// Message-type allocation: 0x5000-0x5091. Moved up from the original
// 0x3000-0x3091 range because that range was numerically claimed by both
// blk.driver (0x3000-0x3005) and lamina init (0x3000-0x300B). Wasm3
// doesn't runtime-collide with either (peer ID selects the receiver), but
// keeping a unique numeric range makes `src/shared/icc/schema.zig` honest
// and removes a future "find a free number" footgun.
//
// Reply layout: every reply carries a 1-byte `Status` at payload[0]
// (0 = ok, 1 = err) followed by a NUL-terminated message/output string
// from payload[1..]. This collapses what used to be two reply tags per
// request (LOAD_OK/LOAD_ERR, CALL_OK/CALL_ERR) into one, so the generic
// `rpc.call` -- which assumes a single REPLY_TYPE per request -- can
// drive the wasm3 client like every other peer.
//
//------------------------------------------------------------------------------

/// Default service name. The shell's `wasm <path>` command and `test_wasm3`
/// look this up; daemonized instances re-register under different names
/// via `SetName`.
pub const NAMESPACE: []const u8 = "wasm_prime";

/// Message type constants. Kept as a flat namespace so the driver's dispatch
/// switch can use `WasmMsgType.LOAD_MODULE`, etc.
pub const WasmMsgType = struct {
    pub const LOAD_MODULE: u16 = 0x5000;
    pub const LOAD_RESULT: u16 = 0x5001;

    pub const CALL_FUNC: u16 = 0x5010;
    pub const CALL_RESULT: u16 = 0x5011;

    pub const UNLOAD: u16 = 0x5020;

    pub const SET_NAME: u16 = 0x5030;
    pub const SET_NAME_OK: u16 = 0x5031;

    pub const PING: u16 = 0x5090;
    pub const PONG: u16 = 0x5091;
};

/// Reply status discriminant. Always at payload[0] for LOAD_RESULT / CALL_RESULT.
pub const Status = enum(u8) {
    ok = 0,
    err = 1,
};

/// Maximum bytes of payload string (path / func name) in a request -- the
/// mailbox payload is 248 bytes; cap at 247 to leave a NUL terminator slot
/// when caller code wants to treat it as a C string.
pub const MAX_PAYLOAD_STR: usize = 247;

/// Maximum bytes of message/output string in a reply. Status occupies
/// payload[0], so the message body has one less byte than a request.
pub const MAX_REPLY_STR: usize = 246;

inline fn writeString(payload: *[248]u8, s: []const u8) void {
    const n = @min(s.len, MAX_PAYLOAD_STR);
    @memcpy(payload[0..n], s[0..n]);
}

/// Encode a Status + NUL-terminated body into a reply payload.
/// Used by the wasm3 driver; clients use the matching `Reply.message()` /
/// `Reply.output()` accessors to decode.
pub fn writeReply(payload: *[248]u8, status: Status, body: []const u8) void {
    @memset(payload, 0);
    payload[0] = @intFromEnum(status);
    const n = @min(body.len, MAX_REPLY_STR);
    @memcpy(payload[1 .. 1 + n], body[0..n]);
}

/// Extract a NUL-trimmed string starting at `offset` from a payload.
fn extractStringAt(payload: *const [248]u8, comptime offset: usize) []const u8 {
    var len: usize = 0;
    const max = 248 - offset;
    while (len < max and payload[offset + len] != 0) : (len += 1) {}
    return payload[offset .. offset + len];
}

/// Extract a NUL-trimmed string from offset 0 of a payload. Used for
/// request payloads (path, func name) that don't carry a status byte.
pub fn extractString(payload: *const [248]u8) []const u8 {
    return extractStringAt(payload, 0);
}

/// Decode the status byte at payload[0]. Any value other than 0 maps to
/// `.err` so a corrupted byte never tips into an out-of-enum panic.
inline fn decodeStatus(b: u8) Status {
    return if (b == @intFromEnum(Status.ok)) .ok else .err;
}

//------------------------------------------------------------------------------
// Method specs
//
// LoadModule / CallFunc replies share one REPLY_TYPE each (LOAD_RESULT /
// CALL_RESULT). The Reply carries a status byte plus an NUL-terminated body
// (error message for LOAD, captured stdout for CALL). The full 248-byte
// payload rides inside the Reply so accessor methods can return slices that
// outlive the underlying mailbox buffer.
//------------------------------------------------------------------------------

pub const LoadReply = struct {
    status: Status,
    payload: [248]u8,

    /// NUL-trimmed message body. Empty on success; error string on failure.
    pub fn message(self: *const LoadReply) []const u8 {
        return extractStringAt(&self.payload, 1);
    }
};

pub const LoadModule = struct {
    pub const REQ_TYPE: u16 = WasmMsgType.LOAD_MODULE;
    pub const REPLY_TYPE: u16 = WasmMsgType.LOAD_RESULT;
    pub const Request = struct { path: []const u8 };
    pub const Reply = LoadReply;
    pub fn serialize(req: Request, payload: *[248]u8) void {
        writeString(payload, req.path);
    }
    pub fn deserialize(payload: *const [248]u8) Reply {
        return .{ .status = decodeStatus(payload[0]), .payload = payload.* };
    }
};

pub const CallReply = struct {
    status: Status,
    payload: [248]u8,

    /// NUL-trimmed captured stdout. Empty on err or when the program
    /// produced no output.
    pub fn output(self: *const CallReply) []const u8 {
        return extractStringAt(&self.payload, 1);
    }
};

pub const CallFunc = struct {
    pub const REQ_TYPE: u16 = WasmMsgType.CALL_FUNC;
    pub const REPLY_TYPE: u16 = WasmMsgType.CALL_RESULT;
    pub const Request = struct { name: []const u8 };
    pub const Reply = CallReply;
    pub fn serialize(req: Request, payload: *[248]u8) void {
        writeString(payload, req.name);
    }
    pub fn deserialize(payload: *const [248]u8) Reply {
        return .{ .status = decodeStatus(payload[0]), .payload = payload.* };
    }
};

pub const SetName = struct {
    pub const REQ_TYPE: u16 = WasmMsgType.SET_NAME;
    pub const REPLY_TYPE: u16 = WasmMsgType.SET_NAME_OK;
    pub const Request = struct { name: []const u8 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, payload: *[248]u8) void {
        writeString(payload, req.name);
    }
    pub fn deserialize(_: *const [248]u8) Reply {
        return .{};
    }
};

pub const Ping = struct {
    pub const REQ_TYPE: u16 = WasmMsgType.PING;
    pub const REPLY_TYPE: u16 = WasmMsgType.PONG;
    pub const Request = struct {};
    pub const Reply = struct {};
    pub fn serialize(_: Request, _: *[248]u8) void {}
    pub fn deserialize(_: *const [248]u8) Reply {
        return .{};
    }
};

pub const Unload = struct {
    pub const REQ_TYPE: u16 = WasmMsgType.UNLOAD;
    pub const Request = struct {};
    pub fn serialize(_: Request, _: *[248]u8) void {}
};
