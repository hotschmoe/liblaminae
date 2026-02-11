# Kitchen Sink Demo — Recommendations for Kernel & Userspace Teams

**Date:** 2026-02-10  
**Binary:** `kitchen_sink.bin` (6,494 bytes)  
**Runtime:** 9.2ms on QEMU virt, Laminae v0.38.2  
**Tested:** 27 syscalls + 7 zero-syscall operations across 13 phases

---

## 1. Error Codes Need Context — The Biggest Gap

### The Problem

Three phases returned `0xffffffffffffffea` (-22, EINVAL) or `0xfffffffffffffff3` (-13, EACCES), and from userspace it was **not obvious why**:

| Syscall | Error | Actual Reason (guessed) | What the user sees |
|---------|-------|------------------------|-------------------|
| `map_attach` | -22 | App containers can't attach SHM? | "ERR ffffffffffffffea" |
| `fs_open(..., CREATE)` | -22 | App containers can't create files? Or `/tmp` isn't writable? | Same opaque hex |
| `device_graph_count` | -13 | Device graph is driver-only? | "ERR fffffffffffffff3" |

The error values are raw negated errno-style constants. A userspace developer hitting these has **zero** diagnostic information about *why* it failed — was it a permissions issue? A missing capability? An invalid argument? A feature not implemented yet?

### Recommendations

**Kernel-side (short term):**
- Add a `sys_strerror(code)` or `sys_errdesc(code, buf, len)` syscall that returns a human-readable string for an error code. Even short strings like `"EPERM: no SHM cap"` would be transformative for debugging.
- Alternatively, expand `errors.zig` in liblaminae to include a full error enum with named constants (not just `ERROR_BASE`), so userspace can at least `switch` on known error values and print meaningful names.

**Kernel-side (medium term):**
- Consider a per-container **last-error-detail** register (similar to Windows `GetLastError` + `FormatMessage`). When a syscall fails, the kernel writes a detail code to a known memory location (like how `TPIDRRO_EL0` works for container ID). This would be zero-syscall error context.
- The detail could be a simple enum: `permission_denied`, `not_implemented`, `invalid_capability`, `resource_exhausted`, `invalid_argument`, etc.

**liblaminae-side (immediate):**
- `errors.zig` should define named constants for common error codes:
  ```zig
  pub const EPERM  = ERROR_BASE | 1;   // Operation not permitted
  pub const ENOENT = ERROR_BASE | 2;   // No such file or directory
  pub const EACCES = ERROR_BASE | 13;  // Permission denied  
  pub const EINVAL = ERROR_BASE | 22;  // Invalid argument
  pub const ENOSYS = ERROR_BASE | 38;  // Function not implemented
  ```
- Add a `pub fn errorName(code: u64) []const u8` function that returns `"EINVAL"`, `"EACCES"`, etc.

---

## 2. Sleep Resolution Anomaly

### Observation

```
sleep(10ms): 0.0ms
```

`sys.sleep(10_000_000)` (10ms in nanoseconds) returned with `get_time()` showing essentially zero elapsed time. Two possible explanations:

1. **Timer resolution issue** — `get_time()` returns coarse ticks and the sleep actually happened but the timer didn't advance enough to register at the ms granularity we printed.
2. **Sleep returned immediately** — the scheduler decided not to actually block, maybe because there was nothing else to schedule.

### Recommendation

- The kernel should guarantee that `sleep(N)` blocks for **at least** `N` nanoseconds. If nothing else is runnable, WFI until the timer fires.
- Consider documenting the minimum sleep granularity (tick period). If the timer tick is, say, 10ms, then sleep(10ms) might return after 0-10ms depending on phase alignment. This is normal RTOS behavior but should be documented.
- The kitchen sink's yield benchmark showed `get_time()` has ~8μs resolution (back-to-back delta was 8,288ns). So sleep(10ms) reading as 0.0ms can't be a resolution issue at the ms level — this looks like sleep returned too early.

---

## 3. Capability Visibility

### The Problem

When `device_graph_count()` returns EACCES, the container has no way to know **what capabilities it has**. It can only discover them by trial-and-error across every syscall.

### Recommendations

- Add a `sys_get_capabilities()` syscall that returns a bitmask of the container's granted capabilities. Something like:
  ```
  bit 0: CONSOLE_WRITE
  bit 1: HEAP_BRK
  bit 2: NAMESPACE
  bit 3: SHM_CREATE
  bit 4: SHM_ATTACH
  bit 5: FS_READ
  bit 6: FS_WRITE
  bit 7: DEVICE_GRAPH
  bit 8: IRQ_REGISTER
  bit 9: DEVICE_MAP
  bit 10: CONTAINER_SPAWN
  bit 11: CONTAINER_KILL
  ```
- This lets containers introspect their own privilege level and present useful output like *"Skipping device graph — no DEVICE_GRAPH capability"* instead of crashing into opaque errors.

---

## 4. What to Add Next — Logical Next Steps

### Tier 1: Low-Hanging Fruit (builds on what already works)

1. **`container_log_read` returned 0 bytes for our own container.** This makes sense if the container hasn't written to its own log yet, but it means there's no way for a container to read its *own* output. Consider: should `container_log_read(self)` return the console ring contents? That would be a useful debugging tool.

2. **ICC (Inter-Container Communication) demo.** We have `icc_send`/`icc_recv` syscalls and the full message schema defined, but we didn't test them because you need a second container to talk to. The logical next step:
   - Build a **two-container demo**: a "ping" container and a "pong" container
   - ping sends ICC message type 1 (PING), pong responds with type 2 (PONG)
   - This would validate the entire ICC path end-to-end

3. **`ns_wait` with timeout.** We tested `ns_register` and `ns_lookup` but not `ns_wait`. The wait syscall blocks until a named service appears — this is the foundation for service dependency ordering. Worth testing in a multi-container scenario.

### Tier 2: Infrastructure (makes future demos easier)

4. **File write support for app containers.** `fs_open` with CREATE failed. If app containers could write to `/tmp`, it opens up:
   - Persistent state between container restarts
   - Inter-container data exchange via filesystem
   - Log files, config files, etc.
   - Even if it's a simple ramfs, writable `/tmp` is high value

5. **Read from stdin.** `sys.read(0, ...)` for interactive containers. Right now output works great (console ring + write syscall), but there's no tested input path. This would enable:
   - Interactive demos
   - Shell-like applications running as containers
   - Game-like programs

### Tier 3: Advanced (where things get really interesting)

6. **SHM between containers.** `map_create` succeeded but `map_attach` failed with EINVAL. If app containers could share memory regions, combined with ICC for signaling, you'd have:
   - High-throughput zero-copy data transfer between containers
   - Producer/consumer patterns
   - Lock-free ring buffers between containers (your net stack already does this for driver↔stack)

7. **Cooperative tasks + ICC.** The task scheduler works in-process. Combined with ICC, a single container could multiplex handling messages from multiple peers — this is the pattern for building actual services.

8. **`get_crash_telemetry`** — we have the syscall but didn't test it. Building an auto-diagnostics container that watches for peer crashes and collects telemetry would be a great reliability story.

---

## 5. liblaminae Compatibility Issue

### Observation

`heap.allocator` (the Zig `std.mem.Allocator` interface) doesn't compile with Zig 0.15.2 because the `VTable` signature changed — `u8` for alignment became `mem.Alignment`. This means any container trying to use `heap.allocator` with `std.ArrayList`, `std.StringHashMap`, etc. will fail to compile.

### Recommendation

- Update the `VTable` in `heap.zig` to use the new Zig 0.15 `mem.Alignment` type
- This is blocking for any non-trivial container that wants dynamic data structures
- Consider pinning the liblaminae minimum Zig version and testing against it in CI

---

## 6. Binary Size & Transfer Constraints

### Observation

The 8KB transfer limit is a real constraint. Our initial build with `console.printf` (which pulls in `std.fmt`) produced a **103KB** binary. The working build avoids all `std` imports and came in at **6.5KB**.

### Recommendations

- **Document the "no std.fmt" rule** prominently in liblaminae. Any container developer who calls `console.printf` will blow past the transfer limit without understanding why.
- Consider making `console.printf` opt-in behind a build flag, or moving it to a separate module that's not imported by default.
- Long-term: increase the transfer limit or add chunked transfer support. 8KB is fine for demos but will be tight for real applications.

---

## 7. Quick Wins Summary

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 🔴 P0 | Named error constants in liblaminae `errors.zig` | 1 hour | Huge developer experience improvement |
| 🔴 P0 | Fix `heap.zig` VTable for Zig 0.15 | 30 min | Unblocks dynamic data structures |
| 🟡 P1 | `sys_get_capabilities()` syscall | 1 day | Enables graceful degradation |
| 🟡 P1 | Investigate sleep(10ms) returning immediately | 1 hour | Timer correctness |
| 🟡 P1 | Writable `/tmp` for app containers | 1 day | Enables persistent state |
| 🟢 P2 | ICC ping/pong two-container demo | 2 hours | Validates IPC path |
| 🟢 P2 | `sys_strerror` or error detail register | 1 day | Zero-cost error diagnostics |
| 🟢 P2 | Document binary size constraints | 30 min | Prevents developer frustration |

---

*Generated from kitchen_sink demo results on Laminae v0.38.2, QEMU virt platform.*
