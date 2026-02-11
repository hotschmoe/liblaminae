// Big Counter Demo for Laminae OS
// Showcases syscalls: write, get_time, sleep, get_container_id, get_platform, yield

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

fn writeHex(n: u64) void {
    const hex = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 17;
    var num = n;
    if (num == 0) {
        write("0x0");
        return;
    }
    while (num > 0 and i >= 2) : (num >>= 4) {
        buf[i] = hex[@intCast(num & 0xF)];
        i -= 1;
    }
    write(buf[i + 1 .. 18]);
}

/// Print a simple progress bar: [####    ] style
fn writeBar(current: u64, total: u64, width: u64) void {
    const filled = (current * width) / total;
    write("[");
    var j: u64 = 0;
    while (j < width) : (j += 1) {
        if (j < filled) {
            write("#");
        } else {
            write(".");
        }
    }
    write("]");
}

export fn _start() noreturn {
    // ── Banner ──────────────────────────────
    write("\n");
    write("+--------------------------------------+\n");
    write("|      BIG COUNTER - Laminae OS        |\n");
    write("|      Syscall Showcase Demo           |\n");
    write("+--------------------------------------+\n\n");

    // ── System Info ─────────────────────────
    write(">> System Info\n");

    const cid = sys.get_container_id();
    write("   Container ID : ");
    writeNum(cid);
    write("\n");

    const plat = sys.get_platform();
    write("   Platform     : ");
    writeHex(plat);
    write("\n");

    const boot_time = sys.get_time();
    write("   Boot time    : ");
    writeNum(boot_time / 1_000_000);
    write(" ms\n\n");

    // ── Counting Phase ──────────────────────
    const max: u64 = 20;
    write(">> Counting to ");
    writeNum(max);
    write(" (200ms intervals)\n\n");

    const t0 = sys.get_time();
    var i: u64 = 0;

    while (i <= max) : (i += 1) {
        // Line: "   03/20 [######..........] 150ms"
        write("   ");
        if (i < 10) write("0");
        writeNum(i);
        write("/");
        writeNum(max);
        write(" ");
        writeBar(i, max, 20);

        const elapsed = (sys.get_time() - t0) / 1_000_000;
        write(" ");
        writeNum(elapsed);
        write("ms\n");

        if (i < max) {
            _ = sys.sleep(200_000_000); // 200ms
        }
    }

    // ── Yield Test ──────────────────────────
    write("\n>> Yield test (5 yields)\n");
    var y: u64 = 0;
    const yt0 = sys.get_time();
    while (y < 5) : (y += 1) {
        _ = sys.yield();
    }
    const yield_us = (sys.get_time() - yt0) / 1_000;
    write("   5 yields in ");
    writeNum(yield_us);
    write(" us\n");

    // ── Summary ─────────────────────────────
    const total_ms = (sys.get_time() - t0) / 1_000_000;
    write("\n+--------------------------------------+\n");
    write("|  RESULTS                             |\n");
    write("+--------------------------------------+\n");
    write("   Counts      : ");
    writeNum(max);
    write("\n");
    write("   Total time  : ");
    writeNum(total_ms);
    write(" ms\n");
    write("   Avg/count   : ");
    if (max > 0) writeNum(total_ms / max);
    write(" ms\n");
    write("+--------------------------------------+\n");
    write("\n[BIG_COUNTER_OK]\n");

    sys.exit(0);
}
