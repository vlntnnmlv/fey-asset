const std = @import("std");
const zlm = @import("zlm").as(f32);
const fbx = @import("fbx.zig");

const FBXFile = fbx.FBXFile;
const FBXFormatError = fbx.FBXFormatError;

test "fbx_load" {
    const allocator = std.testing.allocator;

    var cube = try FBXFile.init(allocator, "test/cube.fbx");
    defer cube.deinit();
}

test "fbx_load_ascii" {
    const allocator = std.testing.allocator;

    var maybe_rock: FBXFile = FBXFile.init(allocator, "test/rock_ascii.fbx") catch |err| {
        return try std.testing.expectEqual(FBXFormatError.FBXIsNotBinaryEncoded, err);
    };
    maybe_rock.deinit();
}

test "fbx_data" {
    const allocator = std.testing.allocator;

    var cube = try FBXFile.init(allocator, "test/cube_tr.fbx");
    defer cube.deinit();

    const vertices = try cube.vertices(allocator);
    defer allocator.free(vertices);
}

test "fbx_data_array_list" {
    const allocator = std.testing.allocator;

    var cube = try FBXFile.init(allocator, "test/cube_tr.fbx");
    defer cube.deinit();

    const vertices = try cube.vertices(allocator);

    var verticies_list: std.ArrayList(zlm.Vec3) = .empty;
    defer allocator.free(vertices);

    try verticies_list.appendSlice(allocator, vertices);
    defer verticies_list.deinit(allocator);
}
