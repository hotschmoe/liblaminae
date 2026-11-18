//------------------------------------------------------------------------------
// Boot graph -- one structured dump of this instance (the_law T3)
//
// The resident operator's instrument panel. Sensors already exist
// (cell_list, chan_snapshot, lease_snapshot, cell_history, mem_info,
// device_graph_count). dump() joins them into one JSON object. dumpStatus()
// is the sitting: platform, last [EVT], live names, recent deaths, then
// the ask-path. dumpManual() starts with the same ask-path so a session
// does not have to know the ritual.
//
// Placement: T1 vocabulary. T0 syscalls only, no peer ICC, no heap, no
// indefinite block. Output is streamed through a caller-supplied writer
// so the shell (or any cell) owns I/O. Snapshots are racy by design --
// `consistent` is always false. Identities are generation-qualified.
// A cell that vanishes between list and snapshot is emitted with
// `"gone": true` rather than a crash.
//
// Schema version 1. Bump when a field is renamed or removed.
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const errors = @import("../gen/errors.zig");
const fmt = @import("../shared/fmt.zig");
const identity = @import("identity.zig");
const sensitive = @import("../shared/icc/sensitive.zig");

/// Tier-contract classification (audited by `lib/_audit.zig`).
pub const tier: u8 = 1;

pub const SCHEMA_VERSION: u32 = 1;

pub const Writer = struct {
    write: *const fn ([]const u8) void,
};

const MAX_CELLS = 64;
const MAX_DEATHS = 16;

var cells: [MAX_CELLS]sys.CellInfo = undefined;
var deaths: [MAX_DEATHS]sys.CellExitRecord = undefined;
var ep_snap: sys.EndpointSnapshot = undefined;
var lease_snap: sys.LeaseSnapshot = undefined;

const STATE_NAMES = [_][]const u8{ "running", "ready", "blocked", "terminated" };
const TYPE_NAMES = [_][]const u8{ "user", "driver", "init", "platform", "kernel_test" };
const EXIT_NAMES = [_][]const u8{ "self_exit", "killed", "crashed" };
const LEASE_KIND = [_][]const u8{ "mmio", "irq", "dma" };
const LEASE_STATE = [_][]const u8{ "free", "held", "revoking", "fenced", "reusable" };
const EP_DIR = [_][]const u8{ "out", "in" };
const EP_STATE = [_][]const u8{ "unwired", "wired", "peer_closed" };

fn w(out: Writer, s: []const u8) void {
    out.write(s);
}

fn wDec(out: Writer, n: u64) void {
    var buf: [20]u8 = undefined;
    w(out, fmt.dec(n, &buf));
}

fn wHex(out: Writer, n: u64) void {
    var buf: [16]u8 = undefined;
    w(out, "0x");
    w(out, fmt.hex(n, .lower, &buf));
}

fn wJsonStr(out: Writer, s: []const u8) void {
    w(out, "\"");
    for (s) |c| {
        switch (c) {
            '"' => w(out, "\\\""),
            '\\' => w(out, "\\\\"),
            '\n' => w(out, "\\n"),
            '\r' => w(out, "\\r"),
            '\t' => w(out, "\\t"),
            else => {
                if (c < 0x20) {
                    w(out, "\\u00");
                    const hi: u8 = "0123456789abcdef"[c >> 4];
                    const lo: u8 = "0123456789abcdef"[c & 0xf];
                    const pair = [_]u8{ hi, lo };
                    w(out, &pair);
                } else {
                    const one = [_]u8{c};
                    w(out, &one);
                }
            },
        }
    }
    w(out, "\"");
}

fn nameOf(names: []const []const u8, idx: u8) []const u8 {
    if (idx < names.len) return names[idx];
    return "unknown";
}

fn wPackedId(out: Writer, packed_id: u32) void {
    const id = identity.fromPacked(packed_id);
    w(out, "{\"raw\":");
    wDec(out, id.raw);
    w(out, ",\"generation\":");
    wDec(out, id.generation);
    w(out, ",\"packed\":");
    wDec(out, packed_id);
    w(out, "}");
}

fn wEndpoints(out: Writer, snap: *const sys.EndpointSnapshot) void {
    w(out, "[");
    var i: u32 = 0;
    while (i < snap.count) : (i += 1) {
        if (i != 0) w(out, ",");
        const e = snap.entries[i];
        w(out, "{\"token\":");
        wDec(out, e.token);
        w(out, ",\"pair_id\":");
        wDec(out, e.pair_id);
        w(out, ",\"contract_hash\":");
        wHex(out, e.contract_hash);
        w(out, ",\"sensitive\":");
        w(out, if (sensitive.isSensitive(e.contract_hash)) "true" else "false");
        w(out, ",\"version\":");
        wDec(out, e.version);
        w(out, ",\"direction\":");
        wJsonStr(out, nameOf(&EP_DIR, e.direction));
        w(out, ",\"state\":");
        wJsonStr(out, nameOf(&EP_STATE, e.state));
        w(out, ",\"wired_by\":");
        wPackedId(out, e.wired_by);
        w(out, ",\"peer_holder\":");
        wPackedId(out, e.peer_holder);
        w(out, ",\"closed_peer\":");
        wPackedId(out, e.closed_peer);
        w(out, "}");
    }
    w(out, "]");
}

fn wLeases(out: Writer, snap: *const sys.LeaseSnapshot) void {
    w(out, "[");
    var i: u32 = 0;
    while (i < snap.count) : (i += 1) {
        if (i != 0) w(out, ",");
        const e = snap.entries[i];
        w(out, "{\"kind\":");
        wJsonStr(out, nameOf(&LEASE_KIND, e.kind));
        w(out, ",\"state\":");
        wJsonStr(out, nameOf(&LEASE_STATE, e.state));
        w(out, ",\"holder_gen\":");
        wDec(out, e.holder_gen);
        w(out, ",\"detail\":");
        wHex(out, e.detail);
        w(out, "}");
    }
    w(out, "]");
}

/// Stream this boot as one JSON object. Never blocks forever. Never allocates.
pub fn dump(out: Writer) void {
    w(out, "{\"schema_version\":");
    wDec(out, SCHEMA_VERSION);
    w(out, ",\"consistent\":false");

    w(out, ",\"platform\":");
    wDec(out, sys.get_platform());
    w(out, ",\"now_ns\":");
    wDec(out, sys.get_time());

    var mem: sys.MemInfo = undefined;
    const mem_r = sys.mem_info(&mem);
    w(out, ",\"mem\":");
    if (errors.isError(mem_r)) {
        w(out, "null");
    } else {
        w(out, "{\"total_pages\":");
        wDec(out, mem.total_pages);
        w(out, ",\"free_pages\":");
        wDec(out, mem.free_pages);
        w(out, ",\"used_pages\":");
        wDec(out, mem.used_pages);
        w(out, ",\"page_size\":");
        wDec(out, mem.page_size);
        w(out, ",\"cell_count\":");
        wDec(out, mem.cell_count);
        w(out, "}");
    }

    const n_dev = sys.device_graph_count();
    w(out, ",\"device_count\":");
    if (errors.isError(n_dev)) w(out, "null") else wDec(out, n_dev);

    const n_cells = sys.cell_list(&cells[0], MAX_CELLS, 0);
    w(out, ",\"cells\":[");
    if (!errors.isError(n_cells)) {
        var i: u64 = 0;
        while (i < n_cells) : (i += 1) {
            if (i != 0) w(out, ",");
            const c = cells[i];
            const packed_id = (identity.CellIdentity{ .raw = c.id, .generation = c.generation }).pack();
            w(out, "{\"id\":");
            wPackedId(out, packed_id);
            w(out, ",\"type\":");
            wJsonStr(out, nameOf(&TYPE_NAMES, c.cell_type));
            w(out, ",\"state\":");
            wJsonStr(out, nameOf(&STATE_NAMES, c.state));
            w(out, ",\"name\":");
            wJsonStr(out, c.getName());
            w(out, ",\"start_time_ns\":");
            wDec(out, c.start_time_ns);

            const ep_r = sys.chan_snapshot(@as(u64, packed_id), &ep_snap);
            w(out, ",\"endpoints\":");
            if (errors.isError(ep_r)) {
                w(out, "[]");
                w(out, ",\"gone\":true");
            } else {
                wEndpoints(out, &ep_snap);
                w(out, ",\"gone\":false");
            }

            const ls_r = sys.lease_snapshot(@as(u64, packed_id), &lease_snap);
            w(out, ",\"leases\":");
            if (errors.isError(ls_r)) w(out, "[]") else wLeases(out, &lease_snap);

            w(out, "}");
        }
    }
    w(out, "]");

    const n_dead = sys.cell_history(&deaths[0], MAX_DEATHS, 0);
    w(out, ",\"deaths\":[");
    if (!errors.isError(n_dead)) {
        var d: u64 = 0;
        while (d < n_dead) : (d += 1) {
            if (d != 0) w(out, ",");
            const rec = deaths[d];
            w(out, "{\"index\":");
            wDec(out, rec.index);
            w(out, ",\"id\":");
            wPackedId(out, rec.id_packed);
            w(out, ",\"type\":");
            wJsonStr(out, nameOf(&TYPE_NAMES, rec.cell_type));
            w(out, ",\"exit_kind\":");
            wJsonStr(out, nameOf(&EXIT_NAMES, rec.exit_kind));
            w(out, ",\"name\":");
            wJsonStr(out, rec.getName());
            w(out, ",\"exit_code\":");
            wHex(out, rec.exit_code);
            w(out, ",\"start_time_ns\":");
            wDec(out, rec.start_time_ns);
            w(out, ",\"exit_time_ns\":");
            wDec(out, rec.exit_time_ns);
            var cap: sys.DeathCapsule = undefined;
            const cap_r = sys.cell_capsule(rec.id_packed, &cap);
            if (!errors.isError(cap_r)) {
                w(out, ",\"endpoints\":");
                wEndpoints(out, &cap.endpoints);
                w(out, ",\"leases\":");
                wLeases(out, &cap.leases);
            }
            w(out, "}");
        }
    }
    w(out, "]");

    w(out, "}\n");
}

fn hasEvtTag(s: []const u8) bool {
    if (s.len < 5) return false;
    var i: usize = 0;
    while (i + 5 <= s.len) : (i += 1) {
        if (s[i] == '[' and s[i + 1] == 'E' and s[i + 2] == 'V' and s[i + 3] == 'T' and s[i + 4] == ']')
            return true;
    }
    return false;
}

fn dumpAsk(out: Writer) void {
    w(out, "ask:\n");
    w(out, "  what is alive?            status\n");
    w(out, "  why did X die?            capsule <packed-id> then klog --evt\n");
    w(out, "  can I talk to net.stack?  dryrun net.stack\n");
    w(out, "  show the wiring           graph\n");
    w(out, "ops: status | graph | manual | capsule <packed-id> | dryrun <ns> | klog --evt\n");
}

/// One sitting: platform, last [EVT] crumbs, live names, recent deaths, then ask.
pub fn dumpStatus(out: Writer) void {
    w(out, "status\n");
    w(out, "platform=");
    wDec(out, sys.get_platform());
    w(out, " now_ns=");
    wDec(out, sys.get_time());
    w(out, "\n");

    const EVT_KEEP: usize = 8;
    const EVT_LINE: usize = 160;
    var ring: [EVT_KEEP][EVT_LINE]u8 = undefined;
    var ring_n: [EVT_KEEP]u8 = [_]u8{0} ** EVT_KEEP;
    var ring_i: usize = 0;
    var ring_count: usize = 0;

    var kbuf: [2048]u8 = undefined;
    var req = sys.KlogCursorRead{
        .cursor = 0,
        .buf_ptr = @intFromPtr(&kbuf[0]),
        .buf_len = kbuf.len,
        .dropped = 0,
    };
    var line: [EVT_LINE]u8 = undefined;
    var line_len: usize = 0;
    while (true) {
        const n = sys.console_ctl(6, @intFromPtr(&req), 0);
        if (errors.isError(n) or n == 0) break;
        for (kbuf[0..@intCast(n)]) |c| {
            if (c == '\n') {
                if (hasEvtTag(line[0..line_len])) {
                    const slot = ring_i % EVT_KEEP;
                    const take = @min(line_len, EVT_LINE);
                    @memcpy(ring[slot][0..take], line[0..take]);
                    ring_n[slot] = @intCast(take);
                    ring_i += 1;
                    if (ring_count < EVT_KEEP) ring_count += 1;
                }
                line_len = 0;
            } else if (line_len < line.len) {
                line[line_len] = c;
                line_len += 1;
            }
        }
        if (n < kbuf.len) break;
    }
    if (line_len > 0 and hasEvtTag(line[0..line_len])) {
        const slot = ring_i % EVT_KEEP;
        const take = @min(line_len, EVT_LINE);
        @memcpy(ring[slot][0..take], line[0..take]);
        ring_n[slot] = @intCast(take);
        ring_i += 1;
        if (ring_count < EVT_KEEP) ring_count += 1;
    }

    w(out, "evt:\n");
    if (ring_count == 0) {
        w(out, "  (none)\n");
    } else {
        const start = ring_i - ring_count;
        var e: usize = 0;
        while (e < ring_count) : (e += 1) {
            const slot = (start + e) % EVT_KEEP;
            w(out, "  ");
            w(out, ring[slot][0..ring_n[slot]]);
            w(out, "\n");
        }
    }

    const n_cells = sys.cell_list(&cells[0], MAX_CELLS, 0);
    w(out, "alive=");
    if (errors.isError(n_cells)) {
        w(out, "?\n");
    } else {
        wDec(out, n_cells);
        w(out, "\n");
        var i: u64 = 0;
        while (i < n_cells) : (i += 1) {
            const c = cells[i];
            const packed_id = (identity.CellIdentity{ .raw = c.id, .generation = c.generation }).pack();
            w(out, "  ");
            w(out, c.getName());
            w(out, " packed=");
            wDec(out, packed_id);
            w(out, " ");
            w(out, nameOf(&STATE_NAMES, c.state));
            w(out, "\n");
        }
    }

    const n_dead = sys.cell_history(&deaths[0], MAX_DEATHS, 0);
    w(out, "deaths=");
    if (errors.isError(n_dead)) {
        w(out, "?\n");
    } else {
        const show_from: u64 = if (n_dead > 4) n_dead - 4 else 0;
        wDec(out, n_dead);
        w(out, " (last 4)\n");
        var d: u64 = show_from;
        while (d < n_dead) : (d += 1) {
            const rec = deaths[d];
            w(out, "  packed=");
            wDec(out, rec.id_packed);
            w(out, " ");
            w(out, nameOf(&EXIT_NAMES, rec.exit_kind));
            w(out, " ");
            w(out, rec.getName());
            w(out, "\n");
        }
    }

    dumpAsk(out);
}

/// Instance manual: this boot's syscall surface + HARDLINE breaks + graph.
/// Syscall names come from the generated enum -- never hand-listed.
pub fn dumpManual(out: Writer) void {
    w(out, "Laminae instance manual\n");
    dumpAsk(out);
    w(out, "platform=");
    wDec(out, sys.get_platform());
    w(out, " now_ns=");
    wDec(out, sys.get_time());
    w(out, "\n");

    w(out, "syscalls (generated table):\n");
    inline for (@typeInfo(sys.Syscall).@"enum".fields) |f| {
        w(out, "  ");
        wDec(out, f.value);
        w(out, " ");
        w(out, f.name);
        w(out, "\n");
    }

    w(out, "hardline breaks in force:\n");
    w(out, "  1 ramfs (RAM-only, syscalls 220-236)\n");
    w(out, "  2 console/klog/fbcon mirror (panic path)\n");
    w(out, "  3 UART/GIC/timer (kernel heartbeat)\n");
    w(out, "  4 kernel_test EL1 (dev/CI only)\n");
    w(out, "  5 early_uart_debug (EL2 window)\n");
    w(out, "  6 (closed) SHM rides channel-pair grants\n");
    w(out, "  7 single kernel-spawned cell (lamina)\n");

    w(out, "graph:\n");
    dump(out);
}
