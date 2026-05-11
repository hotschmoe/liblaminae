//------------------------------------------------------------------------------
// Laminae User Library - Module Entry Point
//------------------------------------------------------------------------------
// Root module for the laminae user-space library.
// User programs import via @import("liblaminae").
//
// Usage:
//   const lib = @import("liblaminae");
//   lib.syscalls.write(1, buf, len);
//   lib.va_layout.HEAP_VA_BASE;
//------------------------------------------------------------------------------

// T1 vocabulary modules (lib/man/) — pure, peer-free, T0 syscalls only
pub const console = @import("man/console.zig");
pub const heap = @import("man/heap.zig");
pub const tasks = @import("man/tasks.zig");
pub const fwcfg = @import("man/fwcfg.zig");
pub const virtio = @import("man/virtio.zig");
pub const socket_shm = @import("man/socket_shm.zig");
pub const net_shm = @import("man/net_shm.zig");
pub const net_protocol = @import("man/net_protocol.zig");
pub const rpc = @import("man/rpc.zig");
pub const http = @import("man/http.zig");
pub const socket_stream = @import("man/socket_stream.zig");

// T2 RPC client modules — thin clients of named peer containers
pub const init_client = @import("init_client/api.zig");
pub const init_protocol = @import("init_protocol");
pub const platform_client = @import("platform_client/api.zig");
pub const platform_protocol = @import("platform_protocol");
pub const blk_client = @import("blk_client/api.zig");
pub const blk_protocol = @import("blk_protocol");
pub const wasm_client = @import("wasm_client/api.zig");
pub const wasm_protocol = @import("wasm_protocol");
pub const net_client = @import("net_client/api.zig");
pub const http_client = @import("net_client/http_transport.zig");

// Generated modules (lib/gen/) - from kernel tables
pub const syscalls = @import("gen/syscalls.zig");
pub const errors = @import("gen/errors.zig");

// Shared modules (lib/shared/) - synced from src/shared/
pub const shm = @import("shared/shm.zig");
pub const va_layout = @import("shared/va_layout.zig");
pub const barriers = @import("shared/arch/barriers_el0.zig");
pub const idle = @import("shared/arch/idle_el0.zig");
pub const container_info = @import("shared/arch/container_info.zig");
pub const compat = @import("shared/compat/table.zig");
pub const platform_table = @import("shared/platform/table.zig");
pub const icc_schema = @import("shared/icc/schema.zig");
pub const filetypes = @import("shared/filetypes.zig");
pub const container_type = @import("shared/container_type.zig");
pub const ContainerType = container_type.ContainerType;

// Shared protocol specifications (build.zig provides module mapping)
pub const net_stack_protocol = @import("net_stack_protocol");
pub const platform_types = @import("platform_types");
pub const PlatformType = platform_types.PlatformType;

/// Check if a return value is an error code
pub const isError = errors.isError;

// Re-export getContainerId for convenience (zero-syscall via TPIDRRO_EL0)
pub const getContainerId = container_info.getContainerId;

// Tier-contract audit (contracts follow-up item 3). Comptime-only -- the
// import forces _audit.zig's comptime block to evaluate, which asserts
// every lib/man/*.zig module declares the right `pub const tier: u8`.
comptime {
    _ = @import("_audit.zig");
}
