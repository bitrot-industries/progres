const std = @import("std");
const page = @import("page");
const Header = @import("tuple/header.zig").Header;

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
};

test {
    _ = Header;
}
