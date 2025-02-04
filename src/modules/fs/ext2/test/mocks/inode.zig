const std = @import("std");
const Inode = @import("../../types.zig").Inode;
const BlockNum = @import("../../types.zig").BlockNum;

pub fn createMockInode(allocator: std.mem.Allocator, block: []BlockNum) !*Inode {
    const mock = try allocator.create(Inode);
    mock.* = .{
        .mode = .{
            .permissions = .{},
            .process_flags = .{},
            .format = .block_device,
        },
        .uid = 0,
        .size = 0,
        .atime = 0,
        .ctime = 0,
        .mtime = 0,
        .dtime = 0,
        .gid = 0,
        .links_count = 0,
        .blocks = 0,
        .flags = .{},
        .osd1 = 0,
        .block = undefined,
        .generation = 0,
        .file_acl = 0,
        .dir_acl = 0,
        .faddr = 0,
        .osd2 = [_]u32{0} ** 3,

        .extra_isize = 0,
        .pad1 = 0,
        .ctime_extra = 0,
        .mtime_extra = 0,
        .atime_extra = 0,
        .crtime = 0,
        .crtime_extra = 0,
        .version_hi = 0,
    };
    @memcpy(mock.block[0..], block);
    return mock;
}
