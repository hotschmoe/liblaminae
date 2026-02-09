//------------------------------------------------------------------------------
// User-Space Console API (Level 2 TTY)
//------------------------------------------------------------------------------
// Zero-syscall console output for containers.
//
// Each container has a 64KB console ring buffer mapped at CONSOLE_RING_VA.
// The kernel reads from this buffer and routes output to UART.
//
// Usage:
//   const console = @import("liblaminae").console;
//   console.print("Hello, World!\n");
//   console.printf("Value: {}\n", .{42});
//
// Benefits:
// - Zero syscall overhead for output
// - ASID-isolated (each container has its own ring)
// - Kernel polls and drains to UART
//
// TODO: Research ring buffer for stdin (currently syscall-based)
//------------------------------------------------------------------------------

const std = @import("std");
const va_layout = @import("../shared/va_layout.zig");

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
    };
}

/// Container console type (64KB - 64B header = 65472B data)
pub const ContainerConsole = ConsoleRing(64 * 1024 - 64);

//------------------------------------------------------------------------------
// Console Ring Pointer
//------------------------------------------------------------------------------

/// Get pointer to this container's console ring.
/// Uses CONSOLE_RING_VA from shared va_layout (single source of truth).
fn getConsole() *ContainerConsole {
    return @ptrFromInt(va_layout.CONSOLE_RING_VA);
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
    var i: usize = 20;
    var num = n;

    if (num == 0) {
        print("0");
        return;
    }

    while (num > 0) : (num /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (num % 10));
    }

    print(buf[i..20]);
}

/// Print a number in hexadecimal (with 0x prefix)
pub fn printHex(n: u64) void {
    const hex_chars = "0123456789abcdef";
    var buf: [18]u8 = undefined; // "0x" + 16 hex digits
    buf[0] = '0';
    buf[1] = 'x';

    var i: usize = 17;
    var num = n;

    if (num == 0) {
        print("0x0");
        return;
    }

    while (num > 0 and i >= 2) : (num >>= 4) {
        buf[i] = hex_chars[@intCast(num & 0xF)];
        i -= 1;
    }

    print(buf[i + 1 .. 18]);
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
