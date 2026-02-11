// =============================================================================
// Laminae OS — "Kitchen Sink" Demo  (must stay < 8KB .bin)
// =============================================================================
// Exercises every user-accessible subsystem via raw syscalls.
// No std imports — keeps binary tiny.
// =============================================================================

const lib = @import("liblaminae");
const sys = lib.syscalls;
const barriers = lib.barriers;
const va = lib.va_layout;

// ─── Tiny Output (no std, no fmt) ───────────────────────────────────────────

fn w(buf: []const u8) void {
    _ = sys.write(1, @ptrCast(buf.ptr), buf.len);
}

fn wn(n: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var num = n;
    if (num == 0) {
        w("0");
        return;
    }
    while (num > 0) : (num /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (num % 10));
    }
    w(buf[i..20]);
}

fn wh(n: u64) void {
    const hx = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 17;
    var num = n;
    if (num == 0) {
        w("0x0");
        return;
    }
    while (num > 0 and i >= 2) : (num >>= 4) {
        buf[i] = hx[@intCast(num & 0xF)];
        i -= 1;
    }
    w(buf[i + 1 .. 18]);
}

fn hdr(label: []const u8) void {
    w("\n== ");
    w(label);
    w(" ==\n");
}

fn res(label: []const u8, val: u64) void {
    w("  ");
    w(label);
    if (lib.isError(val)) {
        w(" ERR ");
        wh(val);
    } else {
        w(" => ");
        wn(val);
    }
    w("\n");
}

fn ok(label: []const u8) void {
    w("  + ");
    w(label);
    w("\n");
}

// ─── Console Ring direct access ─────────────────────────────────────────────

const RingHdr = extern struct { write_idx: u32, read_idx: u32, sequence: u32, flags: u32, overflow_count: u32, _p: [44]u8 };

fn ringHdr() *volatile RingHdr {
    return @ptrFromInt(va.CONSOLE_RING_VA);
}

fn ringWrite(msg: []const u8) void {
    const ring: [*]volatile u8 = @ptrFromInt(va.CONSOLE_RING_VA + 64);
    const h = ringHdr();
    const cap: u32 = 64 * 1024 - 64;
    for (msg) |b| {
        ring[h.write_idx] = b;
        h.write_idx = (h.write_idx + 1) % cap;
        h.sequence += 1;
    }
}

// ─── Entry ──────────────────────────────────────────────────────────────────

export fn _start() noreturn {
    const t0 = sys.get_time();

    w("\n+== LAMINAE Kitchen Sink Demo ==+\n");

    // ── 1. Identity & Platform ────────────────────────
    hdr("1 Identity");
    const cid = lib.getContainerId();
    w("  CID(zero-sc): ");
    wn(cid);
    w("\n");
    w("  CID(syscall): ");
    wn(sys.get_container_id());
    w("\n");

    const plat = lib.PlatformType.fromSyscall(sys.get_platform());
    w("  Platform: ");
    w(plat.getName());
    w(if (plat.isRealHardware()) " [HW]" else " [EMU]");
    w("\n  Time: ");
    wn(t0 / 1_000_000);
    w("ms\n");

    // ── 2. Console Ring (zero-syscall I/O) ────────────
    hdr("2 Console Ring");
    ringWrite("[ring] zero-syscall write!\n");
    ok("ring buffer direct write");
    const rh = ringHdr();
    w("  seq=");
    wn(rh.sequence);
    w(" ovf=");
    wn(rh.overflow_count);
    w("\n");
    w("  VA: con=");
    wh(va.CONSOLE_RING_VA);
    w(" heap=");
    wh(va.HEAP_VA_BASE);
    w(" dev=");
    wh(va.DEVICE_VA_BASE);
    w("\n");

    // ── 3. Timing ─────────────────────────────────────
    hdr("3 Timing");
    const ys = sys.get_time();
    var yi: u32 = 0;
    while (yi < 10) : (yi += 1) _ = sys.yield();
    const yc = sys.get_time() - ys;
    w("  10x yield: ");
    wn(yc);
    w("ns (");
    wn(yc / 10);
    w("ns/ea)\n");

    const ps = sys.get_time();
    _ = sys.sleep(10_000_000);
    const ac = sys.get_time() - ps;
    w("  sleep(10ms): ");
    wn(ac / 1_000_000);
    w(".");
    wn((ac / 100_000) % 10);
    w("ms\n");

    const a1 = sys.get_time();
    const a2 = sys.get_time();
    w("  timer delta: ");
    wn(a2 - a1);
    w("ns\n");

    // ── 4. Container List ─────────────────────────────
    hdr("4 Containers");
    var ib: [8]sys.ContainerInfo = undefined;
    const lc = sys.container_list(&ib[0], 8);
    if (!lib.isError(lc)) {
        w("  count=");
        wn(lc);
        w("\n");
        var ci: u64 = 0;
        while (ci < lc and ci < 8) : (ci += 1) {
            const inf = &ib[ci];
            w("   [");
            wn(inf.id);
            w("] ");
            w(inf.getName());
            w(" t=");
            wn(inf.container_type);
            w("\n");
        }
    } else {
        res("list", lc);
    }

    var lb: [64]u8 = undefined;
    const lr = sys.container_log_read(cid, &lb[0], 64);
    if (!lib.isError(lr)) {
        w("  log(");
        wn(lr);
        w("B): ");
        const s = if (lr > 40) @as(usize, 40) else @as(usize, @intCast(lr));
        if (s > 0) w(lb[0..s]);
        w("\n");
    } else {
        res("log", lr);
    }

    // ── 5. Namespace ──────────────────────────────────
    hdr("5 Namespace");
    const sn = "demo.ks";
    res("register", sys.ns_register(&sn[0], sn.len));
    const lu = sys.ns_lookup(&sn[0], sn.len);
    if (!lib.isError(lu)) {
        w("  lookup => ");
        wn(lu);
        if (lu == cid) w(" (self)");
        w("\n");
    } else {
        res("lookup", lu);
    }
    const fk = "no.svc";
    if (lib.isError(sys.ns_lookup(&fk[0], fk.len))) {
        ok("miss => error (ok)");
    }

    // ── 6. Shared Memory ──────────────────────────────
    hdr("6 SHM");
    const sh = sys.map_create(1, 0);
    if (!lib.isError(sh)) {
        ok("map_create");
        const handle = sys.MapResult.handle(sh);
        const create_va = sys.MapResult.va(sh);
        const sv = sys.map_attach(handle, 0x3);
        if (!lib.isError(sv)) {
            ok("map_attach(RW)");
            // Write via create mapping, verify via attach mapping (same phys pages)
            const pw: [*]volatile u8 = @ptrFromInt(create_va);
            pw[0] = 0xCA;
            pw[1] = 0xFE;
            pw[2] = 0xBA;
            pw[3] = 0xBE;
            barriers.dataMemoryBarrier();
            const pr: [*]volatile u8 = @ptrFromInt(sv);
            if (pr[0] == 0xCA and pr[1] == 0xFE) ok("SHM verify 0xCAFE");
            res("detach", sys.map_detach(handle));
        } else {
            res("attach", sv);
        }
    } else {
        res("map_create", sh);
    }

    // ── 7. Heap (brk) ─────────────────────────────────
    hdr("7 Heap");
    const b0 = sys.brk(0);
    w("  break: ");
    wh(b0);
    w("\n");
    const b1 = sys.brk(b0 + 4096);
    if (b1 >= b0 + 4096) {
        ok("brk(+4K)");
        const hp: [*]volatile u8 = @ptrFromInt(b0);
        var hi: usize = 0;
        while (hi < 256) : (hi += 1) hp[hi] = @truncate(hi);
        var g: usize = 0;
        hi = 0;
        while (hi < 256) : (hi += 1) {
            if (hp[hi] == @as(u8, @truncate(hi))) g += 1;
        }
        w("  verify: ");
        wn(g);
        w("/256\n");
        _ = sys.brk(b0);
        ok("brk reset");
    } else {
        res("brk", b1);
    }

    // ── 8. Filesystem ─────────────────────────────────
    hdr("8 FS");
    const fn_ = "/tmp/ks.txt";
    const fd = sys.fs_open(&fn_[0], fn_.len, 0x241);
    if (!lib.isError(fd)) {
        ok("open /tmp/ks.txt");
        const dt = "KitchenSink!\n";
        res("write", sys.write(fd, &dt[0], dt.len));
        var st: sys.Stat = undefined;
        if (!lib.isError(sys.fs_stat(fd, &st))) {
            w("  size=");
            wn(@intCast(st.size));
            w("B\n");
        }
        res("close", sys.fs_close(fd));
    } else {
        res("fs_open", fd);
    }

    var de: [4]sys.DirEntry = undefined;
    const dp = "/";
    const dc = sys.fs_readdir(&dp[0], dp.len, &de[0], 4);
    if (!lib.isError(dc)) {
        w("  / : ");
        wn(dc);
        w(" entries\n");
        var di: u64 = 0;
        while (di < dc and di < 4) : (di += 1) {
            w("    ");
            w(de[di].name[0..de[di].name_len]);
            w("\n");
        }
    } else {
        res("readdir", dc);
    }

    // ── 9. Device Graph ───────────────────────────────
    hdr("9 DevGraph");
    const dn = sys.device_graph_count();
    if (!lib.isError(dn)) {
        w("  nodes=");
        wn(dn);
        w("\n");
        var di2: u32 = 0;
        const mx: u32 = if (dn > 3) 3 else @intCast(dn);
        while (di2 < mx) : (di2 += 1) {
            var nd: sys.DeviceGraphNode = undefined;
            if (!lib.isError(sys.device_graph_get_node(di2, &nd))) {
                w("   [");
                wn(nd.id);
                w("] ");
                w(nd.getCompatible());
                w(" r=");
                wn(nd.reg_count);
                w(" i=");
                wn(nd.irq_count);
                w("\n");
                if (nd.reg_count > 0) {
                    var rg: sys.RegEntry = undefined;
                    if (!lib.isError(sys.device_graph_get_reg(di2, 0, &rg))) {
                        w("     @");
                        wh(rg.phys_addr);
                        w("+");
                        wh(rg.size);
                        w("\n");
                    }
                }
            }
        }
    } else {
        res("dev_count", dn);
    }

    // ── 10. Cache Ops ─────────────────────────────────
    hdr("10 Cache");
    const cb0 = sys.brk(0);
    const cb1 = sys.brk(cb0 + 4096);
    if (cb1 >= cb0 + 4096) {
        const cp: [*]volatile u8 = @ptrFromInt(cb0);
        var cx: usize = 0;
        while (cx < 64) : (cx += 1) cp[cx] = @truncate(cx);
        res("clean", sys.cache_clean_range(cb0, 64));
        res("inv", sys.cache_invalidate_range(cb0, 64));
        res("c+i", sys.cache_clean_invalidate_range(cb0, 64));
        _ = sys.brk(cb0);
    }

    // ── 11. Barriers ──────────────────────────────────
    hdr("11 Barriers");
    barriers.dataMemoryBarrier();
    ok("DMB SY");
    barriers.dataMemoryBarrierInner();
    ok("DMB ISH");
    barriers.dataSyncBarrier();
    ok("DSB SY");
    barriers.instructionBarrier();
    ok("ISB");
    barriers.systemBarrier();
    ok("DSB+ISB");
    barriers.fullBarrierWithClobber();
    ok("full+fence");
    lib.idle.sendEvent();
    ok("SEV");

    // ── 12. Event Wait ────────────────────────────────
    hdr("12 WaitEvent");
    const ws = sys.get_time();
    const wk = sys.wait_event(0, 0, 0, 1_000_000);
    const we = sys.get_time() - ws;
    w("  reason=");
    switch (sys.WakeReason.fromU64(wk)) {
        .timeout => w("TIMEOUT"),
        .irq => w("IRQ"),
        .icc => w("ICC"),
        .peer_crashed => w("CRASH"),
        .@"error" => w("ERR"),
    }
    w(" ");
    wn(we / 1000);
    w("us\n");

    // ── 13. Error Utils ───────────────────────────────
    hdr("13 Errors");
    w("  isErr(0)=");
    w(if (lib.isError(0)) "T" else "F");
    w(" isErr(42)=");
    w(if (lib.isError(42)) "T" else "F");
    w(" isErr(BASE)=");
    w(if (lib.isError(lib.errors.ERROR_BASE)) "T" else "F");
    w("\n  CTX_SW=");
    wh(lib.errors.CONTEXT_SWITCHED);
    w("\n");

    // ── Done ──────────────────────────────────────────
    hdr("DONE");
    const el = sys.get_time() - t0;
    w("  ");
    wn(el / 1_000_000);
    w(".");
    wn((el / 100_000) % 10);
    w("ms\n");
    w("  27 syscalls + 7 zero-syscall ops\n");
    w("\n[KITCHEN_SINK_OK]\n");

    sys.exit(0);
}
