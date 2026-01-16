const std = @import("std");
const helpers = @import("helpers.zig");

const takeBytes = helpers.takeBytes;

pub const FBXPropertyDataType = union(enum) {
    StringBinary: []u8, //'R'
    String: []u8, //'S'
    ArrayFloat: []f32, //'f'
    ArrayDouble: []f64, //'d'
    ArrayLong: []i64, //'l'
    ArrayInteger: []i32, //'i'
    ArrayBool: []u8, //'b'
    Short: i16, //'Y'
    Bool: bool, //'C'
    Integer: i32, //'I'
    Float: f32, //'F'
    Double: f64, //'D'
    Long: i64, //'L'
    Empty: void,
};

pub const FBXPropertyType = u8;

pub const FBXProperty = struct {
    record_type: FBXPropertyType,
    data: FBXPropertyDataType,

    // pub fn DataType(self: FBXProperty) type {
    //     return switch (self.record_type) {
    //         'R' => []u8,
    //         'S' => []u8,
    //         'f' => []f32,
    //         'd' => []f64,
    //         'l' => []i64,
    //         'i' => []i32,
    //         'b' => []u1,
    //         'Y' => i16,
    //         'C' => u1,
    //         'I' => i32,
    //         'F' => f32,
    //         'D' => f64,
    //         'L' => i64,
    //         else => unreachable,
    //     };
    // }
};

pub const FBXNode = struct {
    end_offset: u32,
    num_properties: u32,
    property_list_len: u32,
    name_len: u8,
    name: []u8,
    properties: std.ArrayList(FBXProperty) = .empty,
    children: std.StringHashMap(FBXNode),
};

pub const FBXFile = struct {
    version: u32,
};

const FBXArrayInfo = struct {
    length: u32,
    encoding: u32,
    compressed_length: u32,

    pub fn skipIfEncoded(self: FBXArrayInfo, allocator: std.mem.Allocator, reader: *std.Io.Reader) !bool {
        if (self.encoding == 1) {
            _ = try takeBytes(allocator, reader, self.compressed_length); // skip compressed data for now
            return true;
        } else return false;
    }
};

fn readArrayInfo(reader: *std.Io.Reader) !FBXArrayInfo {
    const length: u32 = try reader.takeInt(u32, .little);
    const encoding = try reader.takeInt(u32, .little);
    const compressed_length = try reader.takeInt(u32, .little);

    return FBXArrayInfo{
        .length = length,
        .encoding = encoding,
        .compressed_length = compressed_length,
    };
}

fn decompressArray(allocator: std.mem.Allocator, compressed: []u8, comptime T: type) ![]T {
    var fbs = std.Io.Reader.fixed(compressed);

    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&fbs, .zlib, &buffer);

    var decompressed: std.ArrayList(u8) = .empty;
    try decompress.reader.appendRemaining(allocator, &decompressed, .unlimited);
    defer decompressed.deinit(allocator);

    const count = decompressed.items.len / @sizeOf(T);
    const array = try allocator.alloc(T, count);

    const bytes = decompressed.items;

    const bit_size_of_t = @bitSizeOf(T);
    const IntType = switch (bit_size_of_t) {
        8 => u8,
        32 => u32,
        64 => u64,
        else => unreachable,
    };

    for (array, 0..) |*out, i| {
        const chunk = bytes[i * bit_size_of_t / 8 ..][0 .. bit_size_of_t / 8];
        const bits = std.mem.readInt(IntType, chunk, .little);
        out.* = @bitCast(bits);
    }

    return array;
}

fn readArray(allocator: std.mem.Allocator, reader: *std.Io.Reader, comptime T: type) ![]T {
    const array_info = try readArrayInfo(reader);
    var array: []T = undefined;
    if (array_info.encoding == 1) {
        const compressed = try takeBytes(allocator, reader, array_info.compressed_length);
        array = try decompressArray(allocator, compressed, T);
    } else {
        const bit_size_of_t = @bitSizeOf(T);
        const IntType = switch (bit_size_of_t) {
            8 => u8,
            32 => u32,
            64 => u64,
            else => unreachable,
        };

        array = try allocator.alloc(T, array_info.length);
        for (0..array_info.length) |i| {
            array[i] = @bitCast(try reader.takeInt(IntType, .little));
        }
    }

    return array;
}

fn readProperty(allocator: std.mem.Allocator, reader: *std.Io.Reader) !FBXProperty {
    const property_record_type: FBXPropertyType = try reader.takeInt(FBXPropertyType, .little);

    var data: ?FBXPropertyDataType = null;
    switch (property_record_type) {
        // special
        'R' => {
            const length = try reader.takeInt(u32, .little);
            const binary_string = try takeBytes(allocator, reader, length);
            data = FBXPropertyDataType{ .StringBinary = binary_string };
        },
        'S' => {
            const length = try reader.takeInt(u32, .little);
            const string = try takeBytes(allocator, reader, length);
            data = FBXPropertyDataType{ .String = string };
        },
        // arrays
        'f' => {
            //    []f32
            const array = try readArray(allocator, reader, f32);
            data = FBXPropertyDataType{ .ArrayFloat = array };
        },
        'd' => {
            const array = try readArray(allocator, reader, f64);
            data = FBXPropertyDataType{ .ArrayDouble = array };
        },
        'l' => {
            //    []i64
            const array = try readArray(allocator, reader, i64);
            data = FBXPropertyDataType{ .ArrayLong = array };
        },
        'i' => {
            //    []i32
            const array = try readArray(allocator, reader, i32);
            data = FBXPropertyDataType{ .ArrayInteger = array };
        },
        'b' => {
            //    []u8
            const array = try readArray(allocator, reader, i32);
            data = FBXPropertyDataType{ .ArrayBool = array };
        },
        'Y' => {
            const s = try reader.takeInt(i16, .little);
            data = FBXPropertyDataType{ .Short = s };
        },
        'C' => {
            const raw = try reader.takeInt(i8, .little);
            const b: bool = raw & -raw == 1;
            data = FBXPropertyDataType{ .Bool = b };
        },
        'I' => {
            const i = try reader.takeInt(i32, .little);
            data = FBXPropertyDataType{ .Integer = i };
        },
        'F' => {
            const raw = try reader.takeInt(u32, .little);
            const f: f32 = @bitCast(raw);
            data = FBXPropertyDataType{ .Float = f };
        },
        'D' => {
            const raw = try reader.takeInt(u64, .little);
            const d: f64 = @bitCast(raw);
            data = FBXPropertyDataType{ .Double = d };
        },
        'L' => {
            const l = try reader.takeInt(i64, .little);
            data = FBXPropertyDataType{ .Long = l };
        },
        else => unreachable,
    }

    if (data == null) {
        data = .Empty;
    }

    return FBXProperty{ .record_type = property_record_type, .data = data.? };
}

fn readNode(allocator: std.mem.Allocator, reader: *std.Io.Reader, reader_pos: *u64) !FBXNode {
    const end_offset = reader.takeInt(u32, .little) catch |err| return err;
    reader_pos.* += 4;
    const num_properties = reader.takeInt(u32, .little) catch |err| return err;
    reader_pos.* += 4;
    const property_list_len = reader.takeInt(u32, .little) catch |err| return err;
    reader_pos.* += 4;
    const name_len = reader.takeInt(u8, .little) catch |err| return err;
    reader_pos.* += 1;
    const name = takeBytes(allocator, reader, name_len) catch |err| return err;
    reader_pos.* += name_len;

    var node = FBXNode{
        .end_offset = end_offset,
        .num_properties = num_properties,
        .property_list_len = property_list_len,
        .name_len = name_len,
        .name = name,
        .children = std.StringHashMap(FBXNode).init(allocator),
    };

    if (node.isEmpty()) {
        return node;
    }

    // read properties
    for (0..node.num_properties) |_| {
        try node.properties.append(allocator, try readProperty(allocator, reader));
    }
    reader_pos.* += node.property_list_len;

    // read child node
    if (node.end_offset > reader_pos.*) {
        while (readNode(allocator, reader, reader_pos)) |child_node| {
            if (child_node.isEmpty())
                break;

            try node.children.put(child_node.name, child_node);
        } else |err| {
            return err;
        }
    }

    // skip to the end
    if (node.end_offset > reader_pos.*) {
        const bytes_left = node.end_offset - reader_pos.*;
        _ = try takeBytes(allocator, reader, bytes_left);
        reader_pos.* += node.end_offset;
    }

    return node;
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !FBXFile {
    var buffer: [256]u8 = undefined;
    var file: std.fs.File = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    var reader: std.fs.File.Reader = file.reader(&buffer);
    _ = try takeBytes(allocator, &reader.interface, 21);
    _ = try takeBytes(allocator, &reader.interface, 2);
    const version = try reader.interface.takeInt(u32, .little);

    var result = FBXFile{
        .version = version,
        .nodes = std.StringHashMap(FBXNode).init(allocator),
    };

    const reader_pos: *u64 = try allocator.create(u64);
    defer allocator.destroy(reader_pos);
    reader_pos.* = reader.logicalPos();
    while (readNode(allocator, &reader, reader_pos)) |node| {
        const end = node.isEmpty();
        if (end) break;
        try result.nodes.put(node.name, node);
    } else |err| {
        switch (err) {
            std.Io.Reader.Error.EndOfStream => {
                std.debug.print("FBX File reached the end!\n", .{});
            },
            else => return err,
        }
    }

    return result;
}
