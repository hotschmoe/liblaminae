const std = @import("std");

pub fn build(b: *std.Build) void {
    // Configure for bare-metal aarch64 (Laminae OS)
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Hardcode ReleaseSmall for bare-metal (size-critical)
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    // Get liblaminae dependency (note: it doesn't accept target/optimize options)
    const liblaminae = b.dependency("liblaminae", .{});

    // Create the bare-metal executable for Laminae OS
    const exe = b.addExecutable(.{
        .name = "big_counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Import liblaminae module (the module is named "laminae_lib" in their build.zig)
    exe.root_module.addImport("liblaminae", liblaminae.module("laminae_lib"));

    // Use the Laminae OS user-space linker script
    exe.setLinkerScript(b.path("user.ld"));

    // Install the ELF artifact
    b.installArtifact(exe);

    // Extract raw binary using objcopy (Laminae OS needs .bin, not ELF)
    const objcopy = b.addObjCopy(exe.getEmittedBin(), .{
        .format = .bin,
    });

    // Install the .bin file
    const bin_install = b.addInstallBinFile(objcopy.getOutput(), "big_counter.bin");
    b.getInstallStep().dependOn(&bin_install.step);

    // Create a step to output the binary location
    const install_step = b.getInstallStep();
    const print_step = b.step("build", "Build the counter demo for Laminae OS");
    print_step.dependOn(install_step);
}
