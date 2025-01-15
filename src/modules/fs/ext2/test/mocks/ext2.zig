const std = @import("std");
const Ext2 = @import("../../Ext2.zig");
const BlockGroupDescriptor = @import("../../types.zig").BlockGroupDescriptor;
const mpart = @import("../../../../../devices/block/test/mocks/partition.zig");
const msuper = @import("../../test/mocks/superblock.zig");
const mbgd = @import("../../test/mocks/bgd.zig");

pub fn mockExt2(allocator: std.mem.Allocator) Ext2 {
    return .{
        .allocator = allocator,
        .partition = &mpart.mockPartition(allocator),
        .superblock = &msuper.mockSuperblock,
        .block_group_descriptor_table = &[_]BlockGroupDescriptor{mbgd.mockBlockGroupDescriptor},
    };
}
