const std = @import("std");

pub const Superblock = packed struct {
    inodes_count: u32, // 0x0 - the total number of inodes, both used and free, in the file system.
    blocks_count: u32, // 0x4 - the total number of blocks in the system including all used, free and reserved
    rsrvd_blocks_count: u32, // 0x8 - the total number of blocks reserved for the usage of the super user
    free_blocks_count: u32, // 0xC -  the total number of free blocks, including the number of reserved blocks
    free_inodes_count: u32, // 0x10 - the total number of free inodes
    first_data_block: u32, // 0x14 - in other word the id of the block containing the superblock structure (Note that this value is always 0 for file systems with a block size larger than 1KB, and always 1 for file systems with a block size of 1KB)
    log_block_size: u32, // 0x18 - block size = 1024 << log_block_size and must be the same as LBA size on the device
    log_frag_size: u32, // 0x1C - if(positive) fragmnet size = 1024 << s_log_frag_size else framgnet size = 1024 >> -s_log_frag_size;
    blocks_per_group: u32, // 0x20 - the total number of blocks per group; this value in combination with s_first_data_block can be used to determine the block groups boundaries.
    frags_per_group: u32, // 0x24 - the total number of fragments per group; it is also used to determine the size of the block bitmap of each block group.
    inodes_per_group: u32, // 0x28 - the total number of inodes per group; this is also used to determine the size of the inode bitmap of each block group.
    mount_time: u32, // 0x2C - the last time the file system was mounted
    write_time: u32, // 0x30 - the last write access to the file system
    mount_count: u16, // 0x34 - the value indicating how many time the file system was mounted since the last time it was fully verified
    max_mount_count: u16, // 0x36 - the maximum number of times that the file system may be mounted before a full check is performed
    magic: u16, // 0x38 (0xEF53) - the file system as Ext2; the value is currently fixed to EXT2_SUPER_MAGIC of value 0xEF53
    state: enum(u16) {
        valid_fs = 1,
        error_fs = 2, //error not means error in the file system but it means that the file system was not unmounted cleanly
    }, // 0x3A - the file system state
    errors: enum(u16) {
        do_continue = 1, //continue as if nothing happened
        do_ro = 2, //remount the file system as read-only
        do_panic = 3, //cause the kernel to panic
    }, // 0x3C - value indicating what the file system driver should do when an error is detected
    minor_rev_level: u16, // 0x3E - the value identifying the minor revision level
    last_check: u32, // 0x40 - the last time the file system was checked
    check_interval: u32, // 0x44 - maximum Unix time interval, as defined by POSIX, allowed between file system checks
    creator_os: enum(u32) {
        os_linux = 0,
        os_hurd = 1,
        os_masix = 2,
        os_freebsd = 3,
        os_lites = 4,
        os_other = 5,
    }, // 0x48 - the identifier of the os that created the file system
    major_rev_level: enum(u32) {
        good_old = 0,
        dynamic = 1,
    }, // 0x4C - the major revision level of the file system
    def_resuid: u16, // 0x50 - the value used as the default user id for reserved blocks
    def_resgid: u16, // 0x52 - the value used as the default group id for reserved blocks

    pub fn isMagicValid(self: *const Superblock) bool {
        return self.magic == 0xEF53;
    }

    pub fn getBlockSize(self: *const Superblock) u64 {
        return @as(u64, 1024) << @as(u6, @truncate(self.log_block_size));
    }

    pub fn getFragSize(self: *const Superblock) u64 {
        return if (self.log_frag_size >= 0) @as(u64, 1024) << @as(u6, @truncate(self.log_frag_size)) else @as(u64, 1024) >> @as(u6, @truncate(self.log_frag_size));
    }

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const fmt_str =
            \\inodes_count: {d}
            \\blocks_count: {d}
            \\rsrvd_blocks_count: {d}
            \\free_blocks_count: {d}
            \\free_inodes_count: {d}
            \\first_data_block: {d}
            \\block_size: {d}
            \\frag_size: {d}
        ;

        _ = try writer.print(fmt_str, .{ self.inodes_count, self.blocks_count, self.rsrvd_blocks_count, self.free_blocks_count, self.free_inodes_count, self.first_data_block, self.getBlockSize(), self.getFragSize() });
    }
};
