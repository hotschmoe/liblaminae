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
    mod.addImport("init_protocol", b.createModule(.{
        .root_source_file = b.path("shared/icc/protocols/init.zig"),
    }));
    mod.addImport("platform_protocol", b.createModule(.{
        .root_source_file = b.path("shared/icc/protocols/platform.zig"),
    }));
    mod.addImport("blk_protocol", b.createModule(.{
        .root_source_file = b.path("shared/icc/protocols/blk.zig"),
    }));
    mod.addImport("wasm_protocol", b.createModule(.{
        .root_source_file = b.path("shared/icc/protocols/wasm3.zig"),
    }));
    mod.addImport("platform_types", b.createModule(.{
        .root_source_file = b.path("shared/platform_types.zig"),
    }));
}
