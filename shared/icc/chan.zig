//------------------------------------------------------------------------------
// Channel control-plane shared types (channel_contract.md Section 7.5 / 10.4)
//
// Auto-synced to lib/shared/icc/chan.zig by `zig build gen-lib`. Import-free,
// ASCII only.
//------------------------------------------------------------------------------

/// chan_recv outcome, returned in x0. The discriminating datum rides in x1
/// (packed gen-qualified sender CellId for `message`, dead peer CellId for
/// `peer_closed`). Both values
/// are small positive integers below ERROR_BASE (0xFFFF_FFFF_0000_0000), so
/// they can never collide with the kernel error codes that share the x0
/// channel (contract 10.4). The open `_` tag reserves room for future
/// outcomes without an ABI break.
pub const ChanRecvOutcome = enum(u64) {
    message = 0,
    peer_closed = 1,
    _,
};

/// wait_event `flags` bit 0 (channel_contract.md 15.6): the caller passes an
/// endpoint-token vector in x4 (pointer) / x5 (count) to multi-wait on its
/// held in-endpoints. Callers that leave the bit clear get the legacy
/// 4-register form -- x4/x5 are never read, so old wrappers stay valid.
pub const WAIT_FLAG_CHAN_ARM: u64 = 1;

//------------------------------------------------------------------------------
// Channel wiring-provenance ABI (channel_contract.md LAW 2 -- provenance query)
//
// The wire format returned by the `chan_snapshot` syscall (139), the endpoint
// analog of `lease_snapshot`. LAW 2 wants wiring provenance queryable: an
// endpoint records WHO wired it (`wired_by`) and WHICH chan_create pair it
// belongs to (`pair_id`); this snapshot makes those observable. Read-only,
// keyed by (generation-qualified) holder CID.
//------------------------------------------------------------------------------

/// The uniform per-cell endpoint cap (channel_contract.md 15.7). EXACT, not a
/// view truncation: the kernel enforces it at chan_create/chan_grant/spawn-fold,
/// the death-walk wake buffer and EndpointSnapshot are sized to it, so death
/// notification and discovery are lossless for every cell -- no per-cell
/// exemption, ever. 32 = L4 provider fanout (~16 clients at 2 endpoints each,
/// 15.8) with orchestrator headroom.
pub const MAX_ENDPOINTS_PER_CELL: usize = 32;

/// Pair-local SHM grant table (T5 / channel_contract 12.3). Exact: one
/// net.stack pair can carry 8 sockets * 2 regions. Index is not authority;
/// holdership of the endpoint is.
pub const MAX_REGION_GRANTS: usize = 16;

/// One endpoint as seen by a provenance observer. Cell identities are packed
/// CellIds (raw | generation<<16), matching the chan syscalls' wire format; the
/// INVALID sentinel is raw=0, generation=0xFFFF (0xFFFF0000).
pub const EndpointView = extern struct {
    /// (slot | generation<<16) token naming THIS endpoint -- the chan_wire name.
    token: u32,
    /// The chan_create pair this endpoint belongs to (LAW 2 provenance).
    pair_id: u32,
    /// Contract hash the pair was created under.
    contract_hash: u64,
    /// Packed CellId of the cell that performed wire() (LAW 2 provenance).
    /// INVALID until the endpoint is wired.
    wired_by: u32,
    /// Packed CellId of the current peer holder when state==wired; INVALID
    /// otherwise. Resolves "who am I wired to right now."
    peer_holder: u32,
    /// Packed CellId of the departed peer; set ONLY when state==peer_closed.
    closed_peer: u32,
    /// 0 = out, 1 = in (Direction).
    direction: u8,
    /// 0 = unwired, 1 = wired, 2 = peer_closed (EpState).
    state: u8,
    /// Contract version the pair was created under.
    version: u16,
};

/// The full snapshot buffer the caller supplies via out-pointer. `count`
/// populated entries (<= MAX_ENDPOINTS_PER_CELL) follow.
pub const EndpointSnapshot = extern struct {
    /// Number of populated entries.
    count: u32,
    _pad: u32 = 0,
    entries: [MAX_ENDPOINTS_PER_CELL]EndpointView,
};
