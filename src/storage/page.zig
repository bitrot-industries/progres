//! PostgreSQL page storage subsystem.

const std = @import("std");
const options = @import("options");

pub const item_id = @import("page/item_id.zig");
pub const item_pointer = @import("page/item_pointer.zig");
pub const checksum = @import("page/checksum.zig");

pub const LocationIndex = u16;
pub const TransactionId = u32;

const PAGE_LAYOUT_VERSION: usize = 4;
const HEADER_SIZE: usize = 24;
const VALID_FLAG_BITS: u16 = 0x0007;
// The page format uses an 8-byte boundary for special space.
const SPECIAL_ALIGNMENT: usize = 8;

pub const EmptyPage = struct {
    bytes: *const [options.page_size]u8,

    /// Format a buffer as an empty page with no special space.
    pub fn new(bytes: *[options.page_size]u8) EmptyPage {
        @memset(bytes, 0);
        initializeHeader(bytes[0..24], options.page_size);
        return .{ .bytes = bytes };
    }

    /// Format an empty page with aligned special space at the end.
    pub fn newWithSpecialSize(
        bytes: *[options.page_size]u8,
        special_size: u16,
    ) !EmptyPage {
        const aligned_size = std.mem.alignForward(
            usize,
            special_size,
            SPECIAL_ALIGNMENT,
        );

        // Check that space remains after the header and special area.
        if (aligned_size >= options.page_size - HEADER_SIZE) {
            return error.SpecialSpaceTooLarge;
        }

        const special_start = options.page_size - aligned_size;

        @memset(bytes, 0);
        initializeHeader(bytes[0..HEADER_SIZE], @intCast(special_start));

        return .{ .bytes = bytes };
    }

    /// `special_start` is an offset from the beginning of the page.
    fn initializeHeader(bytes: *[HEADER_SIZE]u8, special_start: u16) void {
        // The empty line-pointer array ends immediately after the header.
        std.mem.writeInt(u16, bytes[12..14], HEADER_SIZE, .little);

        // There are no items yet, so both boundaries start at special space.
        std.mem.writeInt(u16, bytes[14..16], special_start, .little);
        std.mem.writeInt(u16, bytes[16..18], special_start, .little);

        // Store the page size and layout version together.
        std.mem.writeInt(
            u16,
            bytes[18..20],
            options.page_size | PAGE_LAYOUT_VERSION,
            .little,
        );
    }
};

pub const PageView = struct {
    bytes: *const [options.page_size]u8,

    pub fn fromBytes(bytes: *const [options.page_size]u8, block_number: u32) error{ UninitializedPage, InvalidPage, ChecksumMismatch }!PageView {
        if (std.mem.allEqual(u8, bytes, 0)) {
            return error.UninitializedPage;
        }

        const header_view = HeaderView.new(bytes[0..HEADER_SIZE]);
        try header_view.validate();
        if (header_view.checksum() != checksum.calculate(bytes, block_number)) return error.ChecksumMismatch;
        return .{ .bytes = bytes };
    }

    pub fn header(self: *const PageView) HeaderView {
        return HeaderView.new(self.bytes[0..24]);
    }
};

const ItemId = packed struct(u32) {
    offset: u15,
    flags: u2,
    length: u15,
};

pub const HeaderView = struct {
    bytes: *const [24]u8,

    fn new(bytes: *const [24]u8) HeaderView {
        return .{ .bytes = bytes };
    }

    fn validate(self: HeaderView) error{InvalidPage}!void {
        if (
        // Only defined page-state flags may be set.
        self.flags() & ~VALID_FLAG_BITS != 0 or
            // The line-pointer area cannot begin inside the fixed header.
            self.lower() < HEADER_SIZE or
            // The beginning of free space cannot pass its end.
            self.lower() > self.upper() or
            // Item storage cannot extend into the special-space area.
            self.upper() > self.special() or
            // Special space must start within the page, on its required boundary.
            self.special() > options.page_size or
            self.special() % SPECIAL_ALIGNMENT != 0) return error.InvalidPage;
    }

    /// Header fields
    pub fn logSequenceNumber(self: HeaderView) u64 {
        return std.mem.readInt(u64, self.bytes[0..8], .little);
    }

    pub fn checksum(self: HeaderView) u16 {
        return std.mem.readInt(u16, self.bytes[8..10], .little);
    }

    pub fn flags(self: HeaderView) u16 {
        return std.mem.readInt(u16, self.bytes[10..12], .little);
    }

    pub fn lower(self: HeaderView) LocationIndex {
        return std.mem.readInt(u16, self.bytes[12..14], .little);
    }

    pub fn upper(self: HeaderView) LocationIndex {
        return std.mem.readInt(u16, self.bytes[14..16], .little);
    }

    pub fn special(self: HeaderView) LocationIndex {
        return std.mem.readInt(u16, self.bytes[16..18], .little);
    }

    pub fn pageSizeVersion(self: HeaderView) u16 {
        return std.mem.readInt(u16, self.bytes[18..20], .little);
    }

    pub fn pruneId(self: HeaderView) TransactionId {
        return std.mem.readInt(u32, self.bytes[20..24], .little);
    }

    /// Further helpers
    pub fn pageSize(self: HeaderView) u16 {
        return self.pageSizeVersion() & page_size_mask;
    }

    pub fn layoutVersion(self: HeaderView) u8 {
        return @intCast(self.pageSizeVersion() & layout_version_mask);
    }
};

const page_size_mask: u16 = 0xFF00;
const layout_version_mask: u16 = 0x00FF;

test {
    @import("std").testing.refAllDecls(@This());
}

test "header view reads each field from page bytes" {
    var page_bytes: [options.page_size]u8 = @splat(0);

    const bytes = [_]u8{
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x12, 0x11, 0x14, 0x13, 0x16, 0x15, 0x18, 0x17,
        0x1a, 0x19, 0x1c, 0x1b, 0x20, 0x1f, 0x1e, 0x1d,
    };
    @memcpy(page_bytes[0..24], &bytes);

    // This fixture exercises decoding independently of header validation.
    const view: HeaderView = .{ .bytes = page_bytes[0..HEADER_SIZE] };
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), view.logSequenceNumber());
    try std.testing.expectEqual(@as(u16, 0x1112), view.checksum());
    try std.testing.expectEqual(@as(u16, 0x1314), view.flags());
    try std.testing.expectEqual(@as(u16, 0x1516), view.lower());
    try std.testing.expectEqual(@as(u16, 0x1718), view.upper());
    try std.testing.expectEqual(@as(u16, 0x191a), view.special());
    try std.testing.expectEqual(@as(u16, 0x1b1c), view.pageSizeVersion());
    try std.testing.expectEqual(@as(u32, 0x1d1e1f20), view.pruneId());
}

test "fromBytes validates initialized pages without copying" {
    var bytes: [options.page_size]u8 = @splat(0);
    try std.testing.expectError(error.UninitializedPage, PageView.fromBytes(&bytes, 0));
    _ = EmptyPage.new(&bytes);
    std.mem.writeInt(u16, bytes[8..10], checksum.calculate(&bytes, 0), .little);
    const page = try PageView.fromBytes(&bytes, 0);
    try std.testing.expect(page.bytes == &bytes);
    try std.testing.expectEqual(@as(u16, HEADER_SIZE), page.header().lower());

    std.mem.writeInt(u16, bytes[10..12], 0x8000, .little);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    std.mem.writeInt(u16, bytes[10..12], 0, .little);
    std.mem.writeInt(u16, bytes[12..14], 23, .little);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    std.mem.writeInt(u16, bytes[12..14], options.page_size, .little);
    std.mem.writeInt(u16, bytes[14..16], 24, .little);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    std.mem.writeInt(u16, bytes[12..14], 24, .little);
    std.mem.writeInt(u16, bytes[14..16], options.page_size, .little);
    std.mem.writeInt(u16, bytes[16..18], options.page_size - 8, .little);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    std.mem.writeInt(u16, bytes[14..16], options.page_size - 1, .little);
    std.mem.writeInt(u16, bytes[16..18], options.page_size - 1, .little);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
}

test "new empty page formats its buffer in place" {
    var bytes: [options.page_size]u8 = @splat(0xaa);
    const page = EmptyPage.new(&bytes);
    const header = HeaderView.new(page.bytes[0..24]);

    try std.testing.expectEqual(&bytes, page.bytes);
    try std.testing.expectEqual(@as(u16, 24), header.lower());
    try std.testing.expectEqual(@as(u16, options.page_size), header.upper());
    try std.testing.expectEqual(@as(u16, options.page_size), header.special());
    try std.testing.expectEqual(@as(u16, options.page_size), header.pageSize());
    try std.testing.expectEqual(@as(u8, PAGE_LAYOUT_VERSION), header.layoutVersion());
    try std.testing.expectEqual(@as(u64, 0), header.logSequenceNumber());
    try std.testing.expectEqual(@as(u16, 0), header.checksum());
    try std.testing.expectEqual(@as(u16, 0), header.flags());
    try std.testing.expectEqual(@as(u32, 0), header.pruneId());
    for (bytes[24..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "new empty page reserves aligned special space" {
    const cases = [_]struct { requested: u16, reserved: u16 }{
        .{ .requested = 0, .reserved = 0 },
        .{ .requested = 13, .reserved = 16 },
        .{ .requested = 16, .reserved = 16 },
    };

    for (cases) |case| {
        var bytes: [options.page_size]u8 = @splat(0xaa);
        const empty = try EmptyPage.newWithSpecialSize(&bytes, case.requested);
        const header = HeaderView.new(empty.bytes[0..HEADER_SIZE]);
        const expected_start: u16 = @intCast(options.page_size - case.reserved);

        try std.testing.expectEqual(@as(u16, HEADER_SIZE), header.lower());
        try std.testing.expectEqual(expected_start, header.upper());
        try std.testing.expectEqual(expected_start, header.special());
        for (bytes[HEADER_SIZE..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "oversized special space leaves the buffer unchanged" {
    var bytes: [options.page_size]u8 = @splat(0xaa);
    try std.testing.expectError(
        error.SpecialSpaceTooLarge,
        EmptyPage.newWithSpecialSize(&bytes, @intCast(options.page_size - HEADER_SIZE)),
    );
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
}

test "checksummed page detects corruption and incorrect block number" {
    var bytes: [options.page_size]u8 = @splat(0);
    _ = EmptyPage.new(&bytes);
    const block_number: u32 = 42;
    const expected = checksum.calculate(&bytes, block_number);
    std.mem.writeInt(u16, bytes[8..10], expected, .little);
    _ = try PageView.fromBytes(&bytes, block_number);
    try std.testing.expectError(error.ChecksumMismatch, PageView.fromBytes(&bytes, block_number + 1));
    bytes[HEADER_SIZE] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, PageView.fromBytes(&bytes, block_number));
}
