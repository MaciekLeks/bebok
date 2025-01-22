// src/test_root.zig
//pub usingnamespace @import("kernel.zig");
const std = @import("std");
pub const ext2 = @import("ext2");

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("ext2");
}
