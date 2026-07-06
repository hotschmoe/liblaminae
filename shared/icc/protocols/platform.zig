//------------------------------------------------------------------------------
// Platform Container Protocol — Method specs for `lib/platform_client/`
//------------------------------------------------------------------------------
//
// Single source of truth for the platform container's ICC message format
// (clock / power / reset / board-info ops in the 0x4000-0x4035 range).
//
// Closes the C8.12 follow-up: before this file, the same constants were
// declared in three places — `lib/man/platform.zig`, `user/platforms/virt.zig`,
// and `src/shared/icc/schema.zig`'s metadata table. This module is now the
// canonical source; both the client lib (`lib/platform_client/api.zig`) and
// the server (`user/platforms/virt.zig`) import from here. The schema.zig
// metadata table stays as descriptive registry-of-ranges (it's not the
// authority on individual constants).
//
//------------------------------------------------------------------------------

/// Mailbox payload size. Mirrors `src/shared/icc/schema.zig` PAYLOAD_SIZE --
/// this module is import-free by design; lib/root.zig asserts the mirror.
pub const PAYLOAD_SIZE = 248;

/// Namespace name registered by the platform container at boot.
/// The client looks this up via `ns_lookup` to discover the peer ID.
pub const NAMESPACE: []const u8 = "platform";

/// Message type constants. Kept as a flat namespace so server-side
/// dispatch can use `PlatformMsgType.ENABLE_CLOCK`, etc.
pub const PlatformMsgType = struct {
    // Clock control (0x4000-0x4004)
    pub const ENABLE_CLOCK: u16 = 0x4000;
    pub const ENABLE_CLOCK_OK: u16 = 0x4001;
    pub const ENABLE_CLOCK_FAIL: u16 = 0x4002;
    pub const DISABLE_CLOCK: u16 = 0x4003;
    pub const DISABLE_CLOCK_OK: u16 = 0x4004;

    // Reset control (0x4005-0x4009)
    pub const DEASSERT_RESET: u16 = 0x4005;
    pub const DEASSERT_RESET_OK: u16 = 0x4006;
    pub const DEASSERT_RESET_FAIL: u16 = 0x4007;
    pub const ASSERT_RESET: u16 = 0x4008;
    pub const ASSERT_RESET_OK: u16 = 0x4009;

    // Power domain control (0x4010-0x4014)
    pub const ENABLE_POWER: u16 = 0x4010;
    pub const ENABLE_POWER_OK: u16 = 0x4011;
    pub const ENABLE_POWER_FAIL: u16 = 0x4012;
    pub const DISABLE_POWER: u16 = 0x4013;
    pub const DISABLE_POWER_OK: u16 = 0x4014;

    // Board info (0x4020-0x4035)
    pub const GET_MAC_ADDRESS: u16 = 0x4020;
    pub const MAC_ADDRESS_OK: u16 = 0x4021;
    pub const MAC_ADDRESS_FAIL: u16 = 0x4022;
    pub const GET_BOARD_SERIAL: u16 = 0x4030;
    pub const BOARD_SERIAL_OK: u16 = 0x4031;
    pub const GET_BOARD_REVISION: u16 = 0x4032;
    pub const BOARD_REVISION_OK: u16 = 0x4033;
    pub const SET_CLOCK_RATE: u16 = 0x4034;
    pub const SET_CLOCK_RATE_OK: u16 = 0x4035;
};

//------------------------------------------------------------------------------
// Method specs
//
// Most platform ops follow an identical shape: send a u32 ID, get back a
// "_OK" reply discriminated only by msg_type. The repetition is intentional
// — each spec stays Zig-idiomatic and discoverable, and a future op with a
// different payload doesn't have to wrestle with a meta-template.
//------------------------------------------------------------------------------

/// Helper: encode a u32 ID at payload offset 0.
fn writeU32(payload: *[PAYLOAD_SIZE]u8, value: u32) void {
    @as(*align(1) u32, @ptrCast(&payload[0])).* = value;
}

pub const EnableClock = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.ENABLE_CLOCK;
    pub const REPLY_TYPE: u16 = PlatformMsgType.ENABLE_CLOCK_OK;
    pub const Request = struct { clock_id: u32 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, p: *[PAYLOAD_SIZE]u8) void {
        writeU32(p, req.clock_id);
    }
    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

pub const DisableClock = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.DISABLE_CLOCK;
    pub const REPLY_TYPE: u16 = PlatformMsgType.DISABLE_CLOCK_OK;
    pub const Request = struct { clock_id: u32 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, p: *[PAYLOAD_SIZE]u8) void {
        writeU32(p, req.clock_id);
    }
    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

pub const DeassertReset = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.DEASSERT_RESET;
    pub const REPLY_TYPE: u16 = PlatformMsgType.DEASSERT_RESET_OK;
    pub const Request = struct { reset_id: u32 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, p: *[PAYLOAD_SIZE]u8) void {
        writeU32(p, req.reset_id);
    }
    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

pub const AssertReset = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.ASSERT_RESET;
    pub const REPLY_TYPE: u16 = PlatformMsgType.ASSERT_RESET_OK;
    pub const Request = struct { reset_id: u32 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, p: *[PAYLOAD_SIZE]u8) void {
        writeU32(p, req.reset_id);
    }
    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

pub const EnablePower = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.ENABLE_POWER;
    pub const REPLY_TYPE: u16 = PlatformMsgType.ENABLE_POWER_OK;
    pub const Request = struct { power_id: u32 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, p: *[PAYLOAD_SIZE]u8) void {
        writeU32(p, req.power_id);
    }
    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

pub const DisablePower = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.DISABLE_POWER;
    pub const REPLY_TYPE: u16 = PlatformMsgType.DISABLE_POWER_OK;
    pub const Request = struct { power_id: u32 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, p: *[PAYLOAD_SIZE]u8) void {
        writeU32(p, req.power_id);
    }
    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};

pub const GetMac = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.GET_MAC_ADDRESS;
    pub const REPLY_TYPE: u16 = PlatformMsgType.MAC_ADDRESS_OK;
    pub const Request = struct {};
    pub const Reply = struct { mac: [6]u8 };
    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}
    pub fn deserialize(p: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .mac = p[0..6].* };
    }
};

pub const GetBoardSerial = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.GET_BOARD_SERIAL;
    pub const REPLY_TYPE: u16 = PlatformMsgType.BOARD_SERIAL_OK;
    pub const Request = struct {};
    pub const Reply = struct { serial: u64 };
    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}
    pub fn deserialize(p: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .serial = @as(*align(1) const u64, @ptrCast(&p[0])).* };
    }
};

pub const GetBoardRevision = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.GET_BOARD_REVISION;
    pub const REPLY_TYPE: u16 = PlatformMsgType.BOARD_REVISION_OK;
    pub const Request = struct {};
    pub const Reply = struct { revision: u32 };
    pub fn serialize(_: Request, _: *[PAYLOAD_SIZE]u8) void {}
    pub fn deserialize(p: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .revision = @as(*align(1) const u32, @ptrCast(&p[0])).* };
    }
};

pub const SetClockRate = struct {
    pub const REQ_TYPE: u16 = PlatformMsgType.SET_CLOCK_RATE;
    pub const REPLY_TYPE: u16 = PlatformMsgType.SET_CLOCK_RATE_OK;
    pub const Request = struct { clock_id: u32, rate_hz: u64 };
    pub const Reply = struct {};
    pub fn serialize(req: Request, p: *[PAYLOAD_SIZE]u8) void {
        @as(*align(1) u32, @ptrCast(&p[0])).* = req.clock_id;
        @as(*align(1) u64, @ptrCast(&p[4])).* = req.rate_hz;
    }
    pub fn deserialize(_: *const [PAYLOAD_SIZE]u8) Reply {
        return .{};
    }
};
