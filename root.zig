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

// Hand-written modules (lib/man/)
pub const net_shm = @import("man/net_shm.zig");
pub const net_api = @import("man/net_api.zig");
pub const virtio = @import("man/virtio.zig");
pub const init_api = @import("man/init_api.zig");
pub const net_protocol = @import("man/net_protocol.zig");
pub const http = @import("man/http.zig");
pub const console = @import("man/console.zig");
pub const platform = @import("man/platform.zig");
pub const heap = @import("man/heap.zig");
pub const tasks = @import("man/tasks.zig");

// Generated modules (lib/gen/) - from kernel tables
pub const syscalls = @import("gen/syscalls.zig");
pub const errors = @import("gen/errors.zig");

// Shared modules (lib/shared/) - synced from src/shared/
pub const va_layout = @import("shared/va_layout.zig");
pub const barriers = @import("shared/arch/barriers_el0.zig");
pub const idle = @import("shared/arch/idle_el0.zig");
pub const container_info = @import("shared/arch/container_info.zig");
pub const compat = @import("shared/compat/table.zig");
pub const platform_table = @import("shared/platform/table.zig");
pub const icc_schema = @import("shared/icc/schema.zig");
pub const filetypes = @import("shared/filetypes.zig");

// Shared protocol specifications (build.zig provides module mapping)
pub const net_stack_protocol = @import("net_stack_protocol");
pub const platform_types = @import("platform_types");
pub const PlatformType = platform_types.PlatformType;

/// Check if a return value is an error code
pub const isError = errors.isError;

// Re-export getContainerId for convenience (zero-syscall via TPIDRRO_EL0)
pub const getContainerId = container_info.getContainerId;
