//------------------------------------------------------------------------------
// Ring Event Wrapper -- T1 vocabulary
//
// Typed wrapper over sys_ring_arm + sys_wait_event (consumer) and
// sys_ring_wake (producer) that closes the lost-wake race without
// exposing the raw snapshot protocol to call sites.
//
// Contract reference: docs/architecture/contracts/ring_event_contract.md §8
//
// Usage:
//   var h = RingHandle(u8, 256){ .ring = ring_ptr, .token = tok };
//   h.produce(byte);
//   h.flush(); // or: defer h.flush()
//
//   // Consumer side:
//   try h.waitForData(timeout_ns);
//   while (ring_ptr.hasData()) { ... consume ... }
//
// All `inline` annotations are load-bearing: the wrapper must compile to
// the same machine code as manual ring.produce() + sys_ring_wake() calls
// (zero-overhead abstraction, RE contract §8 last paragraph).
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const shm = @import("../shared/shm.zig");

pub const tier: u8 = 1;

pub const RingError = error{
    Timeout,
    RingClosed,
    Spurious,
    ArmFailed,
};

/// Typed producer+consumer handle for a single-producer/single-consumer ring.
///
/// `T` is the entry type; `N` is the ring capacity (power of 2).
/// `ring` must point into a shared memory region the caller has attached.
/// `token` is the per-attach token returned by sys_map_create / sys_map_attach.
pub fn RingHandle(comptime T: type, comptime N: u32) type {
    return struct {
        ring: *volatile shm.SpscRing(T, N),
        token: u32,
        signal_pending: bool = false,

        const Self = @This();

        /// Write one entry to the ring. Caller must ensure space exists
        /// (via hasSpace() or waitForSpace()). Sets signal_pending so a
        /// subsequent flush() delivers the wake.
        pub inline fn produce(self: *Self, entry: T) void {
            self.ring.produce(entry);
            self.signal_pending = true;
        }

        /// Deliver a ring_wake to the consumer if produce() was called since
        /// the last flush(). Idiomatic batched usage:
        ///   for (frames) |f| h.produce(f);
        ///   h.flush();
        pub inline fn flush(self: *Self) void {
            if (!self.signal_pending) return;
            _ = sys.ring_wake(self.token, 0); // 0 = wake consumer
            self.signal_pending = false;
        }

        /// Park until the ring has data or the deadline expires.
        ///
        /// Returns immediately if head != tail (fast path, no syscall park).
        /// On WakeEvent.ring, returns ok; caller MUST re-check ring.hasData()
        /// as spurious wakes are allowed (RE.11).
        pub inline fn waitForData(self: *Self, timeout_ns: u64) RingError!void {
            const last = self.ring.tail;
            if (self.ring.hasData()) return; // fast path: data already present
            const arm_res = sys.ring_arm(self.token, @intFromPtr(self.ring), last, 0);
            if (@import("../gen/errors.zig").isError(arm_res)) return error.ArmFailed;
            switch (sys.wait_event(0, 0, 0, timeout_ns)) {
                .ring => {},
                .timeout => return error.Timeout,
                .closed => return error.RingClosed,
                .irq, .icc, .peer_crashed, .@"error" => return error.Spurious,
            }
        }

        /// Park until the ring has space or the deadline expires.
        ///
        /// Returns immediately if space is available (fast path).
        /// On WakeEvent.ring, returns ok; caller MUST re-check ring.hasSpace().
        pub inline fn waitForSpace(self: *Self, timeout_ns: u64) RingError!void {
            const last = self.ring.head;
            if (self.ring.hasSpace()) return; // fast path
            const arm_res = sys.ring_arm(self.token, @intFromPtr(self.ring), last, 1);
            if (@import("../gen/errors.zig").isError(arm_res)) return error.ArmFailed;
            switch (sys.wait_event(0, 0, 0, timeout_ns)) {
                .ring => {},
                .timeout => return error.Timeout,
                .closed => return error.RingClosed,
                .irq, .icc, .peer_crashed, .@"error" => return error.Spurious,
            }
        }

        /// Blocking produce: wait for space then write one entry.
        pub inline fn produceBlocking(self: *Self, entry: T, timeout_ns: u64) RingError!void {
            try self.waitForSpace(timeout_ns);
            self.produce(entry);
        }
    };
}
