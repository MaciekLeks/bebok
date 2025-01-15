const Inode = @import("../../types.zig").Inode;

pub const MockInode: Inode = .{
    .mode = 0,
    .uid = 0,
    .size = 0,
    .atime = 0,
    .ctime = 0,
    .mtime = 0,
    .dtime = 0,
    .gid = 0,
    .links_count = 0,
    .blocks = 0,
    .flags = 0,
    .osd1 = 0,
    .block = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .generation = 0,
    .file_acl = 0,
    .dir_acl = 0,
    .faddr = 0,
    .osd2 = 0,
};
