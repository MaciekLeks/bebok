const std = @import("std");
const Ext2 = @import("../Ext2.zig");
const mext2 = @import("mocks/ext2.zig");
const mionode = @import("mocks/inode.zig");

test "InodeBlockIterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mext = mext2.mockExt2(allocator);
    const minode = mionode.mockInode;

    std.debug.print("mext: {}\n", .{mext});

    var iter = try Ext2.InodeBlockIterator.init(allocator, &mext, &minode);
    _ = &iter;
}

test "dwa" {}

test "trzy" {}
