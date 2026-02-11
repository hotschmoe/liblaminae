# Big Counter - Laminae OS Demo

A counting demonstration program for [Laminae OS](https://github.com/hotschmoe/liblaminae), showcasing the OS's syscall interface and zero-syscall console output system.

## Overview

This is a bare-metal aarch64 program that demonstrates Laminae OS capabilities by:
- Counting from 0 to 100 with timing information
- Using multiple Laminae OS syscalls (get_time, sleep, get_container_id, get_platform)
- Demonstrating the zero-syscall console ring buffer system
- Providing performance statistics and console buffer metrics

## Features Showcased

### Syscalls Used
- **`get_container_id()`** - Retrieves the container's unique ID
- **`get_platform()`** - Gets the hardware platform identifier
- **`get_time()`** - Reads the system timer (nanoseconds since boot)
- **`sleep(ns)`** - Suspends execution for a specified duration
- **`exit(status)`** - Terminates the container with a status code

### Zero-Syscall Console
The demo uses Laminae OS's innovative **zero-syscall console output** system:
- Each container has a 64KB memory-mapped ring buffer
- Writing to the console requires **no syscalls** - just memory writes
- The kernel polls and drains the buffer to UART automatically
- ASID-isolated, so each container has its own output buffer

## Building

The project requires:
- **Zig 0.15.2** or later
- **aarch64-freestanding** target
- **liblaminae** dependency (fetched automatically)

```bash
# Build the demo
zig build

# Output binary location
zig-out/bin/big_counter
```

The build system:
1. Fetches `liblaminae` from GitHub (master branch)
2. Compiles for `aarch64-freestanding-none`
3. Links with `user.ld` (Laminae OS userspace linker script)
4. Produces a flat binary ready to load into the OS

## Running

To run this program, you need the Laminae OS kernel which will:
1. Load the `big_counter` binary into a container
2. Map the console ring buffer to the container's address space
3. Execute from the `_start` entry point
4. Monitor the console buffer and output to UART

## Architecture

### Entry Point
The program exports `_start` as the entry point (required by user.ld):
```zig
export fn _start() noreturn {
    mainDemo();
}
```

### Memory Layout
Defined by `user.ld`:
- Base address: `0x10000` (64KB, avoids null pointer region)
- Single `.all` section containing:
  - `.text._start` (entry point, must be first)
  - `.text*` (code)
  - `.rodata*` (read-only data)
  - `.data*` (initialized data)
  - `.bss*` (zero-initialized data)

### Console Output
All output uses the zero-syscall console system:
```zig
const console = lib.console;
console.print("Hello, Laminae!\n");
console.printNum(42);
console.printHex(0xDEADBEEF);
```

The console module provides:
- `print()` / `println()` - String output
- `printf()` - Formatted output
- `printNum()` / `printHex()` - Number output
- `flush()` - Force immediate UART output (uses yield syscall)
- Statistics: `getSequence()`, `getOverflowCount()`, `hasOverflowed()`

## Demo Output

When run, the program produces:
```
========================================
   BIG COUNTER - Laminae OS Demo
========================================

Container ID: 5
Platform: 0x1234
Boot time: 1500000000 ns

Starting counter...

Count: 0 | Elapsed: 100 ms
Count: 1 | Elapsed: 200 ms
...
Count: 10 | Elapsed: 1000 ms <<<
...
Count: 100 | Elapsed: 10000 ms

========================================
   Counter Complete!
========================================
Total counts: 100
Total time: 10000 ms
Average per count: 100 ms

Console stats:
  Bytes written: 2048
  Buffer overflows: 0

Exiting...
```

## Project Structure

```
big_counter/
├── build.zig         # Zig build configuration
├── build.zig.zon     # Dependency specification (liblaminae)
├── user.ld           # Laminae OS userspace linker script
├── src/
│   └── main.zig      # Counter demo implementation
├── example/          # Reference examples from Laminae OS
│   ├── user.ld       # Original linker script
│   ├── build_config.zig  # Kernel build system reference
│   └── program/
│       └── hello.zig # Minimal example
└── README.md         # This file
```

## Technical Details

### Target Triple
- **CPU**: aarch64 (ARMv8-A)
- **OS**: freestanding (no OS layer)
- **ABI**: none (bare-metal)

### Syscall Interface
Laminae OS uses the ARM64 SVC (Supervisor Call) instruction:
- Syscall number in `x8`
- Arguments in `x0-x5`
- Return value in `x0`

Example from liblaminae:
```zig
pub inline fn get_time() u64 {
    return svc0(@intFromEnum(Syscall.get_time));
}

inline fn svc0(num: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (num)
        : .{ .memory = true }
    );
}
```

### Console Ring Buffer
Defined in `liblaminae/man/console.zig`:
```zig
pub const ContainerConsole = ConsoleRing(64 * 1024 - 64);

pub fn ConsoleRing(comptime capacity: usize) type {
    return extern struct {
        // Header (64 bytes, cache-line aligned)
        write_idx: u32 = 0,
        read_idx: u32 = 0,
        sequence: u32 = 0,
        flags: ConsoleFlags = .{},
        overflow_count: u32 = 0,
        _header_padding: [44]u8 = [_]u8{0} ** 44,
        
        // Data region (65472 bytes)
        data: [capacity]u8 = [_]u8{0} ** capacity,
        
        // ...
    };
}
```

## Dependencies

- **liblaminae** (https://github.com/hotschmoe/liblaminae)
  - Version: master branch
  - Hash: `laminae_lib-0.35.8-AAAAAKy1AgC3kpfhxwLBStIlwpXI6RJen13FZm0yBEXT`
  - Provides: Syscall wrappers, console API, shared kernel/user types

## License

This demo is provided as an example for Laminae OS development.

## References

- [Laminae OS liblaminae](https://github.com/hotschmoe/liblaminae)
- [Zig Programming Language](https://ziglang.org/)
- [ARM Developer Documentation](https://developer.arm.com/architectures/learn-the-architecture/armv8-a-instruction-set-architecture)
