const std = @import("std");
const page = @import("page");
const Header = @import("tuple/header.zig").Header;

// todo: move to primitives
const bits_per_byte = @import("tuple/header.zig").bits_per_byte;

pub const TupleView = struct {
    bytes: []const u8,

    pub fn from(bytes: []const u8) !TupleView {
        if (bytes.len < Header.Layout.size) {
            return error.InvalidBytes;
        }

        _ = try Header.init(bytes[0..Header.Layout.size], bytes.len);

        return .{ .bytes = bytes };
    }

    pub fn header(self: TupleView) Header {
        // from() has already checked the fixed header.
        return .{ .data = self.bytes[0..Header.Layout.size] };
    }

    pub fn isNull(self: TupleView, column_index: usize) bool {
        if (!self.header().infoMask().has_null) return false;

        const byte_index = column_index / bits_per_byte;
        const bit_index: u3 = @intCast(column_index % bits_per_byte);

        // 0 means NULL - 1 means nonNull
        return self.bytes[Header.Layout.size + byte_index] & @as(u8, 1) << bit_index == 0;
    }
};

test "isNull reads the tuple's null bitmap" {
    var bytes: [64]u8 = @splat(0);

    // The tuple has four columns.
    bytes[Header.Layout.infomask2_offset] = 4;

    // Mark the null bitmap as present.
    bytes[Header.Layout.infomask_offset] = 0x01;

    // Bits in column order: 1, 0, 1, 1.
    // Column 1 is NULL; the other columns have values.
    bytes[Header.Layout.size] = 0b0000_1101;

    const data_offset = std.mem.alignForward(
        usize,
        Header.Layout.size + 1, // One bitmap byte.
        page.special_alignment,
    );
    bytes[Header.Layout.attribute_data_offset] = @intCast(data_offset);

    const tuple = try TupleView.from(&bytes);

    try std.testing.expect(!tuple.isNull(0));
    try std.testing.expect(tuple.isNull(1));
    try std.testing.expect(!tuple.isNull(2));
    try std.testing.expect(!tuple.isNull(3));
}

test "isNull returns false when the tuple has no null bitmap" {
    var bytes: [64]u8 = @splat(0);

    bytes[Header.Layout.infomask2_offset] = 4;

    const data_offset = std.mem.alignForward(
        usize,
        Header.Layout.size,
        page.special_alignment,
    );
    bytes[Header.Layout.attribute_data_offset] = @intCast(data_offset);

    const tuple = try TupleView.from(&bytes);

    try std.testing.expect(!tuple.isNull(0));
    try std.testing.expect(!tuple.isNull(3));
}

test "isNull reads columns across bitmap bytes" {
    var bytes: [64]u8 = @splat(0);

    bytes[Header.Layout.infomask2_offset] = 10;
    bytes[Header.Layout.infomask_offset] = 0x01; // Bitmap is present.

    // Column 7 is NULL; column 8 is present; column 9 is NULL.
    bytes[Header.Layout.size] = 0b0111_1111;
    bytes[Header.Layout.size + 1] = 0b0000_0001;

    const data_offset = std.mem.alignForward(
        usize,
        Header.Layout.size + 2, // Two bitmap bytes.
        page.special_alignment,
    );
    bytes[Header.Layout.attribute_data_offset] = @intCast(data_offset);

    const tuple = try TupleView.from(&bytes);

    try std.testing.expect(!tuple.isNull(6));
    try std.testing.expect(tuple.isNull(7));
    try std.testing.expect(!tuple.isNull(8));
    try std.testing.expect(tuple.isNull(9));
}
