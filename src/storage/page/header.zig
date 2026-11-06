const std = @import("std");
const options = @import("options");

const item = @import("item.zig");
const ItemId = item.ItemId;

const page = @import("page.zig");
const SPECIAL_ALIGNMENT = page.SPECIAL_ALIGNMENT;

pub const LocationIndex = u16;
pub const TransactionId = u32;

pub const HeaderLayout = struct {
    pub const size: usize = 24;
    pub const checksum_offset: usize = 8;
    pub const flags_offset: usize = 10;
    pub const lower_offset: usize = 12;
    pub const upper_offset: usize = 14;
    pub const special_offset: usize = 16;
    pub const page_size_version_offset: usize = 18;
    pub const page_size_mask: u16 = 0xFF00;
    pub const layout_version_mask: u16 = 0x00FF;
    pub const has_free_lines: u16 = 0x0001;
};

pub const MutableHeader = HeaderAccess(true);
pub const HeaderView = HeaderAccess(false);

fn HeaderAccess(comptime isMut: bool) type {
    return struct {
        const Self = @This();

        const valid_flag_bits: u16 = 0x0007;
        bytes: if (isMut) *[HeaderLayout.size]u8 else *const [HeaderLayout.size]u8,

        pub fn init(bytes: if (isMut) *[HeaderLayout.size]u8 else *const [HeaderLayout.size]u8) !Self {
            const self = Self{ .bytes = bytes };
            try self.validate();
            return self;
        }

        pub fn unchecked(bytes: if (isMut) *[HeaderLayout.size]u8 else *const [HeaderLayout.size]u8) Self {
            return .{ .bytes = bytes };
        }

        fn validate(self: Self) !void {
            if (
            // Only defined page-state flags may be set.
            self.flags() & ~Self.valid_flag_bits != 0 or
                // The line-pointer area cannot begin inside the fixed header.
                self.lower() < HeaderLayout.size or
                // The beginning of free space cannot pass its end.
                self.lower() > self.upper() or
                // Item storage cannot extend into the special-space area.
                self.upper() > self.special() or
                // Special space must start within the page, on its required boundary.
                self.special() > options.page_size or
                self.special() % SPECIAL_ALIGNMENT != 0) return error.InvalidHeader;
        }

        pub fn slotCount(self: Self) usize {
            return (self.lower() - HeaderLayout.size) / ItemId.size;
        }

        pub fn exactFreeSpace(self: Self) usize {
            // todo: make sure this stands always:
            // Headers are always valid/validate when constructed so it should not be necessary to check `upper < lower`
            return self.upper() - self.lower();
        }

        pub fn freeSpace(self: Self) usize {
            const exactSpace = self.exactFreeSpace();
            if (exactSpace < ItemId.size) return 0;
            return exactSpace - ItemId.size;
        }

        pub fn freeSpaceForMultipleItems(self: Self, n: usize) usize {
            const exact = self.exactFreeSpace();
            if (n > exact / ItemId.size) return 0;

            const item_ids_required = (n * ItemId.size);
            return exact - item_ids_required;
        }

        /// Header fields
        pub fn logSequenceNumber(self: Self) u64 {
            return std.mem.readInt(u64, self.bytes[0..8], .little);
        }

        pub fn checksum(self: Self) u16 {
            return std.mem.readInt(u16, self.bytes[HeaderLayout.checksum_offset..][0..@sizeOf(u16)], .little);
        }

        pub fn flags(self: Self) u16 {
            return std.mem.readInt(u16, self.bytes[HeaderLayout.flags_offset..][0..@sizeOf(u16)], .little);
        }

        pub fn hasFreeLines(self: Self) bool {
            return (self.flags() & HeaderLayout.has_free_lines) != 0;
        }

        pub fn lower(self: Self) LocationIndex {
            return std.mem.readInt(u16, self.bytes[HeaderLayout.lower_offset..][0..@sizeOf(u16)], .little);
        }

        pub fn upper(self: Self) LocationIndex {
            return std.mem.readInt(u16, self.bytes[HeaderLayout.upper_offset..][0..@sizeOf(u16)], .little);
        }

        pub fn special(self: Self) LocationIndex {
            return std.mem.readInt(u16, self.bytes[HeaderLayout.special_offset..][0..@sizeOf(u16)], .little);
        }

        pub fn pageSizeVersion(self: Self) u16 {
            return std.mem.readInt(u16, self.bytes[HeaderLayout.page_size_version_offset..][0..@sizeOf(u16)], .little);
        }

        pub fn pruneId(self: Self) TransactionId {
            return std.mem.readInt(u32, self.bytes[20..24], .little);
        }

        /// Further helpers
        pub fn pageSize(self: Self) u16 {
            return self.pageSizeVersion() & HeaderLayout.page_size_mask;
        }

        pub fn layoutVersion(self: Self) u8 {
            return @intCast(self.pageSizeVersion() & HeaderLayout.layout_version_mask);
        }

        //? Mutable methods
        /// Store the checksum calculated for this page.
        pub fn setChecksum(self: MutableHeader, value: u16) void {
            if (!isMut) @compileError("method not available");
            std.mem.writeInt(u16, self.bytes[HeaderLayout.checksum_offset..][0..@sizeOf(u16)], value, .little);
        }

        /// Set page-state flags; callers must preserve valid flag bits.
        pub fn setFlags(self: MutableHeader, value: u16) void {
            if (!isMut) @compileError("method not available");
            std.mem.writeInt(u16, self.bytes[HeaderLayout.flags_offset..][0..@sizeOf(u16)], value, .little);
        }

        /// Set the end of the line-pointer array; caller maintains page invariants.
        pub fn setLower(self: MutableHeader, value: LocationIndex) void {
            if (!isMut) @compileError("method not available");
            std.mem.writeInt(u16, self.bytes[HeaderLayout.lower_offset..][0..@sizeOf(u16)], value, .little);
        }

        /// Set the beginning of item storage; caller maintains page invariants.
        pub fn setUpper(self: MutableHeader, value: LocationIndex) void {
            if (!isMut) @compileError("method not available");
            std.mem.writeInt(u16, self.bytes[HeaderLayout.upper_offset..][0..@sizeOf(u16)], value, .little);
        }

        /// Set the beginning of the access method's reserved special space.
        pub fn setSpecial(self: MutableHeader, value: LocationIndex) void {
            if (!isMut) @compileError("method not available");
            std.mem.writeInt(u16, self.bytes[HeaderLayout.special_offset..][0..@sizeOf(u16)], value, .little);
        }

        /// Store the page size and layout version in their shared header field.
        /// The page size must be a multiple of 256, leaving its low byte free.
        pub fn setPageSizeVersion(self: MutableHeader, size: u16, version: u8) void {
            if (!isMut) @compileError("method not available");
            std.debug.assert(size & HeaderLayout.layout_version_mask == 0);
            std.mem.writeInt(u16, self.bytes[HeaderLayout.page_size_version_offset..][0..@sizeOf(u16)], size | @as(u16, version), .little);
        }
    };
}

// test only
const test_helpers = if (@import("builtin").is_test) struct {
    fn validHeaderBytes() [HeaderLayout.size]u8 {
        var bytes: [HeaderLayout.size]u8 = @splat(0);
        std.mem.writeInt(u16, bytes[HeaderLayout.lower_offset..][0..@sizeOf(u16)], HeaderLayout.size, .little);
        std.mem.writeInt(u16, bytes[HeaderLayout.upper_offset..][0..@sizeOf(u16)], options.page_size, .little);
        std.mem.writeInt(u16, bytes[HeaderLayout.special_offset..][0..@sizeOf(u16)], options.page_size, .little);
        return bytes;
    }
} else struct {};

test "free space for multiple items accounts for line pointers safely" {
    var bytes = test_helpers.validHeaderBytes();
    const mutable_header = try MutableHeader.init(&bytes);
    mutable_header.setUpper(HeaderLayout.size + 20);

    try std.testing.expectEqual(@as(usize, 20), mutable_header.freeSpaceForMultipleItems(0));
    try std.testing.expectEqual(@as(usize, 20 - ItemId.size), mutable_header.freeSpaceForMultipleItems(1));
    try std.testing.expectEqual(@as(usize, 20 - 3 * ItemId.size), mutable_header.freeSpaceForMultipleItems(3));
    try std.testing.expectEqual(@as(usize, 0), mutable_header.freeSpaceForMultipleItems(20 / ItemId.size));
    try std.testing.expectEqual(@as(usize, 0), mutable_header.freeSpaceForMultipleItems(20 / ItemId.size + 1));
    try std.testing.expectEqual(@as(usize, 0), mutable_header.freeSpaceForMultipleItems(std.math.maxInt(usize)));
}

test "mutable header setters update the corresponding boundaries" {
    var bytes = test_helpers.validHeaderBytes();
    const mutable_header = try MutableHeader.init(&bytes);
    mutable_header.setChecksum(0x1234);
    mutable_header.setFlags(0x0003);
    mutable_header.setLower(32);
    mutable_header.setUpper(512);
    mutable_header.setSpecial(768);
    mutable_header.setPageSizeVersion(1024, 4);
    _ = try MutableHeader.init(&bytes);

    try std.testing.expectEqual(@as(u16, 0x1234), mutable_header.checksum());
    try std.testing.expectEqual(@as(u16, 0x0003), mutable_header.flags());
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x03, 0x00 }, bytes[HeaderLayout.checksum_offset..HeaderLayout.lower_offset]);
    try std.testing.expectEqual(@as(LocationIndex, 32), mutable_header.lower());
    try std.testing.expectEqual(@as(LocationIndex, 512), mutable_header.upper());
    try std.testing.expectEqual(@as(LocationIndex, 768), mutable_header.special());
    try std.testing.expectEqual(@as(u16, 1024), mutable_header.pageSize());
    try std.testing.expectEqual(@as(u8, 4), mutable_header.layoutVersion());
}

test "header reports exact free space and reserves a line pointer" {
    var bytes = test_helpers.validHeaderBytes();
    const header_mut = try MutableHeader.init(&bytes);
    const lower: u16 = HeaderLayout.size;

    const cases = [_]struct { gap: u16, available: usize }{
        .{ .gap = 0, .available = 0 },
        .{ .gap = ItemId.size - 1, .available = 0 },
        .{ .gap = ItemId.size, .available = 0 },
        .{ .gap = 20, .available = 20 - ItemId.size },
    };
    for (cases) |case| {
        header_mut.setUpper(lower + case.gap);
        try std.testing.expectEqual(@as(usize, case.gap), header_mut.exactFreeSpace());
        try std.testing.expectEqual(case.available, header_mut.freeSpace());
    }
}

test "validated read-only and mutable headers share data" {
    const invalid: [HeaderLayout.size]u8 = @splat(0);
    try std.testing.expectError(error.InvalidHeader, HeaderView.init(&invalid));
    var bytes = test_helpers.validHeaderBytes();
    const writable = try MutableHeader.init(&bytes);
    const view = try HeaderView.init(&bytes);
    writable.setFlags(HeaderLayout.has_free_lines);
    try std.testing.expect(view.hasFreeLines());
    try std.testing.expectEqual(@as(usize, options.page_size - HeaderLayout.size), view.exactFreeSpace());
    try std.testing.expect(@TypeOf(view.bytes) == *const [HeaderLayout.size]u8);
}
