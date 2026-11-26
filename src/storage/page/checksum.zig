//! Page checksum calculation and integration.

const std = @import("std");
const options = @import("options");

const initial = [32]u32{
    0x5B1F36E9, 0xB8525960, 0x02AB50AA, 0x1DE66D2A,
    0x79FF467A, 0x9BB9F8A3, 0x217E7CD2, 0x83E13D2C,
    0xF8D4474F, 0xE39EB970, 0x42C6AE16, 0x993216FA,
    0x7B093B5D, 0x98DAFF3C, 0xF718902A, 0x0B1C9CDB,
    0xE58F764B, 0x187636BC, 0x5D7B3BB1, 0xE73DE7DE,
    0x92BEC979, 0xCCA6C0B2, 0x304A0979, 0x85AA43D4,
    0x783125BB, 0x6CA8EAA2, 0xE407EAC6, 0x4B5CFC3E,
    0x9FBF8C76, 0x15CA20BE, 0xF2CA9FD3, 0x959BD756,
};

/// Calculate the page checksum without modifying the input page.
/// The checksum field itself is treated as zero, and block_number is
/// relative to the relation fork. Word decoding follows the host byte order.
pub fn calculate(bytes: *const [options.page_size]u8, block_number: u32) u16 {
    var sums = initial;
    for (0..options.page_size / 128) |row| {
        for (0..32) |col| {
            const offset = row * 128 + col * 4;
            const value = if (offset == 8)
                // Bytes 8..10 contain the checksum; flags at 10..12 remain.
                std.mem.readInt(u32, &.{ 0, 0, bytes[10], bytes[11] }, .native)
            else
                std.mem.readInt(u32, bytes[offset..][0..4], .native);
            mix(&sums[col], value);
        }
    }
    for (0..2) |_| for (&sums) |*sum| mix(sum, 0);
    var result: u32 = 0;
    for (sums) |sum| result ^= sum;
    result ^= block_number;
    return @intCast(result % 65535 + 1);
}

fn mix(sum: *u32, value: u32) void {
    const tmp = sum.* ^ value;
    sum.* = (tmp *% 16777619) ^ (tmp >> 17);
}
