const std = @import("std");

pub fn addDependencyModule(
    b: *std.Build,
    comptime name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const dep = b.dependency(name, .{
        .target = target,
        .optimize = optimize,
    });

    return dep.module(name);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "zlm", .module = addDependencyModule(b, "zlm", target, optimize) },
    };

    _ = b.addModule("fey_asset", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
}
