const std = @import("std");
const helpers = @import("helpers.zig");

const zlm = @import("zlm").as(f32);

const takeBytes = helpers.takeBytes;

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
    const array_info = try FBXArrayInfo.init(reader);
    var array: []T = undefined;
    if (array_info.encoding == 1) {
        const compressed = try takeBytes(allocator, reader, array_info.compressed_length);
        defer allocator.free(compressed);

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

const FBXArrayInfo = struct {
    length: u32,
    encoding: u32,
    compressed_length: u32,

    const Self = @This();

    pub fn init(reader: *std.Io.Reader) !Self {
        const length: u32 = try reader.takeInt(u32, .little);
        const encoding = try reader.takeInt(u32, .little);
        const compressed_length = try reader.takeInt(u32, .little);

        return Self{
            .length = length,
            .encoding = encoding,
            .compressed_length = compressed_length,
        };
    }

    pub fn skip(self: Self, allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
        _ = try takeBytes(allocator, reader, self.compressed_length); // skip compressed data
    }
};

pub const FBXProperty = struct {
    allocator: std.mem.Allocator,
    record_type: FBXPropertyType,
    data: FBXPropertyDataType,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Self {
        const property_record_type: FBXPropertyType = try reader.takeInt(FBXPropertyType, .little);
        var data: ?FBXPropertyDataType = null;
        switch (property_record_type) {
            'R' => {
                // []u8 binary encoded
                const length = try reader.takeInt(u32, .little);
                const binary_string = try takeBytes(allocator, reader, length);
                data = FBXPropertyDataType{ .StringBinary = binary_string };
            },
            'S' => {
                // []u8 string
                const length = try reader.takeInt(u32, .little);
                const string = try takeBytes(allocator, reader, length);
                data = FBXPropertyDataType{ .String = string };
            },
            'f' => {
                // []f32
                const array = try readArray(allocator, reader, f32);
                data = FBXPropertyDataType{ .ArrayFloat = array };
            },
            'd' => {
                // [] f64
                const array = try readArray(allocator, reader, f64);
                data = FBXPropertyDataType{ .ArrayDouble = array };
            },
            'l' => {
                // []i64
                const array = try readArray(allocator, reader, i64);
                data = FBXPropertyDataType{ .ArrayLong = array };
            },
            'i' => {
                // []i32
                const array = try readArray(allocator, reader, i32);
                data = FBXPropertyDataType{ .ArrayInteger = array };
            },
            'b' => {
                // []u8
                const array = try readArray(allocator, reader, u8);
                data = FBXPropertyDataType{ .ArrayBool = array };
            },
            'Y' => {
                // i16
                const s = try reader.takeInt(i16, .little);
                data = FBXPropertyDataType{ .Short = s };
            },
            'C' => {
                // bool
                const raw = try reader.takeInt(i8, .little);
                const b: bool = raw & -raw == 1;
                data = FBXPropertyDataType{ .Bool = b };
            },
            'I' => {
                // i32
                const i = try reader.takeInt(i32, .little);
                data = FBXPropertyDataType{ .Integer = i };
            },
            'F' => {
                // f32
                const raw = try reader.takeInt(u32, .little);
                const f: f32 = @bitCast(raw);
                data = FBXPropertyDataType{ .Float = f };
            },
            'D' => {
                // f64
                const raw = try reader.takeInt(u64, .little);
                const d: f64 = @bitCast(raw);
                data = FBXPropertyDataType{ .Double = d };
            },
            'L' => {
                // i64
                const l = try reader.takeInt(i64, .little);
                data = FBXPropertyDataType{ .Long = l };
            },
            else => unreachable,
        }

        return Self{
            .allocator = allocator,
            .record_type = property_record_type,
            .data = data.?,
        };
    }

    pub fn deinit(self: Self) void {
        switch (self.record_type) {
            'R' => self.allocator.free(self.data.StringBinary),
            'S' => self.allocator.free(self.data.String),
            'f' => self.allocator.free(self.data.ArrayFloat),
            'd' => self.allocator.free(self.data.ArrayDouble),
            'l' => self.allocator.free(self.data.ArrayLong),
            'i' => self.allocator.free(self.data.ArrayInteger),
            'b' => self.allocator.free(self.data.ArrayBool),
            else => {},
        }
    }
};

pub const FBXNode = struct {
    allocator: std.mem.Allocator,
    end_offset: u32,
    num_properties: u32,
    property_list_len: u32,
    name_len: u8,
    name: []u8,
    properties: std.ArrayList(FBXProperty) = .empty,
    children: std.StringHashMap(FBXNode),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader, reader_pos: *u64) !Self {
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

        var node = Self{
            .allocator = allocator,
            .end_offset = end_offset,
            .num_properties = num_properties,
            .property_list_len = property_list_len,
            .name_len = name_len,
            .name = name,
            .children = std.StringHashMap(FBXNode).init(allocator),
        };

        errdefer {
            allocator.free(node.name);
            node.properties.deinit(allocator);
            node.children.deinit();
        }

        if (node.isEmpty()) {
            return node;
        }

        // read properties
        for (0..node.num_properties) |_| {
            const property = try FBXProperty.init(allocator, reader);
            errdefer property.deinit();
            try node.properties.append(allocator, property);
        }
        reader_pos.* += node.property_list_len;

        // read child nodes
        if (node.end_offset > reader_pos.*) {
            while (FBXNode.init(allocator, reader, reader_pos)) |child_node| {
                var child_node_mut = child_node;
                if (child_node_mut.isEmpty()) {
                    child_node_mut.deinit();
                    break;
                }

                // TODO: Support multiple values on one key
                var key: []const u8 = undefined;
                if (node.children.getEntry(child_node.name)) |entry| {
                    var value_mut = entry.value_ptr.*;
                    value_mut.deinit();
                    key = entry.key_ptr.*;
                } else {
                    key = try allocator.dupe(u8, child_node.name);
                }

                try node.children.put(key, child_node);
            } else |err| {
                return err;
            }
        }

        // skip to the end
        if (node.end_offset > reader_pos.*) {
            const bytes_left = node.end_offset - reader_pos.*;
            const skip = try takeBytes(allocator, reader, bytes_left);
            allocator.free(skip);
            reader_pos.* += bytes_left;
        }

        return node;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);

        for (self.properties.items) |property| {
            property.deinit();
        }

        self.properties.deinit(self.allocator);

        var children_it = self.children.iterator();
        while (children_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }

        self.children.deinit();
    }

    pub fn isEmpty(self: Self) bool {
        return self.end_offset == 0 and self.num_properties == 0 and self.property_list_len == 0 and self.name_len == 0;
    }

    pub fn dump(self: Self, comptime depth: []const u8) void {
        if (depth.len > 64) {
            return;
        }

        std.debug.print("{s}<!{s}>\n", .{ depth, self.name });
        std.debug.print("{s}  <Properties>\n", .{depth});
        for (self.properties.items) |property| {
            std.debug.print("{s}    [{c}]: {any}\n", .{ depth, property.record_type, property.data });
        }
        std.debug.print("{s}  </Properties>\n", .{depth});
        std.debug.print("{s}  <Children>\n", .{depth});
        var children = self.children.valueIterator();
        while (children.next()) |child| {
            child.*.dump(depth ++ "  ");
        }
        std.debug.print("{s}  </!Children>\n", .{depth});
        std.debug.print("{s}<{s}/>\n", .{ depth, self.name });
    }
};

const FBXFormatError = error{
    FBXIsNotBinaryEncoded,
};

pub const FBXFile = struct {
    allocator: std.mem.Allocator,
    version: u32,
    children: std.StringHashMap(FBXNode),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        var buffer: [256]u8 = undefined;
        var file: std.fs.File = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        var reader: std.fs.File.Reader = file.reader(&buffer);
        const magic = try takeBytes(allocator, &reader.interface, 21);
        defer allocator.free(magic);
        const should_be = "Kaydara FBX Binary";
        if (magic.len < 21 or !std.mem.eql(u8, magic[0..18], should_be)) {
            return FBXFormatError.FBXIsNotBinaryEncoded;
        }

        const unknown = try takeBytes(allocator, &reader.interface, 2);
        defer allocator.free(unknown);
        const version = try reader.interface.takeInt(u32, .little);

        var result = Self{
            .allocator = allocator,
            .version = version,
            .children = std.StringHashMap(FBXNode).init(allocator),
        };
        // NO LEAKS ABOVE

        var reader_pos: u64 = reader.logicalPos();
        while (FBXNode.init(allocator, &reader.interface, &reader_pos)) |node| {
            var node_mut = node;
            if (node.isEmpty()) {
                node_mut.deinit();
                break;
            }

            const key = try allocator.dupe(u8, node.name);
            try result.children.put(key, node);
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

    pub fn vertices(self: Self, allocator: std.mem.Allocator) ![]zlm.Vec3 {
        const data = self.children.get("Objects").?.children.get("Geometry").?.children.get("Vertices").?.properties.items[0].data.ArrayDouble;
        const num_vertices = @divExact(data.len, 3);
        var result: []zlm.Vec3 = try allocator.alloc(zlm.Vec3, num_vertices);
        for (0..num_vertices) |i| {
            result[i] = zlm.Vec3{
                .x = @floatCast(data[i]),
                .y = @floatCast(data[i + 1]),
                .z = @floatCast(data[i + 2]),
            };
        }

        return result;
    }

    pub fn triangles(self: Self) []i32 {
        var data = self.children.get("Objects").?.children.get("Geometry").?.children.get("PolygonVertexIndex").?.properties.items[0].data.ArrayInteger;
        for (0..data.len) |i| {
            if (data[i] < 0)
                data[i] = ~data[i];
        }
        return data;
    }

    pub fn uvs(self: Self, allocator: std.mem.Allocator) ![]zlm.Vec2 {
        const data = self.children.get("Objects").?.children.get("Geometry").?.children.get("LayerElementUV").?.children.get("UV").?.properties.items[0].data.ArrayDouble;
        const num_uvs = @divExact(data.len, 2);
        var result: []zlm.Vec2 = try allocator.alloc(zlm.Vec2, num_uvs);
        for (0..num_uvs) |i| {
            result[i] = zlm.Vec2{
                .x = @floatCast(data[i]),
                .y = @floatCast(data[i + 1]),
            };
        }

        return result;
    }

    pub fn deinit(self: *Self) void {
        var children_it = self.children.iterator();
        while (children_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }

        self.children.deinit();
    }

    pub fn dump(self: Self) void {
        std.debug.print("Version: {}\n", .{self.version});

        var nodes = self.children.valueIterator();
        while (nodes.next()) |node| {
            node.*.dump("");
        }
    }
};

test "fbx" {
    const allocator = std.testing.allocator;

    var cube = try FBXFile.init(allocator, "test/cube.fbx");
    defer cube.deinit();

    var cube_tr = try FBXFile.init(allocator, "test/cube_tr.fbx");
    defer cube_tr.deinit();
    // cube_tr.dump();

    var tree = try FBXFile.init(allocator, "test/tree.fbx");
    defer tree.deinit();
    tree.dump();

    try std.testing.expectEqual(2, 2);

    var maybe_rock: FBXFile = FBXFile.init(allocator, "test/rock_ascii.fbx") catch |err| {
        return try std.testing.expectEqual(FBXFormatError.FBXIsNotBinaryEncoded, err);
    };
    maybe_rock.deinit();
}
