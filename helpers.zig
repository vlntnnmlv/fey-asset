const std = @import("std");

/// Returns `n` bytes from the reader. Memory is allocated with `allocator`,
/// and you are responsible for freeing it afterwards.
///
/// If there is less then `n` bytes left, returns the whatever amount is left.
pub fn takeBytes(allocator: std.mem.Allocator, reader: *std.Io.Reader, n: usize) ![]u8 {
    _ = try reader.peek(1); // TODO: We shouldn't peek like that...
    const buffer_size = reader.buffer.len;
    var result: std.ArrayList(u8) = .empty;

    var bytes_read: usize = 0;
    var remaining = n;
    while (bytes_read < n) {
        const section_size = switch (remaining > buffer_size) {
            true => buffer_size,
            false => remaining,
        };

        const section = reader.take(section_size) catch |err| {
            if (err == std.Io.Reader.Error.EndOfStream) {
                try reader.appendRemaining(allocator, &result, .unlimited);
                break;
            } else return err;
        };

        try result.appendSlice(allocator, section);
        bytes_read += section_size;
        remaining -= section_size;
    }

    return result.items;
}

pub const FBXArrayInfo = struct {
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

pub fn readArrayInfo(reader: *std.Io.Reader) !FBXArrayInfo {
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

pub fn readArray(allocator: std.mem.Allocator, reader: *std.Io.Reader, comptime T: type) ![]T {
    const array_info = try readArrayInfo(reader);
    var array: []T = undefined;
    if (array_info.encoding == 1) {
        const compressed = try takeBytes(allocator, reader, array_info.compressed_length);
        array = try decompressArray(allocator, compressed, T);
    } else {
        const bit_size_of_t = @bitSizeOf(T);
        const IntType = switch (bit_size_of_t) {
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
