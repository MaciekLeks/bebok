pub const Ext2Driver = @import("Ext2Driver.zig");
pub const Ext2 = @import("Ext2.zig");

test "a" {}

pub fn ext2_pub_fn(in: u32) u32 {
    return in + 1;
}

test {
    //@import("std").testing.refAllDeclsRecursive(@This());
    _ = @import("test/tests.zig");
}
