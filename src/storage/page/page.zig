//! PostgreSQL page storage subsystem.

const std = @import("std");
const options = @import("options");

pub const item = @import("item.zig");
pub const checksum = @import("checksum.zig");
pub const header = @import("header.zig");

pub const SlotNumber = u16;
pub const BlockNumber = u32;

const HeaderLayout = header.HeaderLayout;
const HeaderView = header.HeaderView;
const MutableHeader = header.MutableHeader;

// PostgreSQL's MAXIMUM_ALIGNOF is the larger target alignment of int64_t and double.
pub const SPECIAL_ALIGNMENT: usize = @max(@alignOf(i64), @alignOf(f64));
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
        // SAFETY: fine to start with empty bytes that we set now
        const header_mut = MutableHeader.unchecked(bytes);
        // The empty line-pointer array ends immediately after the header.
        header_mut.setLower(HeaderLayout.size);

        // There are no items yet, so both boundaries start at special space.
        header_mut.setUpper(special_start);
        header_mut.setSpecial(special_start);

        // Store the page size and layout version together.
        header_mut.setPageSizeVersion(options.page_size, EmptyPage.layout_version);
    }
};

pub const PageView = struct {
    bytes: *const [options.page_size]u8,

    pub fn fromBytes(bytes: *[options.page_size]u8, block_number: BlockNumber) !PageView {
        if (std.mem.allEqual(u8, bytes, 0)) {
            return error.UninitializedPage;
        }

        const header_view = try HeaderView.init(bytes[0..HeaderLayout.size]);
        if (header_view.checksum() != checksum.calculate(bytes, block_number)) return error.ChecksumMismatch;
        return .{ .bytes = bytes };
    }

    pub fn page_header(self: *const PageView) HeaderView {
        // SAFETY: this was checked in `fromBytes`
        return HeaderView.unchecked(self.bytes[0..HeaderLayout.size]);
    }

    pub fn specialSpace(self: *const PageView) []const u8 {
        return self.bytes[self.page_header().special()..];
    }

    pub fn mutable(self: PageView) MutablePage {
        return MutablePage{ .bytes = @constCast(self.bytes) };
    }

    pub fn getItem(self: *const PageView, slot: SlotNumber) ![]const u8 {
        const header_view = self.page_header();
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
    const SlotAction = enum { insert, reuse };

    pub fn addItemAtSlot(self: *MutablePage, slot: SlotNumber, item_bytes: []const u8) !SlotNumber {
        if (slot == 0 or slot > self.page_header().slotCount()) return error.InvalidSlot;
        const slot_start = HeaderLayout.size + (slot - 1) * ItemId.size;
        try self.addItemAtSlotStart(slot_start, item_bytes, .insert);
        return slot;
    }

    /// Insert an item and return its one-based slot. Item bytes must not
    /// overlap the page; mutation leaves its stored checksum stale.
    pub fn addItem(
        self: *MutablePage,
        item_bytes: []const u8,
    ) !SlotNumber {
        const header_view = self.page_header();
        const lower: usize = header_view.lower();

        var slot_start = lower;
        const had_hint = header_view.hasFreeLines();
        if (had_hint) {
            var pos: usize = HeaderLayout.size;
            while (pos < lower) : (pos += ItemId.size) {
                const existing = ItemId.decode(self.bytes[pos..][0..ItemId.size]);
                if (existing.state == .unused and existing.length == 0) {
                    slot_start = pos;
                    break;
                }
            }
        }

        const action: SlotAction = if (slot_start == lower) .insert else .reuse;
        try self.addItemAtSlotStart(slot_start, item_bytes, action);

        if (had_hint and slot_start == lower) {
            self.page_header_mut().clearHasFreeLines();
        }

        const slot = (slot_start - HeaderLayout.size) / ItemId.size + 1;
        return @intCast(slot);
    }

    fn addItemAtSlotStart(self: *MutablePage, slot_start: usize, item_bytes: []const u8, action: SlotAction) !void {
        const mutable_header = try MutableHeader.init(self.bytes[0..HeaderLayout.size]);
        const lower: usize = mutable_header.lower();
        const upper: usize = mutable_header.upper();

        // The region between the header and lower must contain whole slots.
        if ((lower - HeaderLayout.size) % ItemId.size != 0) return error.InvalidPage;

        // A normal line pointer needs data and stores its length in 15 bits.
        if (item_bytes.len == 0 or item_bytes.len > ItemId.max_length) return error.InvalidItem;
        if (slot_start > lower) return error.InvalidSlot;

        const new_lower = lower + if (action == .insert) @as(usize, ItemId.size) else 0;

        const aligned_size = std.mem.alignForward(usize, item_bytes.len, SPECIAL_ALIGNMENT);
        if (aligned_size > upper or new_lower > upper - aligned_size) return error.PageFull;

        if (action == .insert and slot_start < lower) {
            @memmove(
                self.bytes[slot_start + ItemId.size .. new_lower],
                self.bytes[slot_start..lower],
            );
        }

        const item_start = upper - aligned_size;
        @memcpy(self.bytes[item_start..][0..item_bytes.len], item_bytes);

        const line_pointer = ItemId.normal(item_start, item_bytes.len);
        line_pointer.encode(self.bytes[slot_start..][0..ItemId.size]);

        mutable_header.setLower(@intCast(new_lower));
        mutable_header.setUpper(@intCast(item_start));
    }

    pub fn page_header(self: *MutablePage) HeaderView {
        return HeaderView.unchecked(self.bytes[0..HeaderLayout.size]);
    }

    pub fn markSlotUnused(self: *MutablePage, slot: SlotNumber) !void {
        const header_view = self.page_header();
        if (slot == 0 or slot > header_view.slotCount()) return error.InvalidSlot;

        const start = HeaderLayout.size + (slot - 1) * ItemId.size;
        // An unused ItemId has zero offset, state, and length.
        @memset(self.bytes[start..][0..ItemId.size], 0);
        self.page_header_mut().setHasFreeLines();
    }

    pub fn setSpecialSpace(self: *MutablePage, data: []const u8) !void {
        const start = self.page_header().special();
        const available = self.bytes[start..];
        if (data.len > available.len) return error.SpecialSpaceTooSmall;
        @memcpy(available[0..data.len], data);
    }

    pub fn prepare(self: *MutablePage, block_number: BlockNumber) PreparedPage {
        self.page_header_mut().setChecksum(checksum.calculate(self.bytes, block_number));
        return .{ .bytes = self.bytes };
    }

    fn page_header_mut(self: *MutablePage) MutableHeader {
        return MutableHeader.unchecked(self.bytes[0..HeaderLayout.size]);
    }
};

pub const PreparedPage = struct {
    bytes: *const [options.page_size]u8,

    pub fn write() !void {}

    pub fn view(self: PreparedPage) PageView {
        return .{ .bytes = self.bytes };
    }
};

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
    const header_mut = try MutableHeader.init(bytes[0..HeaderLayout.size]);
    header_mut.setChecksum(checksum.calculate(&bytes, 0));
    const page = try PageView.fromBytes(&bytes, 0);
    try std.testing.expect(page.bytes == &bytes);
    try std.testing.expectEqual(@as(u16, HeaderLayout.size), page.page_header().lower());

    header_mut.setFlags(0x8000);
    try std.testing.expectError(error.InvalidHeader, PageView.fromBytes(&bytes, 0));
    header_mut.setFlags(0);
    header_mut.setLower(23);
    try std.testing.expectError(error.InvalidHeader, PageView.fromBytes(&bytes, 0));
    header_mut.setLower(options.page_size);
    header_mut.setUpper(HeaderLayout.size);
    try std.testing.expectError(error.InvalidHeader, PageView.fromBytes(&bytes, 0));
    header_mut.setLower(HeaderLayout.size);
    header_mut.setUpper(options.page_size);
    header_mut.setSpecial(options.page_size - SPECIAL_ALIGNMENT);
    try std.testing.expectError(error.InvalidHeader, PageView.fromBytes(&bytes, 0));
    header_mut.setUpper(options.page_size - 1);
    header_mut.setSpecial(options.page_size - 1);
    try std.testing.expectError(error.InvalidHeader, PageView.fromBytes(&bytes, 0));
}

test "new empty page formats its buffer in place" {
    var bytes: [options.page_size]u8 = @splat(0xaa);
    const page = EmptyPage.new(&bytes);
    const header_view = try HeaderView.init(page.bytes[0..24]);

    try std.testing.expectEqual(&bytes, page.bytes);
    try std.testing.expectEqual(@as(u16, 24), header_view.lower());
    try std.testing.expectEqual(@as(u16, options.page_size), header_view.upper());
    try std.testing.expectEqual(@as(u16, options.page_size), header_view.special());
    try std.testing.expectEqual(@as(u16, options.page_size), header_view.pageSize());
    try std.testing.expectEqual(@as(u8, EmptyPage.layout_version), header_view.layoutVersion());
    try std.testing.expectEqual(@as(u64, 0), header_view.logSequenceNumber());
    try std.testing.expectEqual(@as(u16, 0), header_view.checksum());
    try std.testing.expectEqual(@as(u16, 0), header_view.flags());
    try std.testing.expectEqual(@as(u32, 0), header_view.pruneId());
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
        const header_view = try HeaderView.init(empty.bytes[0..HeaderLayout.size]);
        const expected_start: u16 = @intCast(options.page_size - case.reserved);

        try std.testing.expectEqual(@as(u16, HeaderLayout.size), header_view.lower());
        try std.testing.expectEqual(expected_start, header_view.upper());
        try std.testing.expectEqual(expected_start, header_view.special());
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

test "special space can be set and read through page states" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = (try EmptyPage.newWithSpecialSize(&bytes, 13)).mutable();
    const slot = try page.addItem("item");
    try page.setSpecialSpace("metadata");
    const view = page.prepare(42).view();
    const special = view.specialSpace();
    try std.testing.expectEqual(@as(usize, std.mem.alignForward(usize, 13, SPECIAL_ALIGNMENT)), special.len);
    try std.testing.expectEqualStrings("metadata", special[0..8]);
    for (special[8..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualStrings("item", try view.getItem(slot));
}

test "special space rejects oversized writes without changing the page" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    try page.setSpecialSpace("");
    try std.testing.expectError(error.SpecialSpaceTooSmall, page.setSpecialSpace("x"));
    try std.testing.expectEqual(@as(usize, 0), page.prepare(42).view().specialSpace().len);

    page = (try EmptyPage.newWithSpecialSize(&bytes, 8)).mutable();
    try page.setSpecialSpace("original");
    try std.testing.expectError(error.SpecialSpaceTooSmall, page.setSpecialSpace("too long!"));
    try std.testing.expectEqualStrings("original", page.prepare(42).view().specialSpace());
}

test "markSlotUnused clears only the requested line pointer" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    const first = try page.addItem("first");
    const second = try page.addItem("second");
    const before = bytes;
    try std.testing.expectError(error.InvalidSlot, page.markSlotUnused(0));
    try std.testing.expectError(error.InvalidSlot, page.markSlotUnused(second + 1));
    try std.testing.expectEqualSlices(u8, &before, &bytes);

    try page.markSlotUnused(first);
    const start = HeaderLayout.size + (first - 1) * ItemId.size;
    const cleared = ItemId.decode(bytes[start..][0..ItemId.size]);
    try std.testing.expectEqual(ItemId.State.unused, cleared.state);
    try std.testing.expectEqual(@as(u15, 0), cleared.offset);
    try std.testing.expectEqual(@as(u15, 0), cleared.length);
    try std.testing.expectEqual(@as(usize, 2), page.page_header().slotCount());
    const view = page.prepare(42).view();
    try std.testing.expectEqualStrings("second", try view.getItem(second));
}

test "insertion reuses earliest unused slot without growing the line pointer array" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    const first = try page.addItem("first");
    const second = try page.addItem("second");
    const lower = page.page_header().lower();
    try page.markSlotUnused(first);
    try std.testing.expect(page.page_header().hasFreeLines());
    try std.testing.expectEqual(first, try page.addItem("third"));
    try std.testing.expectEqual(lower, page.page_header().lower());
    const view = page.prepare(42).view();
    try std.testing.expectEqualStrings("third", try view.getItem(first));
    try std.testing.expectEqualStrings("second", try view.getItem(second));
}

test "stale free-line hint is cleared when insertion appends" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    _ = try page.addItem("first");
    page.page_header_mut().setHasFreeLines();
    try std.testing.expectEqual(@as(SlotNumber, 2), try page.addItem("second"));
    try std.testing.expect(!page.page_header().hasFreeLines());
}

test "selected slot insertion shifts pointers and appends" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    _ = try page.addItem("a");
    _ = try page.addItem("b");
    _ = try page.addItem("c");
    const lower = page.page_header().lower();
    try std.testing.expectEqual(@as(SlotNumber, 2), try page.addItemAtSlot(2, "x"));
    try std.testing.expectEqual(@as(usize, lower + ItemId.size), page.page_header().lower());
    try std.testing.expectEqual(@as(SlotNumber, 1), try page.addItemAtSlot(1, "first"));
    try std.testing.expectEqual(@as(SlotNumber, 6), try page.addItemAtSlot(6, "last"));
    const view = page.prepare(42).view();
    for ([_][]const u8{ "first", "a", "x", "b", "c", "last" }, 1..) |expected, slot| {
        try std.testing.expectEqualStrings(expected, try view.getItem(@intCast(slot)));
    }
}

test "selected slot insertion failure leaves page unchanged" {
    var bytes: [options.page_size]u8 = @splat(0);
    var page = EmptyPage.new(&bytes).mutable();
    _ = try page.addItem("a");
    const before = bytes;
    try std.testing.expectError(error.InvalidSlot, page.addItemAtSlot(0, "x"));
    try std.testing.expectError(error.InvalidSlot, page.addItemAtSlot(3, "x"));
    try std.testing.expectError(error.InvalidItem, page.addItemAtSlot(1, ""));
    var large: [@min(options.page_size, ItemId.max_length)]u8 = @splat(1);
    try std.testing.expectError(error.PageFull, page.addItemAtSlot(1, &large));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
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
    const header_view = try HeaderView.init(bytes[0..HeaderLayout.size]);
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
