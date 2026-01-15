const std = @import("std");
const reader_helpers = @import("reader_helpers.zig");

const takeBytes = reader_helpers.takeBytes;

pub const FBXFile = struct {
    version: u32,
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !FBXFile {
    _ = allocator;
    _ = path;
    return FBXFile{ .version = 0 };
}
