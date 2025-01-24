// src/test_root.zig
//pub usingnamespace @import("kernel.zig");
pub const ext2 = @import("ext2");

test "maciek_test" {}
test "maciek_test2" {}

test {
    @import("std").testing.refAllDecls(@This());
    //_ = ext2;
}
