//------------------------------------------------------------------------------
// Shared no-alloc formatting primitives
//------------------------------------------------------------------------------
// Pure buffer formatters usable from kernel (EL1), liblaminae, and user
// containers alike. No std, no allocation, no I/O -- callers own the buffer
// and route the returned slice to their own output path.
//
// Buffer sizing: dec() needs at most 20 bytes for a u64, hex() at most 16,
// ipv4() at most 15. Passing a too-small buffer is a caller bug and asserts
// in safe builds (truncated output in fast/small).
//------------------------------------------------------------------------------

pub const Case = enum { lower, upper };

fn digits(case: Case) *const [16]u8 {
    return switch (case) {
        .lower => "0123456789abcdef",
        .upper => "0123456789ABCDEF",
    };
}

/// Minimal decimal digits, no sign, no padding.
pub fn dec(value: u64, buf: []u8) []u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        tmp[len] = @truncate('0' + (v % 10));
        len += 1;
    }
    for (0..len) |i| {
        buf[i] = tmp[len - 1 - i];
    }
    return buf[0..len];
}

/// Minimal hex digits, no 0x prefix, no padding.
pub fn hex(value: u64, case: Case, buf: []u8) []u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [16]u8 = undefined;
    var len: usize = 0;
    var v = value;
    while (v > 0) : (v >>= 4) {
        tmp[len] = digits(case)[@as(u4, @truncate(v))];
        len += 1;
    }
    for (0..len) |i| {
        buf[i] = tmp[len - 1 - i];
    }
    return buf[0..len];
}

/// Fixed-width zero-padded hex, no 0x prefix (register/dump style).
pub fn hexFixed(value: u64, comptime width: usize, case: Case, buf: []u8) []u8 {
    comptime {
        if (width == 0 or width > 16) @compileError("hexFixed width must be 1..16");
    }
    for (0..width) |i| {
        const shift: u6 = @intCast((width - 1 - i) * 4);
        buf[i] = digits(case)[@as(u4, @truncate(value >> shift))];
    }
    return buf[0..width];
}

/// Dotted-quad IPv4. `ip` is packed host-LE: first octet in the LSB,
/// matching the ICC net protocol's writeU32 and zmoltcp's banner.
pub fn ipv4(ip: u32, buf: []u8) []u8 {
    var pos: usize = 0;
    inline for (0..4) |i| {
        const octet: u8 = @truncate(ip >> (i * 8));
        pos += dec(octet, buf[pos..]).len;
        if (i < 3) {
            buf[pos] = '.';
            pos += 1;
        }
    }
    return buf[0..pos];
}
