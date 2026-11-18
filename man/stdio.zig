//------------------------------------------------------------------------------
// stdio -- pipe-aware standard I/O for cells (T1 vocabulary)
//
// Binds a cell's byte-stream input/output to pipe regions (shared/pipe.zig)
// when a supervisor wired them via the reserved "--lmn-stdio=<in>:<out>"
// argv entry, and falls through to the per-cell console rings otherwise.
// Programs that call stdio.init() in _start participate in shell pipelines;
// programs that don't keep today's console behavior everywhere.
//
//   export fn _start(argc: u64, argv: [*]const u64) noreturn {
//       const nargs = stdio.init(argc, argv);
//       ... use stdio.print / stdio.read ...
//       stdio.exit(0);
//   }
//
// Blocking discipline: all parks are bounded (PARK_NS) and re-check the
// ring and closed flags on every iteration -- a lost wake degrades to one
// park interval, never a hang. Snapshot rule for ring_arm: the snapshot is
// the OPPOSITE side's index as last observed (consumer snapshots head,
// producer snapshots tail); the kernel fast path re-reads that index and
// wakes on any difference (RE.8).
//------------------------------------------------------------------------------

const sys = @import("../gen/syscalls.zig");
const errors = @import("../gen/errors.zig");
const pipe = @import("../shared/pipe.zig");
const barriers = @import("../shared/arch/barriers_el0.zig");
const console = @import("console.zig");

pub const tier: u8 = 1;

/// Bounded park interval. Also the crash-detection floor when the
/// supervisor-side reaper (rather than the kernel) reports a dead peer.
const PARK_NS: u64 = 100_000_000;

pub const WriteError = error{BrokenPipe};

const Endpoint = struct {
    region: *volatile pipe.PipeRegion,
    token: u32,
};

var in_ep: ?Endpoint = null;
var out_ep: ?Endpoint = null;
var out_broken: bool = false;

fn strLen(p: [*:0]const u8) usize {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return n;
}

fn attach(cap: pipe.StdioCap) ?Endpoint {
    const res = sys.map_attach(cap.ep, cap.grant_ref, 1);
    if (errors.isError(res)) return null;
    const region: *volatile pipe.PipeRegion = @ptrFromInt(sys.MapResult.va(res));
    if (!region.header.validate()) return null;
    return .{ .region = region, .token = sys.MapResult.token(res) };
}

fn bindSide(spec: []const u8, ep: *?Endpoint) bool {
    if (spec.len == 1 and spec[0] == pipe.UNBOUND) return true;
    const packed_cap = pipe.decodeHandle(spec) orelse return false;
    const cap = pipe.unpackCap(packed_cap);
    if (cap.ep == 0 or cap.grant_ref == 0) return false;
    // Supervisor chan_grants after spawn returns; on SMP we may run first.
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        if (attach(cap)) |got| {
            ep.* = got;
            return true;
        }
        _ = sys.wait_event(0, 0, 2_000_000);
    }
    return false;
}

/// Parse and strip the reserved stdio argv entry (always last, by
/// convention). Returns the argc the program should use. A malformed or
/// unattachable wiring is a supervisor bug: fail loudly rather than run
/// unwired inside a pipeline that will hang waiting on us.
pub fn init(argc: u64, argv: [*]const u64) u64 {
    if (argc == 0) return 0;
    const last: [*:0]const u8 = @ptrFromInt(argv[argc - 1]);
    const arg = last[0..strLen(last)];
    if (arg.len < pipe.ARGV_PREFIX.len) return argc;
    for (pipe.ARGV_PREFIX, 0..) |c, i| {
        if (arg[i] != c) return argc;
    }

    const spec = arg[pipe.ARGV_PREFIX.len..];
    var colon: ?usize = null;
    for (spec, 0..) |c, i| {
        if (c == ':') {
            colon = i;
            break;
        }
    }
    const ok = if (colon) |pos|
        bindSide(spec[0..pos], &in_ep) and bindSide(spec[pos + 1 ..], &out_ep)
    else
        false;
    if (!ok) {
        console.print("[stdio] bad --lmn-stdio wiring, exiting\n");
        sys.exit(127);
    }
    return argc - 1;
}

pub fn inBound() bool {
    return in_ep != null;
}

pub fn outBound() bool {
    return out_ep != null;
}

/// True once a write observed reader hangup. print() swallows BrokenPipe;
/// long-running producers should poll this and stop.
pub fn outBroken() bool {
    return out_broken;
}

/// Supervisor-owned pipe: local mapping + unwired chan_create pair with the
/// region granted on both ends. Caller chan_grants `out_ep` to the writer
/// and/or `in_ep` to the reader after spawn, and packs argv with
/// `pipe.packCap(ep, grant_ref)`.
pub const Pipe = struct {
    region: *volatile pipe.PipeRegion,
    token: u32,
    out_ep: u32,
    in_ep: u32,
    grant_ref: u32,
};

pub fn createPipe() ?Pipe {
    var out_tok: u32 = 0;
    var in_tok: u32 = 0;
    if (sys.chan_create(pipe.STDIO_CONTRACT_HASH, pipe.STDIO_CONTRACT_VERSION, &out_tok, &in_tok) != 0)
        return null;
    const res = sys.map_create(pipe.REGION_PAGES, 0);
    if (errors.isError(res)) {
        _ = sys.chan_close(out_tok);
        _ = sys.chan_close(in_tok);
        return null;
    }
    const token = sys.MapResult.token(res);
    const grant = sys.map_bind(token, out_tok);
    if (errors.isError(grant) or grant == 0) {
        _ = sys.map_detach(token);
        _ = sys.chan_close(out_tok);
        _ = sys.chan_close(in_tok);
        return null;
    }
    const region: *volatile pipe.PipeRegion = @ptrFromInt(sys.MapResult.va(res));
    region.init(@truncate(sys.get_cell_id()));
    return .{
        .region = region,
        .token = token,
        .out_ep = out_tok,
        .in_ep = in_tok,
        .grant_ref = @truncate(grant),
    };
}

pub fn destroyPipe(p: Pipe) void {
    p.region.status.writer_closed = 1;
    p.region.status.reader_closed = 1;
    _ = sys.ring_wake(p.token, 0);
    _ = sys.ring_wake(p.token, 1);
    _ = sys.map_detach(p.token);
    _ = sys.chan_close(p.out_ep);
    _ = sys.chan_close(p.in_ep);
}

fn park(ep: Endpoint, snapshot: u32, direction: u32) enum { again, closed } {
    const arm_res = sys.ring_arm(ep.token, @intFromPtr(&ep.region.ring), snapshot, direction);
    if (errors.isError(arm_res)) return .closed;
    return switch (sys.wait_event(0, 0, PARK_NS)) {
        // Only .closed is terminal. peer_crashed is advisory by the kernel's
        // own contract ("re-derive; a peer died" -- scheduler.zig
        // signalRingPeerCrashed) and is delivered to the CELL, not scoped to
        // the region we parked on. A cell holding a stdio pipe generally holds
        // other regions too -- a session shell attaches socket SHM the moment
        // it makes an outbound request -- so treating it as terminal made an
        // unrelated peer's death look like our writer hanging up.
        //
        // That is what killed telnet sessions: the shell read EOF, printed
        // "session closed" and exit(0)'d moments after connecting, which
        // presented as "the session missed my first line" because the client
        // never got an answer to it.
        //
        // .again returns to the caller's re-check, which derives EOF from the
        // authoritative writer_closed flag instead. The RL.18 benefit is kept:
        // we still unpark immediately rather than waiting out PARK_NS.
        .closed => .closed,
        else => .again,
    };
}

/// Write the whole slice to the out pipe, blocking on backpressure.
/// error.BrokenPipe once the reader hung up or the region closed.
pub fn write(data: []const u8) WriteError!void {
    const ep = out_ep orelse {
        console.print(data);
        return;
    };
    var rest = data;
    while (rest.len > 0) {
        const n = ep.region.ring.write(rest);
        if (n > 0) {
            _ = sys.ring_wake(ep.token, 0);
            rest = rest[n..];
            continue;
        }
        if (ep.region.status.reader_closed != 0) {
            out_broken = true;
            return error.BrokenPipe;
        }
        const tail_snapshot = ep.region.ring.tail;
        if (ep.region.ring.freeBytes() == 0) {
            if (park(ep, tail_snapshot, 1) == .closed) {
                out_broken = true;
                return error.BrokenPipe;
            }
        }
    }
}

/// Pipe-or-console print. BrokenPipe is recorded (outBroken) and swallowed.
pub fn print(msg: []const u8) void {
    write(msg) catch {};
}

/// Read into buf from the in pipe. Blocks until at least one byte or EOF.
/// Returns 0 only at EOF (writer closed or region gone, ring drained).
/// Unbound stdin reads from the console stdin ring (never EOF).
pub fn read(buf: []u8) usize {
    if (buf.len == 0) return 0;
    const ep = in_ep orelse {
        buf[0] = console.readByteBlocking();
        return 1;
    };
    while (true) {
        const n = ep.region.ring.read(buf);
        if (n > 0) {
            _ = sys.ring_wake(ep.token, 1);
            return n;
        }
        if (ep.region.status.writer_closed != 0) {
            // Flag is set after the writer's final ring publish: one more
            // drain attempt closes the set-flag-then-write race.
            const n2 = ep.region.ring.read(buf);
            if (n2 > 0) {
                _ = sys.ring_wake(ep.token, 1);
                return n2;
            }
            return 0;
        }
        const head_snapshot = ep.region.ring.head;
        if (ep.region.ring.availableBytes() == 0) {
            if (park(ep, head_snapshot, 0) == .closed) return 0;
        }
    }
}

/// Read one byte; null at EOF.
pub fn readByte() ?u8 {
    var b: [1]u8 = undefined;
    if (read(&b) == 0) return null;
    return b[0];
}

/// Read one newline-terminated line (newline not stored); null at EOF with
/// nothing buffered. A line longer than buf is truncated (excess consumed).
pub fn readLine(buf: []u8) ?[]const u8 {
    var len: usize = 0;
    var got_any = false;
    while (true) {
        const b = readByte() orelse {
            if (!got_any) return null;
            return buf[0..len];
        };
        got_any = true;
        if (b == '\n') return buf[0..len];
        if (len < buf.len) {
            buf[len] = b;
            len += 1;
        }
    }
}

/// Signal EOF to the reader. Idempotent.
pub fn closeOut() void {
    if (out_ep) |ep| {
        ep.region.status.writer_closed = 1;
        barriers.dataMemoryBarrierInner();
        _ = sys.ring_wake(ep.token, 0);
    }
}

/// Hang up on the writer (its next blocked write gets BrokenPipe). Idempotent.
pub fn closeIn() void {
    if (in_ep) |ep| {
        ep.region.status.reader_closed = 1;
        barriers.dataMemoryBarrierInner();
        _ = sys.ring_wake(ep.token, 1);
    }
}

pub fn close() void {
    closeOut();
    closeIn();
}

/// Close both pipe ends, then exit. Pipe-aware programs exit through this
/// so downstream stages see EOF instead of waiting on the crash reaper.
pub fn exit(code: u64) noreturn {
    close();
    sys.exit(code);
}
