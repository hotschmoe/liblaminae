//------------------------------------------------------------------------------
// Net Driver Protocol -- the netd <-> net.stack control plane (L4)
//------------------------------------------------------------------------------
//
// Single source of truth for the net-driver control messages that ride the
// net.driver channel bundle (channel_contract.md 15.2). Formalizes the
// previously ad-hoc 0x1000-range constants (src/shared/icc/schema.zig) into
// Method specs so the contract has a CONTRACT_HASH the wire-time check
// (CH.5) can enforce. Bulk frame data rides the SHM ring data plane
// (lib/man/net_shm.zig), never these messages.
//
// Import-free by design except the one allowed leaf import (`contract`),
// mirroring the sibling protocol modules.
//
//------------------------------------------------------------------------------

const contract = @import("contract");

/// Mailbox/channel payload size. Mirrors schema.zig PAYLOAD_SIZE; lib/root.zig
/// asserts the mirror.
pub const PAYLOAD_SIZE = 248;

/// Contract namespace (the old ns_register name, kept as the manifest key).
pub const NAMESPACE: []const u8 = "net.driver";

pub const CONTRACT_VERSION: u16 = 2;

/// Message type constants -- the historical 0x1000 range verbatim.
pub const NetDrvMsgType = struct {
    pub const RX_PACKET: u16 = 0x1000;
    pub const TX_PACKET: u16 = 0x1001;
    pub const LINK_STATUS: u16 = 0x1002;
    pub const GET_MAC: u16 = 0x1003;
    pub const MAC_RESPONSE: u16 = 0x1004;
    pub const REGISTER: u16 = 0x1005;
    pub const REGISTER_ACK: u16 = 0x1006;
};

//------------------------------------------------------------------------------
// Method specs (rpc.call / channel.call shape)
//------------------------------------------------------------------------------

/// Stack registers with the driver; the ack carries the MAC and (when the
/// driver owns an SHM data-plane region) the pair-local grant_ref at byte 8.
pub const Register = struct {
    pub const REQ_TYPE: u16 = NetDrvMsgType.REGISTER;
    pub const REPLY_TYPE: u16 = NetDrvMsgType.REGISTER_ACK;

    pub const Request = extern struct { _reserved: u8 = 0 };
    pub const Reply = extern struct { mac: [6]u8, _pad: [2]u8 = .{ 0, 0 }, grant_ref: u32 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        _ = req;
        _ = payload;
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{
            .mac = payload[0..6].*,
            .grant_ref = @bitCast(payload[8..12].*),
        };
    }
};

/// MAC query (kept for parity with the historical surface).
pub const GetMac = struct {
    pub const REQ_TYPE: u16 = NetDrvMsgType.GET_MAC;
    pub const REPLY_TYPE: u16 = NetDrvMsgType.MAC_RESPONSE;

    pub const Request = extern struct { _reserved: u8 = 0 };
    pub const Reply = extern struct { mac: [6]u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        _ = req;
        _ = payload;
    }

    pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
        return .{ .mac = payload[0..6].* };
    }
};

/// TX frame notification (cast-only; the frame bytes ride the SHM plane,
/// the legacy inline form carries len + bytes in the payload).
pub const TxPacket = struct {
    pub const REQ_TYPE: u16 = NetDrvMsgType.TX_PACKET;

    pub const Request = extern struct { len: u16 };
    pub const WireRequest = extern struct { len: u16, data: [246]u8 };

    pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
        @as(*align(1) u16, @ptrCast(&payload[0])).* = req.len;
    }
};

pub const SPECS = .{ Register, GetMac, TxPacket };

pub const CONTRACT_HASH: u64 = contract.hashSpecs(SPECS, NAMESPACE, CONTRACT_VERSION);
