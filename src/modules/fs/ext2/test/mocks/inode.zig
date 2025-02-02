const Inode = @import("../../types.zig").Inode;
const BlockNum = @import("../../types.zig").BlockNum;

pub fn mockExt2(block: []BlockNum) Inode {
    var inode = .{
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
        .block = undefined,
        .generation = 0,
        .file_acl = 0,
        .dir_acl = 0,
        .faddr = 0,
        .osd2 = 0,
    };
    @memcpy(inode.block[0..], block);
}
