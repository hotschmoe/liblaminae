//------------------------------------------------------------------------------
// Network Protocol Constants - Single Source of Truth
//
// This file exports the message types for driver <-> network stack communication.
// These values come from src/shared/ipc/schema.zig and should be used by:
// - genetd, netd (network drivers)
// - c_lwIP (network stack)
//
// Usage:
//   const lib = @import("liblaminae");
//   const NetMsgType = lib.net_protocol.NetMsgType;
//   msg.msg_type = NetMsgType.REGISTER;
//------------------------------------------------------------------------------

/// Network driver <-> stack message types (0x1000-0x1006)
pub const NetMsgType = struct {
    /// RX frame delivered to stack
    pub const RX_PACKET: u16 = 0x1000;
    /// TX frame request from stack
    pub const TX_PACKET: u16 = 0x1001;
    /// Link up/down notification
    pub const LINK_STATUS: u16 = 0x1002;
    /// Request MAC address
    pub const GET_MAC: u16 = 0x1003;
    /// MAC address reply
    pub const MAC_RESPONSE: u16 = 0x1004;
    /// Register stack with driver
    pub const REGISTER: u16 = 0x1005;
    /// Ack registration + MAC
    pub const REGISTER_ACK: u16 = 0x1006;
};

/// Shared memory message types (0x1010-0x1013)
pub const ShmMsgType = struct {
    /// Shared memory handle for ring
    pub const SHM_HANDLE: u16 = 0x1010;
    /// Stack attached to shared memory
    pub const SHM_ATTACHED: u16 = 0x1011;
    /// New RX packets available
    pub const SHM_RX_READY: u16 = 0x1012;
    /// New TX packets available
    pub const SHM_TX_READY: u16 = 0x1013;
};

/// IPC timeout constants
pub const Timeout = struct {
    /// Non-blocking: return immediately if no message
    pub const NON_BLOCKING: u64 = 0;
    /// Infinite: block until message arrives
    pub const INFINITE: u64 = 0xFFFFFFFFFFFFFFFF;
};
