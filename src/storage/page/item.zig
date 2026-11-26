//! Line-pointer representation.
const std = @import("std");

/// A line pointer locates an item within one page and records its state.
pub const ItemId = packed struct(u32) {
    offset: u15,
    state: State,
    length: u15,

    pub const State = enum(u2) {
        unused = 0,
        normal = 1,
        redirect = 2,
        dead = 3,
    };

    pub const size = @sizeOf(u32);
    pub const max_length = std.math.maxInt(u15);

    /// Construct a normal line pointer. Both values must fit in 15 bits.
    pub fn normal(offset: usize, length: usize) ItemId {
        return .{ .offset = @intCast(offset), .state = .normal, .length = @intCast(length) };
    }

    /// Encode the line pointer using the page's little-endian byte order.
    pub fn encode(self: ItemId, bytes: *[size]u8) void {
        std.mem.writeInt(u32, bytes, @bitCast(self), .little);
    }

    pub fn decode(bytes: *const [size]u8) ItemId {
        const value = std.mem.readInt(u32, bytes, .little);
        return @bitCast(value);
    }

    pub fn isReusable(self: ItemId) bool {
        return self.state == .unused and self.length == 0;
    }
};

test "normal item ID encodes offset, state, and length" {
    const id = ItemId.normal(0x1234, 5);
    var bytes: [ItemId.size]u8 = undefined;
    id.encode(&bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x92, 0x0a, 0x00 }, &bytes);
}

test "decode reads offset, state, and length from line-pointer bytes" {
    // Known bytes independently specify the fields, not just an encode/decode round trip.
    const bytes = [ItemId.size]u8{ 0x34, 0x92, 0x0a, 0x00 };
    const id = ItemId.decode(&bytes);

    try std.testing.expectEqual(@as(u15, 0x1234), id.offset);
    try std.testing.expectEqual(ItemId.State.normal, id.state);
    try std.testing.expectEqual(@as(u15, 5), id.length);
}
