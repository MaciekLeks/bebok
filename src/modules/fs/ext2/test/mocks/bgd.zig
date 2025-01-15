const BlockGroupDescriptor = @import("../../types.zig").BlockGroupDescriptor;

pub const mockBlockGroupDescriptor: BlockGroupDescriptor = .{
    .block_bitmap = 0,
    .inode_bitmap = 0,
    .inode_table = 0,
    .free_blocks_count = 0,
    .free_inodes_count = 0,
    .used_dirs_count = 0,
    .pad = 0,
    .reserved = [_]u8{0} ** 12,
};
