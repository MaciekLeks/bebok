const std = @import("std");
const Ext2 = @import("../../Ext2.zig");
const BlockGroupDescriptor = @import("../../types.zig").BlockGroupDescriptor;
const mdev = @import("devices");
const msuper = @import("./superblock.zig");
const mbgd = @import("../../test/mocks/bgd.zig");

pub fn createMockExt2(allocator: std.mem.Allocator) !*Ext2 {
    const mock = try allocator.create(Ext2);
    const bgdt = try allocator.alloc(BlockGroupDescriptor, 1);
    bgdt[0] = (try mbgd.createMockBlockGroupDescriptor(allocator)).*;
    mock.* = .{
        .alloctr = allocator,
        .partition = try mdev.createMockPartition(allocator),
        .superblock = try msuper.createMockSupeblock(allocator),
        .block_group_descriptor_table = bgdt,
    };
    return mock;
}
