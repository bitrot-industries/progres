const std = @import("std");
const page = @import("page");

pub const bits_per_byte = 8;

pub const Header = struct {
    pub const Layout = struct {
        /// Fixed-header bytes, excluding the optional null bitmap and padding.
        pub const size: usize = 23;
        /// Inserting transaction ID in a heap-style header.
        pub const xmin_offset: usize = 0;
        /// Deleting, updating, or locking transaction or multitransaction ID.
        pub const xmax_offset: usize = 4;
        /// Command ID or legacy vacuum transaction ID in a heap-style header.
        pub const command_offset: usize = 8;
        /// Tuple identifier: this or a newer version's location, with special uses.
        pub const tuple_id_offset: usize = 12;
        /// Attribute count and additional tuple-state flags.
        pub const infomask2_offset: usize = 18;
        /// Tuple properties and transaction-state flags.
        pub const infomask_offset: usize = 20;
        /// Offset from the start of the tuple to its attribute data.
        pub const attribute_data_offset: usize = 22;
    };

    data: *const [Layout.size]u8,

    const InfoMask = packed struct(u16) {
        has_null: bool,
        has_var_width: bool,
        has_external: bool,
        has_oid_old: bool,
        xmax_key_share_lock: bool,
        combo_command_id: bool,
        xmax_exclusive_lock: bool,
        xmax_lock_only: bool,
        xmin_committed: bool,
        xmin_invalid: bool,
        xmax_committed: bool,
        xmax_invalid: bool,
        xmax_is_multi: bool,
        updated: bool,
        moved_off: bool,
        moved_in: bool,
    };

    const InfoMask2 = packed struct(u16) {
        attribute_count: u11,
        reserved: u2,
        keys_updated: bool,
        hot_updated: bool,
        heap_only_tuple: bool,
    };

    const TupleId = struct {
        block: page.BlockNumber,
        slot: page.SlotNumber,
    };

    pub fn init(
        data: *const [Layout.size]u8,
        tuple_len: usize,
    ) !Header {
        const header = Header{ .data = data };
        const data_offset: usize = header.dataOffset();

        if (data_offset < Layout.size or data_offset > tuple_len) {
            return error.InvalidDataOffset;
        }

        if (data_offset % page.special_alignment != 0) {
            return error.InvalidAlignment;
        }

        // todo: you can work on a single byte instead
        const mask = header.infoMask();
        if (mask.has_null) {
            const count: usize = header.infoMask2().attribute_count;
            const bitmap_size_in_bytes = (count + bits_per_byte - 1) / bits_per_byte;

            if (Layout.size + bitmap_size_in_bytes > data_offset) {
                return error.InvalidNullBitmap;
            }
        }

        return header;
    }

    /// Raw field: interpret as xmin only for a heap-style header.
    pub fn rawXmin(self: Header) u32 {
        return self.readU32(Layout.xmin_offset);
    }

    /// Raw field: interpret as xmax only for a heap-style header.
    pub fn rawXmax(self: Header) u32 {
        return self.readU32(Layout.xmax_offset);
    }

    pub fn rawCommand(self: Header) u32 {
        return self.readU32(Layout.command_offset);
    }

    pub fn tupleId(self: Header) TupleId {
        const offset = Layout.tuple_id_offset;

        // The block number is stored as high and low u16 parts.
        const high = self.readU16(offset);
        const low = self.readU16(offset + @sizeOf(u16));
        const slot = self.readU16(offset + 2 * @sizeOf(u16));

        return .{
            .block = (@as(page.BlockNumber, high) << 16) | @as(page.BlockNumber, low),
            .slot = slot,
        };
    }

    pub fn infoMask(self: Header) InfoMask {
        return @bitCast(self.readU16(Layout.infomask_offset));
    }

    pub fn infoMask2(self: Header) InfoMask2 {
        return @bitCast(self.readU16(Layout.infomask2_offset));
    }

    pub fn dataOffset(self: Header) u8 {
        return self.data[Layout.attribute_data_offset];
    }

    fn readU16(self: Header, comptime offset: usize) u16 {
        return std.mem.readInt(
            u16,
            self.data[offset..][0..@sizeOf(u16)],
            .little,
        );
    }

    fn readU32(self: Header, comptime offset: usize) u32 {
        return std.mem.readInt(
            u32,
            self.data[offset..][0..@sizeOf(u32)],
            .little,
        );
    }
};

test "header reads fields from known bytes" {
    const bytes = [Header.Layout.size]u8{
        0x01, 0x02, 0x03, 0x04, // xmin
        0x05, 0x06, 0x07, 0x08, // xmax
        0x09, 0x0a, 0x0b, 0x0c, // command
        0x34, 0x12, 0x78, 0x56, 0x09, 0x00, // block and slot
        0x09, 0x40, // 9 attributes; HOT updated
        0x05, 0x02, // has null, external, xmin invalid
        32, // data offset, after the two-byte bitmap and padding
    };

    const header = try Header.init(&bytes, 32);
    try std.testing.expectEqual(@as(u32, 0x04030201), header.rawXmin());
    try std.testing.expectEqual(@as(u32, 0x08070605), header.rawXmax());
    try std.testing.expectEqual(@as(u32, 0x0c0b0a09), header.rawCommand());
    try std.testing.expectEqual(@as(page.BlockNumber, 0x12345678), header.tupleId().block);
    try std.testing.expectEqual(@as(page.SlotNumber, 9), header.tupleId().slot);
    try std.testing.expectEqual(@as(u8, 32), header.dataOffset());

    const mask = header.infoMask();
    try std.testing.expect(mask.has_null);
    try std.testing.expect(!mask.has_var_width);
    try std.testing.expect(mask.has_external);
    try std.testing.expect(mask.xmin_invalid);
    try std.testing.expect(!mask.xmin_committed);
    const mask2 = header.infoMask2();
    try std.testing.expectEqual(@as(u11, 9), mask2.attribute_count);
    try std.testing.expect(mask2.hot_updated);
    try std.testing.expect(!mask2.keys_updated);
}

test "header rejects invalid data offsets and alignment" {
    var bytes: [Header.Layout.size]u8 = @splat(0);
    bytes[Header.Layout.attribute_data_offset] = Header.Layout.size - 1;
    try std.testing.expectError(error.InvalidDataOffset, Header.init(&bytes, 64));

    const aligned = std.mem.alignForward(usize, Header.Layout.size, page.special_alignment);
    bytes[Header.Layout.attribute_data_offset] = @intCast(aligned);
    try std.testing.expectError(error.InvalidDataOffset, Header.init(&bytes, aligned - 1));
    _ = try Header.init(&bytes, aligned);

    if (page.special_alignment > 1) {
        bytes[Header.Layout.attribute_data_offset] = @intCast(aligned + 1);
        try std.testing.expectError(error.InvalidAlignment, Header.init(&bytes, aligned + 1));
    }
}

test "header checks null bitmap space only when null flag is set" {
    var bytes: [Header.Layout.size]u8 = @splat(0);
    const offset = std.mem.alignForward(usize, Header.Layout.size, page.special_alignment);
    bytes[Header.Layout.attribute_data_offset] = @intCast(offset);
    // 255 attributes need 32 bitmap bytes, more than the available padding.
    bytes[Header.Layout.infomask2_offset] = 0xff;

    _ = try Header.init(&bytes, offset);
    bytes[Header.Layout.infomask_offset] = 0x01;
    try std.testing.expectError(error.InvalidNullBitmap, Header.init(&bytes, offset));
}
