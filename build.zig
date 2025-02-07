const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "clipboard",
        .root_source_file = .{ .path = "src/clipboard.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Link X11 and related libraries
    lib.linkSystemLibrary("X11");
    lib.linkLibC();

    b.installArtifact(lib);
}
