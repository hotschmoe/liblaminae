//------------------------------------------------------------------------------
// Sensitive-contract table (the_law T6)
//
// A contract hash in this set requires elevated consent to wire. v1: only
// lamina (CID 1, the sole CAP_WIRE holder and consent broker) may chan_wire
// a sensitive hash. Adding a contract later is a data edit here, not a new
// interpreter in EL1.
//
// Import: named `net_stack_protocol` (build.zig maps it for kernel and
// liblaminae). Relative-importing the protocol file would double-claim it
// against the existing named module.
//------------------------------------------------------------------------------

const net_stack = @import("net_stack_protocol");

/// Contract hashes that require CID-1 consent to wire.
pub const hashes = [_]u64{
    net_stack.CONTRACT_HASH,
};

pub fn isSensitive(hash: u64) bool {
    for (hashes) |h| {
        if (h == hash) return true;
    }
    return false;
}
