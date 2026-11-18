//------------------------------------------------------------------------------
// User-Space Console API (Level 2 TTY)
//------------------------------------------------------------------------------
// Zero-syscall console output for cells.
//
// Each cell has a 64KB console ring buffer mapped at uva_layout.console_ring.base.
// The kernel reads from this buffer and routes output to UART.
//
// Usage:
//   const console = @import("liblaminae").console;
//   console.print("Hello, World!\n");
//   console.printf("Value: {}\n", .{42});
//
// Benefits:
// - Zero syscall overhead for output
// - ASID-isolated (each cell has its own ring)
// - Kernel polls and drains to UART
//
// Stdin is symmetric: each cell also has a 4KB stdin ring mapped at
// uva_layout.console_in.base. The kernel PL011 RX IRQ writes received bytes
// into it; the cell drains them here with zero syscalls (`readByte`). The
// only syscall is the blocking-wait slow path (`waitReadable`, syscall 109
// with fd=0), taken when the ring is empty and the reader wants to block.
//------------------------------------------------------------------------------

const std = @import("std");
const sys = @import("../gen/syscalls.zig");
const shared_fmt = @import("../shared/fmt.zig");
const uva_layout = @import("../shared/uva_layout.zig");

/// Tier-contract classification (tier_contract.md, audited by `lib/_audit.zig`).
/// Zero-syscall ring drain + `sys.write` fallback. No peer ICC.
pub const tier: u8 = 1;

//------------------------------------------------------------------------------
// Console Ring Buffer (matches kernel structure)
//------------------------------------------------------------------------------

/// Console flags for tracking buffer state
pub const ConsoleFlags = packed struct(u32) {
    overflow: bool = false,
    _reserved: u31 = 0,
};

/// Generic console ring buffer (matches kernel ConsoleRing)
pub fn ConsoleRing(comptime capacity: usize) type {
    return extern struct {
        const Self = @This();
        pub const CAPACITY = capacity;

        // Header (64 bytes, cache-line aligned)
        write_idx: u32 = 0,
        read_idx: u32 = 0,
        sequence: u32 = 0,
        flags: ConsoleFlags = .{},
        overflow_count: u32 = 0,
        _header_padding: [44]u8 = [_]u8{0} ** 44,

        // Data region
        data: [capacity]u8 = [_]u8{0} ** capacity,

        /// Write bytes to the ring buffer (producer API)
        pub fn write(self: *Self, bytes: []const u8) usize {
            if (bytes.len == 0) return 0;

            var written: usize = 0;
            for (bytes) |byte| {
                const next_write = (self.write_idx + 1) % capacity;

                // Check if buffer is full
                if (next_write == self.read_idx) {
                    // Overflow: advance read pointer (drop oldest)
                    self.read_idx = @intCast((@as(usize, self.read_idx) + 1) % capacity);
                    self.overflow_count += 1;
                    self.flags.overflow = true;
                }

                // Write the byte
                self.data[self.write_idx] = byte;
                self.write_idx = @intCast(next_write);
                self.sequence += 1;
                written += 1;
            }

            return written;
        }

        /// Bytes available to read (consumer API).
        pub fn readable(self: *const Self) usize {
            const w = self.write_idx;
            const r = self.read_idx;
            return if (w >= r) w - r else capacity - r + w;
        }

        /// Pop one byte (consumer API). Returns null if empty.
        pub fn pop1(self: *Self) ?u8 {
            if (self.read_idx == self.write_idx) return null;
            const c = self.data[self.read_idx];
            self.read_idx = @intCast((self.read_idx + 1) % capacity);
            return c;
        }
    };
}

/// Cell console type (64KB - 64B header = 65472B data)
pub const CellConsole = ConsoleRing(64 * 1024 - 64);

/// Cell stdin type (4KB - 64B header = 4032B data). Producer is the kernel
/// RX IRQ; this cell is the consumer.
pub const CellStdin = ConsoleRing(4 * 1024 - 64);

//------------------------------------------------------------------------------
// Console Ring Pointer
//------------------------------------------------------------------------------

/// Get pointer to this cell's console ring.
/// Uses `uva_layout.console_ring.base` -- single source of truth.
fn getConsole() *CellConsole {
    return uva_layout.console_ring.base.toPtr(*CellConsole);
}

/// Get pointer to this cell's stdin ring.
/// Uses `uva_layout.console_in.base` -- single source of truth.
fn getStdin() *CellStdin {
    return uva_layout.console_in.base.toPtr(*CellStdin);
}

//------------------------------------------------------------------------------
// Public API
//------------------------------------------------------------------------------

/// Print a string to the console (no newline added)
pub fn print(msg: []const u8) void {
    _ = getConsole().write(msg);
}

/// Print a string followed by a newline
pub fn println(msg: []const u8) void {
    const con = getConsole();
    _ = con.write(msg);
    _ = con.write("\n");
}

/// Formatted print (like std.debug.print)
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        print("[console: format overflow]\n");
        return;
    };
    print(msg);
}

/// Print a single character
pub fn putc(c: u8) void {
    var buf: [1]u8 = .{c};
    _ = getConsole().write(&buf);
}

/// Print a number in decimal
pub fn printNum(n: u64) void {
    var buf: [20]u8 = undefined;
    print(shared_fmt.dec(n, &buf));
}

/// Print a number in hexadecimal (with 0x prefix)
pub fn printHex(n: u64) void {
    var buf: [16]u8 = undefined;
    print("0x");
    print(shared_fmt.hex(n, .lower, &buf));
}

//------------------------------------------------------------------------------
// Stdin API (zero-syscall input)
//------------------------------------------------------------------------------

/// Number of bytes waiting in the stdin ring (zero syscall).
pub fn stdinReadable() usize {
    return getStdin().readable();
}

/// Direct pointer to this cell's stdin ring. The kernel RX IRQ is the normal
/// producer; exposed for loopback / self-injection (e.g. tests) where the
/// cell writes its own input via the producer API.
pub fn stdinRing() *CellStdin {
    return getStdin();
}

/// True if the stdin ring has dropped bytes due to overflow (reader too slow).
pub fn hasStdinOverflowed() bool {
    return getStdin().flags.overflow;
}

/// Total stdin bytes dropped so far (drop-oldest overflow policy).
pub fn stdinOverflowCount() u32 {
    return getStdin().overflow_count;
}

/// Acknowledge a stdin overflow (clears the flag; the count keeps running).
pub fn clearStdinOverflow() void {
    getStdin().flags.overflow = false;
}

/// Pop one byte from the stdin ring without blocking (zero syscall).
/// Returns null if no input is currently buffered.
pub fn readByte() ?u8 {
    return getStdin().pop1();
}

/// Non-blocking alias of `readByte`.
pub fn pollByte() ?u8 {
    return readByte();
}

/// Claim foreground and fold any pre-foreground / early-boot bytes into the
/// stdin ring, without blocking. Returns the ring's readable byte count.
/// Use in a poll loop before `pollByte`, e.g. to keep receiving keystrokes
/// while another cell might contend for foreground.
pub fn stdinPoll() u64 {
    var dummy: u8 = 0;
    return sys.read(0, &dummy, 1, 1, 0); // flags=1 -> non-blocking
}

/// Block until at least one byte is readable in the stdin ring, or the
/// deadline expires (timeout_ns == 0 blocks indefinitely). This is the only
/// syscall on the stdin path (syscall 109, fd=0); it copies nothing -- drain
/// the ring with `readByte` afterwards. Returns the readable byte count
/// (0 on timeout).
pub fn waitReadable(timeout_ns: u64) u64 {
    var dummy: u8 = 0;
    return sys.read(0, &dummy, 1, 0, timeout_ns);
}

/// Read one byte, blocking until input arrives. Drains the ring first
/// (zero syscall) and only parks (via `waitReadable`) when it is empty.
pub fn readByteBlocking() u8 {
    while (true) {
        if (readByte()) |c| return c;
        _ = waitReadable(0);
    }
}

/// Read a line into `buf`, blocking until a newline (LF or CR) or `buf` is
/// full. The terminator is consumed but not stored. Returns the line length.
/// Zero-syscall while the ring has bytes; parks only when it drains empty.
pub fn readLine(buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const c = readByteBlocking();
        if (c == '\n' or c == '\r') break;
        buf[n] = c;
        n += 1;
    }
    return n;
}

//------------------------------------------------------------------------------
// Console Statistics
//------------------------------------------------------------------------------

/// Get number of bytes written (total, including dropped)
pub fn getSequence() u32 {
    return getConsole().sequence;
}

/// Get number of bytes dropped due to overflow
pub fn getOverflowCount() u32 {
    return getConsole().overflow_count;
}

/// Check if overflow occurred
pub fn hasOverflowed() bool {
    return getConsole().flags.overflow;
}

//------------------------------------------------------------------------------
// Flush Support
//------------------------------------------------------------------------------

/// Flush console output to UART immediately
/// For interactive shells, call this after echoing characters
pub fn flush() void {
    // Use yield syscall to trigger a scheduler tick which drains the mux
    // This is a lightweight way to force immediate output
    _ = asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 101)), // yield syscall
    );
}
