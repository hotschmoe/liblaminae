//------------------------------------------------------------------------------
// Test Contracts -- channel-plane vocabulary for the regression suites (L4)
//------------------------------------------------------------------------------
//
// Real (non-production) contracts the test programs speak over the channel
// plane, replacing their Break 6 ns_register/icc coordination. Two contracts
// share this module deliberately: each is a single tiny Method spec, and the
// test domain is one domain.
//
//   ShmOwner  ("test.shmowner"): shm_map_owner (child, requires at boot) ->
//             test_shm_owner_death (parent, provides). The child binds its
//             region onto the folded pair and calls Attach with the
//             grant_ref; the parent map_attaches via its end and acks,
//             then the child self-exits to stage the owner-death reclaim (BH2).
//
//   SmpStress ("smp.stress"): smp_stress_peer (worker A, provides) <-
//             smp_stress (worker B, dynamic Connect). Ping/Pong rounds with
//             SIMD probes ride the wired bundle -- the cross-core stress
//             payload itself.
//
// Import-free by design except the one allowed leaf import (`contract`),
// mirroring the sibling protocol modules.
//
//------------------------------------------------------------------------------

const contract = @import("contract");

/// Mailbox/channel payload size. Mirrors schema.zig PAYLOAD_SIZE; lib/root.zig
/// asserts the mirror.
pub const PAYLOAD_SIZE = 248;

pub const ShmOwner = struct {
    pub const NAMESPACE: []const u8 = "test.shmowner";
    pub const CONTRACT_VERSION: u16 = 1;

    /// Child -> parent: "here is my grant_ref; attach and ack."
    pub const Attach = struct {
        pub const REQ_TYPE: u16 = 0x0200;
        pub const REPLY_TYPE: u16 = 0x0201;

        pub const Request = extern struct { grant_ref: u32 };
        pub const Reply = extern struct { ok: u8 };

        pub fn serialize(req: Request, payload: *[PAYLOAD_SIZE]u8) void {
            payload[0..4].* = @bitCast(req.grant_ref);
        }

        pub fn deserialize(payload: *const [PAYLOAD_SIZE]u8) Reply {
            return .{ .ok = payload[0] };
        }

        pub fn serializeReply(reply: Reply, payload: *[PAYLOAD_SIZE]u8) void {
            payload[0] = reply.ok;
        }

        pub fn deserializeRequest(payload: *const [PAYLOAD_SIZE]u8) Request {
            return .{ .grant_ref = @bitCast(payload[0..4].*) };
        }
    };

    pub const CONTRACT_HASH: u64 = contract.hashSpecs(.{Attach}, NAMESPACE, CONTRACT_VERSION);
};

pub const SmpStress = struct {
    pub const NAMESPACE: []const u8 = "smp.stress";
    pub const CONTRACT_VERSION: u16 = 1;

    /// B -> A ping; A -> B pong. `last` tells A to exit after replying.
    /// The tests drive these as raw chan_send/chan_recv messages (the SIMD
    /// probes bracket each syscall), so the payload layout below IS the wire
    /// format: seq at byte 0, last at byte 4.
    pub const Ping = struct {
        pub const REQ_TYPE: u16 = 0x0210;
        pub const REPLY_TYPE: u16 = 0x0211;

        pub const Request = extern struct { seq: u32, last: u8 };
        pub const Reply = extern struct { seq: u32 };
    };

    pub const CONTRACT_HASH: u64 = contract.hashSpecs(.{Ping}, NAMESPACE, CONTRACT_VERSION);
};
