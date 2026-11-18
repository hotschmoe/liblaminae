//------------------------------------------------------------------------------
// Lease telemetry ABI (lease_contract.md Section 11)
//
// The wire format returned by the `lease_snapshot` syscall (128). Lives in
// src/shared/ so it is a SINGLE source of truth: the kernel builds these
// structs, and gen-lib re-exports them into lib/gen/syscalls.zig so userspace
// decodes the identical layout. No kernel imports here -- both sides include
// this file directly.
//
// This is the OBSERVABILITY surface for the device-lease registry
// (src/kernel/icc/leases.zig). B6.1 records leases; B6.2 (this ABI) makes them
// visible; B6.3 will add the reclaim state walk these fields already encode.
//------------------------------------------------------------------------------

/// Cap on the per-cell lease count a single snapshot returns (bounds the
/// extern struct). A driver holds ~3-5 leases; 8 covers it with headroom.
/// Excess leases still exist in the registry -- only the snapshot view
/// truncates (lease_contract.md Section 5, MAX_LEASES_PER_CELL).
pub const MAX_LEASES_PER_CELL: usize = 8;

/// One lease as seen by an observer. `kind` and `state` are the numeric
/// encodings of the kernel's LeaseKind / LeaseState enums; `holder_gen` lets a
/// caller that only had a raw CID still disambiguate generations
/// (lease_contract.md finding 4).
pub const LeaseView = extern struct {
    /// 0 = mmio, 1 = irq, 2 = dma (LeaseKind).
    kind: u8,
    /// 0 = free, 1 = held, 2 = revoking, 3 = fenced, 4 = reusable (LeaseState).
    state: u8,
    /// Holder cell generation (finding 4 disambiguation).
    holder_gen: u16,
    _pad: u32 = 0,
    /// By kind: mmio -> phys_base, irq -> irq_num, dma -> byte length.
    detail: u64,
};

/// The full snapshot buffer the caller supplies via out-pointer. `count`
/// populated entries (<= MAX_LEASES_PER_CELL) follow.
pub const LeaseSnapshot = extern struct {
    /// Number of populated entries.
    count: u32,
    _pad: u32 = 0,
    entries: [MAX_LEASES_PER_CELL]LeaseView,
};
