const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.addModule("liblaminae", .{
        .root_source_file = b.path("root.zig"),
    });

    // Add shared modules for standalone builds
    // (In-tree builds get these from the main build.zig)
    mod.addImport("net_stack_protocol", b.createModule(.{
        .root_source_file = b.path("shared/icc/net_stack_protocol.zig"),
    }));
    mod.addImport("platform_types", b.createModule(.{
        .root_source_file = b.path("shared/platform_types.zig"),
    }));
}
