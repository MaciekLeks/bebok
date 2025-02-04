const std = @import("std");
const BlockGroupDescriptor = @import("../../types.zig").BlockGroupDescriptor;

pub fn createMockBlockGroupDescriptor(allocator: std.mem.Allocator) !*BlockGroupDescriptor {
    const mock = try allocator.create(BlockGroupDescriptor);
    mock.* = .{
        .block_bitmap = 0,
        .inode_bitmap = 0,
        .inode_table = 0,
        .free_blocks_count = 0,
        .free_inodes_count = 0,
        .used_dirs_count = 0,
        .pad = 0,
        .rsrvd = [_]u8{0} ** 12,
    };
    return mock;
}
