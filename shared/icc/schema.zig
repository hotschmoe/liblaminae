const std = @import("std");

/// Describes a single IPC message ID.
pub const Message = struct {
    id: u16,
    name: []const u8,
    direction: []const u8,
    desc: []const u8 = "",
};

/// Main IPC Message Structure (256 bytes)
/// Must match kernel ABI.
pub const IccMessage = extern struct {
    source_id: u16,
    msg_type: u16,
    flags: u32,
    payload: [248]u8,
};

/// Group of related messages sharing an ID range.
pub const MessageRange = struct {
    name: []const u8,
    start: u16,
    end: u16,
    desc: []const u8,
    messages: []const Message = &.{},
};

/// Canonical IPC schema (message ID allocation)
pub const ranges = [_]MessageRange{
    .{
        .name = "ICC Demo (ping/pong)",
        .start = 1,
        .end = 2,
        .desc = "Sample messages used by icc_ping/icc_pong examples.",
        .messages = &.{
            .{ .id = 1, .name = "PING", .direction = "app -> peer", .desc = "Ping request" },
            .{ .id = 2, .name = "PONG", .direction = "peer -> app", .desc = "Ping response" },
        },
    },
    .{
        .name = "net.driver <-> net.stack",
        .start = 0x1000,
        .end = 0x1006,
        .desc = "Raw Ethernet flow and link control between network driver and stack.",
        .messages = &.{
            .{ .id = 0x1000, .name = "RX_PACKET", .direction = "net.driver -> net.stack", .desc = "RX frame delivered to stack" },
            .{ .id = 0x1001, .name = "TX_PACKET", .direction = "net.stack -> net.driver", .desc = "TX frame request from stack" },
            .{ .id = 0x1002, .name = "LINK_STATUS", .direction = "net.driver -> net.stack", .desc = "Link up/down notification" },
            .{ .id = 0x1003, .name = "GET_MAC", .direction = "net.stack -> net.driver", .desc = "Request MAC address" },
            .{ .id = 0x1004, .name = "MAC_RESPONSE", .direction = "net.driver -> net.stack", .desc = "MAC address reply" },
            .{ .id = 0x1005, .name = "REGISTER", .direction = "net.stack -> net.driver", .desc = "Register stack with driver" },
            .{ .id = 0x1006, .name = "REGISTER_ACK", .direction = "net.driver -> net.stack", .desc = "Ack registration + MAC" },
        },
    },
    .{
        .name = "Shared network buffers (SHM)",
        .start = 0x1010,
        .end = 0x1013,
        .desc = "Handshake and queue notifications for shared RX/TX buffers.",
        .messages = &.{
            .{ .id = 0x1010, .name = "SHM_HANDLE", .direction = "net.driver -> net.stack", .desc = "Shared memory handle for ring" },
            .{ .id = 0x1011, .name = "SHM_ATTACHED", .direction = "net.stack -> net.driver", .desc = "Stack attached to shared memory" },
            .{ .id = 0x1012, .name = "SHM_RX_READY", .direction = "net.driver -> net.stack", .desc = "New RX packets available" },
            .{ .id = 0x1013, .name = "SHM_TX_READY", .direction = "net.stack -> net.driver", .desc = "New TX packets available" },
        },
    },
    .{
        .name = "Socket API (app <-> net.stack)",
        .start = 0x2000,
        .end = 0x2047,
        .desc = "Socket-like API bridged over ICC. See net_stack_protocol.zig for full spec.",
        .messages = &.{
            .{ .id = 0x2000, .name = "CONNECT", .direction = "app -> net.stack", .desc = "Connect request" },
            .{ .id = 0x2001, .name = "CONNECT_RESULT", .direction = "net.stack -> app", .desc = "Connect response" },
            .{ .id = 0x2002, .name = "SEND", .direction = "app -> net.stack", .desc = "Send data" },
            .{ .id = 0x2003, .name = "SEND_RESULT", .direction = "net.stack -> app", .desc = "Send completion" },
            .{ .id = 0x2004, .name = "RECV", .direction = "app -> net.stack", .desc = "Receive request" },
            .{ .id = 0x2005, .name = "RECV_RESULT", .direction = "net.stack -> app", .desc = "Receive response + data" },
            .{ .id = 0x2006, .name = "CLOSE", .direction = "app -> net.stack", .desc = "Close socket" },
            .{ .id = 0x2007, .name = "CLOSE_RESULT", .direction = "net.stack -> app", .desc = "Close response" },
            .{ .id = 0x2008, .name = "BIND", .direction = "app -> net.stack", .desc = "Bind local port" },
            .{ .id = 0x2009, .name = "BIND_RESULT", .direction = "net.stack -> app", .desc = "Bind response" },
            .{ .id = 0x200A, .name = "LISTEN", .direction = "app -> net.stack", .desc = "Listen request" },
            .{ .id = 0x200B, .name = "LISTEN_RESULT", .direction = "net.stack -> app", .desc = "Listen response" },
            .{ .id = 0x200C, .name = "ACCEPT", .direction = "app -> net.stack", .desc = "Accept connection" },
            .{ .id = 0x200D, .name = "ACCEPT_RESULT", .direction = "net.stack -> app", .desc = "Accept response" },
            .{ .id = 0x2010, .name = "DNS_RESOLVE", .direction = "app -> net.stack", .desc = "Resolve hostname" },
            .{ .id = 0x2011, .name = "DNS_RESULT", .direction = "net.stack -> app", .desc = "DNS response" },
            .{ .id = 0x2020, .name = "GET_STATUS", .direction = "app -> net.stack", .desc = "Query socket status" },
            .{ .id = 0x2021, .name = "STATUS_RESULT", .direction = "net.stack -> app", .desc = "Socket status response" },
            .{ .id = 0x2030, .name = "PING", .direction = "app -> net.stack", .desc = "ICMP ping to specific IP" },
            .{ .id = 0x2031, .name = "PING_RESULT", .direction = "net.stack -> app", .desc = "ICMP ping result" },
            // Abstract operations - stack uses internal config
            .{ .id = 0x2040, .name = "PING_GATEWAY", .direction = "app -> net.stack", .desc = "Ping stack's gateway" },
            .{ .id = 0x2041, .name = "PING_GATEWAY_RESULT", .direction = "net.stack -> app", .desc = "Gateway ping result" },
            .{ .id = 0x2042, .name = "TEST_DNS", .direction = "app -> net.stack", .desc = "Test DNS connectivity" },
            .{ .id = 0x2043, .name = "TEST_DNS_RESULT", .direction = "net.stack -> app", .desc = "DNS test result" },
            .{ .id = 0x2044, .name = "GET_CONFIG", .direction = "app -> net.stack", .desc = "Query network config" },
            .{ .id = 0x2045, .name = "CONFIG_RESULT", .direction = "net.stack -> app", .desc = "Network config response" },
            .{ .id = 0x2046, .name = "TEST_CONNECTIVITY", .direction = "app -> net.stack", .desc = "Test overall connectivity" },
            .{ .id = 0x2047, .name = "TEST_CONNECTIVITY_RESULT", .direction = "net.stack -> app", .desc = "Connectivity result" },
        },
    },
    .{
        .name = "Block I/O (app <-> blk.driver)",
        .start = 0x3000,
        .end = 0x3005,
        .desc = "Block device read/write operations.",
        .messages = &.{
            .{ .id = 0x3000, .name = "READ_REQUEST", .direction = "app -> blk.driver", .desc = "Read sector request" },
            .{ .id = 0x3001, .name = "READ_RESPONSE", .direction = "blk.driver -> app", .desc = "Read sector response" },
            .{ .id = 0x3002, .name = "WRITE_REQUEST", .direction = "app -> blk.driver", .desc = "Write sector request" },
            .{ .id = 0x3003, .name = "WRITE_RESPONSE", .direction = "blk.driver -> app", .desc = "Write sector response" },
            .{ .id = 0x3004, .name = "GET_INFO", .direction = "app -> blk.driver", .desc = "Query device info" },
            .{ .id = 0x3005, .name = "INFO_RESPONSE", .direction = "blk.driver -> app", .desc = "Device info response" },
        },
    },
    .{
        .name = "Platform Services (driver <-> platform)",
        .start = 0x4000,
        .end = 0x4035,
        .desc = "Platform container services for clock/power/reset control and board info.",
        .messages = &.{
            // Clock control (0x4000-0x4004)
            .{ .id = 0x4000, .name = "ENABLE_CLOCK", .direction = "driver -> platform", .desc = "Request clock enable" },
            .{ .id = 0x4001, .name = "ENABLE_CLOCK_OK", .direction = "platform -> driver", .desc = "Clock enabled successfully" },
            .{ .id = 0x4002, .name = "ENABLE_CLOCK_FAIL", .direction = "platform -> driver", .desc = "Clock enable failed" },
            .{ .id = 0x4003, .name = "DISABLE_CLOCK", .direction = "driver -> platform", .desc = "Request clock disable" },
            .{ .id = 0x4004, .name = "DISABLE_CLOCK_OK", .direction = "platform -> driver", .desc = "Clock disabled successfully" },
            // Reset control (0x4005-0x4009)
            .{ .id = 0x4005, .name = "DEASSERT_RESET", .direction = "driver -> platform", .desc = "Request reset deassert (enable device)" },
            .{ .id = 0x4006, .name = "DEASSERT_RESET_OK", .direction = "platform -> driver", .desc = "Reset deasserted successfully" },
            .{ .id = 0x4007, .name = "DEASSERT_RESET_FAIL", .direction = "platform -> driver", .desc = "Reset deassert failed" },
            .{ .id = 0x4008, .name = "ASSERT_RESET", .direction = "driver -> platform", .desc = "Request reset assert (disable device)" },
            .{ .id = 0x4009, .name = "ASSERT_RESET_OK", .direction = "platform -> driver", .desc = "Reset asserted successfully" },
            // Power domain control (0x4010-0x4014)
            .{ .id = 0x4010, .name = "ENABLE_POWER", .direction = "driver -> platform", .desc = "Request power domain enable" },
            .{ .id = 0x4011, .name = "ENABLE_POWER_OK", .direction = "platform -> driver", .desc = "Power domain enabled" },
            .{ .id = 0x4012, .name = "ENABLE_POWER_FAIL", .direction = "platform -> driver", .desc = "Power domain enable failed" },
            .{ .id = 0x4013, .name = "DISABLE_POWER", .direction = "driver -> platform", .desc = "Request power domain disable" },
            .{ .id = 0x4014, .name = "DISABLE_POWER_OK", .direction = "platform -> driver", .desc = "Power domain disabled" },
            // Board info (0x4020-0x4035)
            .{ .id = 0x4020, .name = "GET_MAC_ADDRESS", .direction = "driver -> platform", .desc = "Request MAC address from OTP/EEPROM" },
            .{ .id = 0x4021, .name = "MAC_ADDRESS_OK", .direction = "platform -> driver", .desc = "MAC address response" },
            .{ .id = 0x4022, .name = "MAC_ADDRESS_FAIL", .direction = "platform -> driver", .desc = "MAC address not available" },
            .{ .id = 0x4030, .name = "GET_BOARD_SERIAL", .direction = "driver -> platform", .desc = "Request board serial number" },
            .{ .id = 0x4031, .name = "BOARD_SERIAL_OK", .direction = "platform -> driver", .desc = "Board serial response" },
            .{ .id = 0x4032, .name = "GET_BOARD_REVISION", .direction = "driver -> platform", .desc = "Request board revision" },
            .{ .id = 0x4033, .name = "BOARD_REVISION_OK", .direction = "platform -> driver", .desc = "Board revision response" },
            .{ .id = 0x4034, .name = "SET_CLOCK_RATE", .direction = "driver -> platform", .desc = "Set clock rate (Hz)" },
            .{ .id = 0x4035, .name = "SET_CLOCK_RATE_OK", .direction = "platform -> driver", .desc = "Clock rate set successfully" },
        },
    },
};

/// Find a message description by ID (linear scan, small table)
pub fn findMessage(id: u16) ?Message {
    for (ranges) |range| {
        if (id < range.start or id > range.end) continue;
        for (range.messages) |msg| {
            if (msg.id == id) return msg;
        }
    }
    return null;
}
