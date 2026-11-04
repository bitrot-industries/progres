//! PostgreSQL page storage subsystem.

const std = @import("std");
const options = @import("options");

pub const item = @import("page/item.zig");
pub const checksum = @import("page/checksum.zig");

pub const LocationIndex = u16;
pub const TransactionId = u32;
pub const SlotNumber = u16;
pub const BlockNumber = u32;

const HeaderLayout = struct {
    const size: usize = 24;
    const checksum_offset: usize = 8;
    const flags_offset: usize = 10;
    const lower_offset: usize = 12;
    const upper_offset: usize = 14;
    const special_offset: usize = 16;
    const page_size_version_offset: usize = 18;
    const page_size_mask: u16 = 0xFF00;
    const layout_version_mask: u16 = 0x00FF;
};

// PostgreSQL's MAXIMUM_ALIGNOF is the larger target alignment of int64_t and double.
const SPECIAL_ALIGNMENT: usize = @max(@alignOf(i64), @alignOf(f64));
const ItemId = item.ItemId;

pub const EmptyPage = struct {
    const layout_version: usize = 4;
    bytes: *const [options.page_size]u8,

    /// Format a buffer as an empty page with no special space.
    pub fn new(bytes: *[options.page_size]u8) EmptyPage {
        @memset(bytes, 0);
        initializeHeader(bytes[0..HeaderLayout.size], options.page_size);
        return .{ .bytes = bytes };
    }

    pub fn mutable(self: EmptyPage) MutablePage {
        return MutablePage{ .bytes = @constCast(self.bytes) };
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
        if (aligned_size >= options.page_size - HeaderLayout.size) {
            return error.SpecialSpaceTooLarge;
        }

        const special_start = options.page_size - aligned_size;

        @memset(bytes, 0);
        initializeHeader(bytes[0..HeaderLayout.size], @intCast(special_start));

        return .{ .bytes = bytes };
    }

    /// `special_start` is an offset from the beginning of the page.
    fn initializeHeader(bytes: *[HeaderLayout.size]u8, special_start: u16) void {
        const header = MutableHeader{ .bytes = bytes };
        // The empty line-pointer array ends immediately after the header.
        header.setLower(HeaderLayout.size);

        // There are no items yet, so both boundaries start at special space.
        header.setUpper(special_start);
        header.setSpecial(special_start);

        // Store the page size and layout version together.
        header.setPageSizeVersion(options.page_size, EmptyPage.layout_version);
    }
};

pub const PageView = struct {
    bytes: *const [options.page_size]u8,

    pub fn fromBytes(bytes: *[options.page_size]u8, block_number: BlockNumber) !PageView {
        if (std.mem.allEqual(u8, bytes, 0)) {
            return error.UninitializedPage;
        }

        const header_view = HeaderView.new(bytes[0..HeaderLayout.size]);
        try header_view.validate();
        if (header_view.checksum() != checksum.calculate(bytes, block_number)) return error.ChecksumMismatch;
        return .{ .bytes = bytes };
    }

    pub fn header(self: *const PageView) HeaderView {
        return HeaderView.new(self.bytes[0..HeaderLayout.size]);
    }

    pub fn mutable(self: PageView) MutablePage {
        return MutablePage{ .bytes = @constCast(self.bytes) };
    }

    pub fn getItem(self: *const PageView, slot: SlotNumber) ![]const u8 {
        const header_view = self.header();
        const lower = header_view.lower();
        const slot_count = header_view.slotCount();
        if (slot == 0 or slot_count < slot) return error.InvalidSlot;

        const item_ids = self.bytes[HeaderLayout.size..lower];
        const start = (slot - 1) * ItemId.size;

        const item_id_bytes = item_ids[start..][0..ItemId.size];
        const item_id = ItemId.decode(item_id_bytes);

        // Convert before adding: offset and length are both u15.
        const item_start: usize = item_id.offset;
        const item_length: usize = item_id.length;
        const item_end = item_start + item_length;

        // Item bytes must be between the start of item storage and special space.
        if (item_length == 0 or
            item_start < header_view.upper() or
            item_end > header_view.special())
        {
            return error.InvalidItem;
        }

        return self.bytes[item_start..item_end];
    }
};

pub const MutablePage = struct {
    bytes: *[options.page_size]u8,

    /// Append an item and return its one-based slot. Item bytes must not
    /// overlap the page; mutation leaves its stored checksum stale.
    pub fn addItem(
        self: *MutablePage,
        item_bytes: []const u8,
    ) !SlotNumber {
        const header_view = HeaderView.new(self.bytes[0..HeaderLayout.size]);
        const lower: usize = header_view.lower();
        const upper: usize = header_view.upper();

        // The region between the header and lower must contain whole slots.
        if ((lower - HeaderLayout.size) % ItemId.size != 0) return error.InvalidPage;
        // A normal line pointer needs data and stores its length in 15 bits.
        if (item_bytes.len == 0 or item_bytes.len > ItemId.max_length) return error.InvalidItem;

        const aligned_size = std.mem.alignForward(usize, item_bytes.len, SPECIAL_ALIGNMENT);
        if (aligned_size > upper or lower + ItemId.size > upper - aligned_size) return error.PageFull;

        const item_start = upper - aligned_size;

        @memcpy(self.bytes[item_start..][0..item_bytes.len], item_bytes);

        const line_pointer = ItemId.normal(item_start, item_bytes.len);
        line_pointer.encode(self.bytes[lower..][0..ItemId.size]);

        const mutable_header = header_view.mutable();
        mutable_header.setLower(@intCast(lower + ItemId.size));
        mutable_header.setUpper(@intCast(item_start));

        const slot_number = (lower - HeaderLayout.size) / ItemId.size + 1;
        return @intCast(slot_number);
    }

    pub fn header(self: *MutablePage) HeaderView {
        return HeaderView.new(self.bytes[0..HeaderLayout.size]);
    }

    pub fn prepare(self: *MutablePage, block_number: BlockNumber) PreparedPage {
        self.header().mutable().setChecksum(checksum.calculate(self.bytes, block_number));
        return .{ .bytes = self.bytes };
    }
};

pub const PreparedPage = struct {
    bytes: *const [options.page_size]u8,

    pub fn write() !void {}

    pub fn view(self: PreparedPage) PageView {
        return .{ .bytes = self.bytes };
    }
};

pub const HeaderView = struct {
    const valid_flag_bits: u16 = 0x0007;
    bytes: *const [HeaderLayout.size]u8,

    fn new(bytes: *const [HeaderLayout.size]u8) HeaderView {
        return .{ .bytes = bytes };
    }

    fn mutable(self: HeaderView) MutableHeader {
        return MutableHeader{ .bytes = @constCast(self.bytes) };
    }

    fn validate(self: HeaderView) error{InvalidPage}!void {
        if (
        // Only defined page-state flags may be set.
        self.flags() & ~HeaderView.valid_flag_bits != 0 or
            // The line-pointer area cannot begin inside the fixed header.
            self.lower() < HeaderLayout.size or
            // The beginning of free space cannot pass its end.
            self.lower() > self.upper() or
            // Item storage cannot extend into the special-space area.
            self.upper() > self.special() or
            // Special space must start within the page, on its required boundary.
            self.special() > options.page_size or
            self.special() % SPECIAL_ALIGNMENT != 0) return error.InvalidPage;
    }

    pub fn slotCount(self: HeaderView) usize {
        return (self.lower() - HeaderLayout.size) / ItemId.size;
    }

    pub fn exactFreeSpace(self: HeaderView) usize {
        // todo: make sure this stands always:
        // Headers are always valid/validate when constructed so it should not be necessary to check `upper < lower`
        return self.upper() - self.lower();
    }

    pub fn freeSpace(self: HeaderView) usize {
        const exactSpace = self.exactFreeSpace();
        if (exactSpace < ItemId.size) return 0;
        return exactSpace - ItemId.size;
    }

    pub fn freeSpaceForMultipleItems(self: HeaderView, n: usize) usize {
        const exact = self.exactFreeSpace();
        if (n > exact / ItemId.size) return 0;

        const item_ids_required = (n * ItemId.size);
        return exact - item_ids_required;
    }

    /// Header fields
    pub fn logSequenceNumber(self: HeaderView) u64 {
        return std.mem.readInt(u64, self.bytes[0..8], .little);
    }

    pub fn checksum(self: HeaderView) u16 {
        return std.mem.readInt(u16, self.bytes[HeaderLayout.checksum_offset..][0..@sizeOf(u16)], .little);
    }

    pub fn flags(self: HeaderView) u16 {
        return std.mem.readInt(u16, self.bytes[HeaderLayout.flags_offset..][0..@sizeOf(u16)], .little);
    }

    pub fn lower(self: HeaderView) LocationIndex {
        return std.mem.readInt(u16, self.bytes[HeaderLayout.lower_offset..][0..@sizeOf(u16)], .little);
    }

    pub fn upper(self: HeaderView) LocationIndex {
        return std.mem.readInt(u16, self.bytes[HeaderLayout.upper_offset..][0..@sizeOf(u16)], .little);
    }

    pub fn special(self: HeaderView) LocationIndex {
        return std.mem.readInt(u16, self.bytes[HeaderLayout.special_offset..][0..@sizeOf(u16)], .little);
    }

    pub fn pageSizeVersion(self: HeaderView) u16 {
        return std.mem.readInt(u16, self.bytes[HeaderLayout.page_size_version_offset..][0..@sizeOf(u16)], .little);
    }

    pub fn pruneId(self: HeaderView) TransactionId {
        return std.mem.readInt(u32, self.bytes[20..24], .little);
    }

    /// Further helpers
    pub fn pageSize(self: HeaderView) u16 {
        return self.pageSizeVersion() & HeaderLayout.page_size_mask;
    }

    pub fn layoutVersion(self: HeaderView) u8 {
        return @intCast(self.pageSizeVersion() & HeaderLayout.layout_version_mask);
    }
};

pub const MutableHeader = struct {
    bytes: *[HeaderLayout.size]u8,

    /// Store the checksum calculated for this page.
    pub fn setChecksum(self: MutableHeader, value: u16) void {
        std.mem.writeInt(u16, self.bytes[HeaderLayout.checksum_offset..][0..@sizeOf(u16)], value, .little);
    }

    /// Set page-state flags; callers must preserve valid flag bits.
    pub fn setFlags(self: MutableHeader, value: u16) void {
        std.mem.writeInt(u16, self.bytes[HeaderLayout.flags_offset..][0..@sizeOf(u16)], value, .little);
    }

    /// Set the end of the line-pointer array; caller maintains page invariants.
    pub fn setLower(self: MutableHeader, value: LocationIndex) void {
        std.mem.writeInt(u16, self.bytes[HeaderLayout.lower_offset..][0..@sizeOf(u16)], value, .little);
    }

    /// Set the beginning of item storage; caller maintains page invariants.
    pub fn setUpper(self: MutableHeader, value: LocationIndex) void {
        std.mem.writeInt(u16, self.bytes[HeaderLayout.upper_offset..][0..@sizeOf(u16)], value, .little);
    }

    /// Set the beginning of the access method's reserved special space.
    pub fn setSpecial(self: MutableHeader, value: LocationIndex) void {
        std.mem.writeInt(u16, self.bytes[HeaderLayout.special_offset..][0..@sizeOf(u16)], value, .little);
    }

    /// Store the page size and layout version in their shared header field.
    /// The page size must be a multiple of 256, leaving its low byte free.
    pub fn setPageSizeVersion(self: MutableHeader, size: u16, version: u8) void {
        std.debug.assert(size & HeaderLayout.layout_version_mask == 0);
        std.mem.writeInt(u16, self.bytes[HeaderLayout.page_size_version_offset..][0..@sizeOf(u16)], size | @as(u16, version), .little);
    }
};

test "header reports exact free space and reserves a line pointer" {
    var bytes: [HeaderLayout.size]u8 = @splat(0);
    const header = HeaderView.new(&bytes);
    const mutable_header = header.mutable();
    const lower: u16 = HeaderLayout.size;
    mutable_header.setLower(lower);

    const cases = [_]struct { gap: u16, available: usize }{
        .{ .gap = 0, .available = 0 },
        .{ .gap = ItemId.size - 1, .available = 0 },
        .{ .gap = ItemId.size, .available = 0 },
        .{ .gap = 20, .available = 20 - ItemId.size },
    };
    for (cases) |case| {
        mutable_header.setUpper(lower + case.gap);
        try std.testing.expectEqual(@as(usize, case.gap), header.exactFreeSpace());
        try std.testing.expectEqual(case.available, header.freeSpace());
    }
}

test "free space for multiple items accounts for line pointers safely" {
    var bytes: [HeaderLayout.size]u8 = @splat(0);
    const header = HeaderView.new(&bytes);
    const mutable_header = header.mutable();
    mutable_header.setLower(HeaderLayout.size);
    mutable_header.setUpper(HeaderLayout.size + 20);

    try std.testing.expectEqual(@as(usize, 20), header.freeSpaceForMultipleItems(0));
    try std.testing.expectEqual(@as(usize, 20 - ItemId.size), header.freeSpaceForMultipleItems(1));
    try std.testing.expectEqual(@as(usize, 20 - 3 * ItemId.size), header.freeSpaceForMultipleItems(3));
    try std.testing.expectEqual(@as(usize, 0), header.freeSpaceForMultipleItems(20 / ItemId.size));
    try std.testing.expectEqual(@as(usize, 0), header.freeSpaceForMultipleItems(20 / ItemId.size + 1));
    try std.testing.expectEqual(@as(usize, 0), header.freeSpaceForMultipleItems(std.math.maxInt(usize)));
}

test "mutable header setters update the corresponding boundaries" {
    var bytes: [HeaderLayout.size]u8 = @splat(0);
    const header = HeaderView.new(&bytes);
    const mutable_header = header.mutable();
    mutable_header.setChecksum(0x1234);
    mutable_header.setFlags(0x0003);
    mutable_header.setLower(32);
    mutable_header.setUpper(512);
    mutable_header.setSpecial(768);
    mutable_header.setPageSizeVersion(1024, 4);
    try std.testing.expectEqual(@as(u16, 0x1234), header.checksum());
    try std.testing.expectEqual(@as(u16, 0x0003), header.flags());
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x03, 0x00 }, bytes[HeaderLayout.checksum_offset..HeaderLayout.lower_offset]);
    try std.testing.expectEqual(@as(LocationIndex, 32), header.lower());
    try std.testing.expectEqual(@as(LocationIndex, 512), header.upper());
    try std.testing.expectEqual(@as(LocationIndex, 768), header.special());
    try std.testing.expectEqual(@as(u16, 1024), header.pageSize());
    try std.testing.expectEqual(@as(u8, 4), header.layoutVersion());
}

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
    const view: HeaderView = .{ .bytes = page_bytes[0..HeaderLayout.size] };
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
    const header = MutableHeader{ .bytes = bytes[0..HeaderLayout.size] };
    header.setChecksum(checksum.calculate(&bytes, 0));
    const page = try PageView.fromBytes(&bytes, 0);
    try std.testing.expect(page.bytes == &bytes);
    try std.testing.expectEqual(@as(u16, HeaderLayout.size), page.header().lower());

    header.setFlags(0x8000);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    header.setFlags(0);
    header.setLower(23);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    header.setLower(options.page_size);
    header.setUpper(HeaderLayout.size);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    header.setLower(HeaderLayout.size);
    header.setUpper(options.page_size);
    header.setSpecial(options.page_size - SPECIAL_ALIGNMENT);
    try std.testing.expectError(error.InvalidPage, PageView.fromBytes(&bytes, 0));
    header.setUpper(options.page_size - 1);
    header.setSpecial(options.page_size - 1);
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
    try std.testing.expectEqual(@as(u8, EmptyPage.layout_version), header.layoutVersion());
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
        const header = HeaderView.new(empty.bytes[0..HeaderLayout.size]);
        const expected_start: u16 = @intCast(options.page_size - case.reserved);

        try std.testing.expectEqual(@as(u16, HeaderLayout.size), header.lower());
        try std.testing.expectEqual(expected_start, header.upper());
        try std.testing.expectEqual(expected_start, header.special());
        for (bytes[HeaderLayout.size..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "oversized special space leaves the buffer unchanged" {
    var bytes: [options.page_size]u8 = @splat(0xaa);
    try std.testing.expectError(
        error.SpecialSpaceTooLarge,
        EmptyPage.newWithSpecialSize(&bytes, @intCast(options.page_size - HeaderLayout.size)),
    );
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
}

test "checksummed page detects corruption and incorrect block number" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    const block_number: BlockNumber = 42;
    const prepared = page.prepare(block_number);

    // Simulate reading the prepared page back from storage.
    var read_buffer = prepared.bytes.*;
    _ = try PageView.fromBytes(&read_buffer, block_number);
    try std.testing.expectError(error.ChecksumMismatch, PageView.fromBytes(&read_buffer, block_number + 1));
    read_buffer[HeaderLayout.size] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, PageView.fromBytes(&read_buffer, block_number));
}

test "addItem inserts aligned items and line pointers" {
    var bytes: [options.page_size]u8 = @splat(0);
    _ = try EmptyPage.newWithSpecialSize(&bytes, 16);
    var page: MutablePage = .{ .bytes = &bytes };
    try std.testing.expectEqual(@as(u16, 1), try page.addItem("hello"));
    try std.testing.expectEqual(@as(u16, 2), try page.addItem("abc"));
    const header_view = HeaderView.new(bytes[0..HeaderLayout.size]);
    try std.testing.expectEqual(@as(u16, HeaderLayout.size + 8), header_view.lower());
    const first_start = options.page_size - 16 - std.mem.alignForward(usize, 5, SPECIAL_ALIGNMENT);
    const second_start = first_start - std.mem.alignForward(usize, 3, SPECIAL_ALIGNMENT);
    try std.testing.expectEqual(@as(u16, @intCast(second_start)), header_view.upper());
    try std.testing.expectEqual(@as(u16, options.page_size - 16), header_view.special());
    const first = std.mem.readInt(u32, bytes[24..28], .little);
    const second = std.mem.readInt(u32, bytes[28..32], .little);
    try std.testing.expectEqual(@as(u32, @intCast(first_start)) | (1 << 15) | (5 << 17), first);
    try std.testing.expectEqual(@as(u32, @intCast(second_start)) | (1 << 15) | (3 << 17), second);
    try std.testing.expectEqualStrings("hello", bytes[first_start..][0..5]);
    try std.testing.expectEqualStrings("abc", bytes[second_start..][0..3]);
}

test "getItem reads inserted items by slot and rejects invalid slots" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    const first = try page.addItem("hello");
    const second = try page.addItem("abc");

    const block_number: BlockNumber = 42;

    const page_view = page.prepare(block_number).view();
    try std.testing.expectEqualStrings("hello", try page_view.getItem(first));
    try std.testing.expectEqualStrings("abc", try page_view.getItem(second));
    try std.testing.expectError(error.InvalidSlot, page_view.getItem(0));
    try std.testing.expectError(error.InvalidSlot, page_view.getItem(second + 1));
}

test "preparing again updates the checksum after a page change" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    const block_number: BlockNumber = 42;
    const first_view = page.prepare(block_number).view();
    page = first_view.mutable();

    const slot = try page.addItem("hello");
    try std.testing.expectError(error.ChecksumMismatch, PageView.fromBytes(page.bytes, block_number));
    const view = page.prepare(block_number).view();
    try std.testing.expectEqualStrings("hello", try view.getItem(slot));
}

test "addItem leaves the page unchanged on failure" {
    var bytes: [options.page_size]u8 = @splat(0);
    _ = EmptyPage.new(&bytes);
    var page: MutablePage = .{ .bytes = &bytes };
    const before = bytes;
    try std.testing.expectError(error.InvalidItem, page.addItem(""));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    var large: [@min(options.page_size, 0x7fff)]u8 = @splat(1);
    try std.testing.expectError(error.PageFull, page.addItem(&large));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
}
