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
