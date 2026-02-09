// Big Counter Demo for Laminae OS
// Minimal counting demo using liblaminae syscalls

const lib = @import("liblaminae");
const sys = lib.syscalls;

fn write(buf: []const u8) void {
    _ = sys.write(1, @ptrCast(buf.ptr), buf.len);
}

fn writeNum(n: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var num = n;
    if (num == 0) {
        write("0");
        return;
    }
    while (num > 0) : (num /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (num % 10));
    }
    write(buf[i..20]);
}

export fn _start() noreturn {
    write("=== BIG COUNTER ===\n");

    const t0 = sys.get_time();
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        writeNum(i);
        write(" ");
        _ = sys.sleep(200_000_000);
    }

    write("\nDone ");
    writeNum((sys.get_time() - t0) / 1_000_000);
    write("ms\n[BIG_COUNTER_OK]\n");
    sys.exit(0);
}
