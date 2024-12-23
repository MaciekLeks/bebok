const std = @import("std");

//const log = std.log.scoped(.ext2_types);

pub const Superblock = extern struct {
    ///Features that can be safely ignored - filesystem can be mounted (for read/write even if these features are not supported)
    const FeatureCompatFlags = packed struct(u32) {
        dir_prealloc: bool,
        imagic_inodes: bool,
        has_journal: bool,
        ext_attr: bool,
        resize_inode: bool,
        dir_index: bool,
        rsrvd: u26 = 0,
    };
    ///Features that must be supported to mount filesystem at all - Mount will fail if any of these features is not supported
    const FeatureIncompatFlags = packed struct(u32) {
        compression: bool,
        file_type: bool,
        needs_recovery: bool,
        journal_dev: bool,
        meta_bg: bool,

        rsrvd: u27 = 0,
    };

    ///Features that must be supported for write operations - Filesystem can be mounted read-only if these features are not supported
    const FeatureRoCompatFlags = packed struct(u32) {
        sparse_super: bool,
        large_file: bool,
        btrees: bool,
        rsrvd: u29 = 0,
    };
    const CompressionAlgorithm = packed struct(u32) {
        lzv1: bool,
        lzrw3a: bool,
        gzip: bool,
        bzip2: bool,
        lzo: bool,
        rsrvd: u27 = 0,
    };

    //
    // Base Superblock fields
    //
    inodes_count: u32 align(1), // 0x0 - the total number of inodes, both used and free, in the file system.
    blocks_count: u32 align(1), // 0x4 - the total number of blocks in the system including all used, free and reserved
    rsrvd_blocks_count: u32 align(1), // 0x8 - the total number of blocks reserved for the usage of the super user
    free_blocks_count: u32 align(1), // 0xC -  the total number of free blocks, including the number of reserved blocks
    free_inodes_count: u32 align(1), // 0x10 - the total number of free inodes
    first_data_block: u32 align(1), // 0x14 - in other word the id of the block containing the superblock structure (Note that this value is always 0 for file systems with a block size larger than 1KB, and always 1 for file systems with a block size of 1KB)
    log_block_size: u32 align(1), // 0x18 - block size = 1024 << log_block_size and must be the same as LBA size on the device
    log_frag_size: u32 align(1), // 0x1C - if(positive) fragmnet size = 1024 << s_log_frag_size else framgnet size = 1024 >> -s_log_frag_size;
    blocks_per_group: u32 align(1), // 0x20 - the total number of blocks per group; this value in combination with s_first_data_block can be used to determine the block groups boundaries.
    frags_per_group: u32 align(1), // 0x24 - the total number of fragments per group; it is also used to determine the size of the block bitmap of each block group.
    inodes_per_group: u32 align(1), // 0x28 - the total number of inodes per group; this is also used to determine the size of the inode bitmap of each block group.
    mount_time: u32 align(1), // 0x2C - the last time the file system was mounted
    write_time: u32 align(1), // 0x30 - the last write access to the file system
    mount_count: u16 align(1), // 0x34 - the value indicating how many time the file system was mounted since the last time it was fully verified
    max_mount_count: u16 align(1), // 0x36 - the maximum number of times that the file system may be mounted before a full check is performed
    magic: u16 align(1), // 0x38 (0xEF53) - the file system as Ext2; the value is currently fixed to EXT2_SUPER_MAGIC of value 0xEF53
    state: enum(u16) {
        unknown = 0, //the file system is in an unknown state
        valid_fs = 1,
        error_fs = 2, //error not means error in the file system but it means that the file system was not unmounted cleanly
    } align(1), // 0x3A - the file system state
    errors: enum(u16) {
        do_continue = 1, //continue as if nothing happened
        do_ro = 2, //remount the file system as read-only
        do_panic = 3, //cause the kernel to panic
    } align(1), // 0x3C - value indicating what the file system driver should do when an error is detected
    minor_rev_level: u16 align(1), // 0x3E - the value identifying the minor revision level
    last_check: u32 align(1), // 0x40 - the last time the file system was checked
    check_interval: u32 align(1), // 0x44 - maximum Unix time interval, as defined by POSIX, allowed between file system checks
    creator_os: enum(u32) {
        os_linux = 0,
        os_hurd = 1,
        os_masix = 2,
        os_freebsd = 3,
        os_lites = 4,
        os_other = 5,
    } align(1), // 0x48 - the identifier of the os that created the file system
    major_rev_level: enum(u32) {
        good_old = 0,
        dynamic = 1,
    } align(1), // 0x4C - the major revision level of the file system
    def_resuid: u16 align(1), // 0x50 - the value used as the default user id for reserved blocks
    def_resgid: u16 align(1), // 0x52 - the value used as the default group id for reserved blocks
    //
    // Dynamic revision specific fields
    //
    first_ino: u32 align(1), // 0x54 - the first non-reserved inode
    inode_size: u16 align(1), // 0x58 - the size of the inode structure, this value must be a perfect power of 2 and must be smaller or equal to the block size (1<<s_log_block_size)
    block_group_nr: u16 align(1), // 0x5A - the block group number of the block containing this superblock structure
    feature_compat: FeatureCompatFlags align(1), // 0x5C - the optional feature set
    feature_incompat: FeatureIncompatFlags align(1), // 0x60 - the required feature set
    feature_ro_compat: FeatureRoCompatFlags align(1), // 0x64 - the read-only feature set
    uuid: u128 align(1), // 0x68 - the 128-bit uuid for the file system
    volume_name: [16]u8 align(1), // 0x78 - the volume name
    algo_bitmap: CompressionAlgorithm align(1), // 0x88 - the compression algorithm used
    //
    // Performance hints
    //
    prealloc_blocks: u8 align(1), // 0x8C - the number of blocks to preallocate for a file the implementation should attempt to pre-allocate when creating it
    prealloc_dir_blocks: u8 align(1), // 0x8D - the number of blocks to preallocate for a directory the implementation should attempt to pre-allocate when creating it
    rsrvd_a: [2]u8 align(1), // 0x8E - reserved for alignment
    //
    // Journaling support
    //
    journal_uuid: u128 align(1), // 0x90 - the uuid of the journal superblock - Ext3 specific
    journal_inum: u32 align(1), // 0x9C - the inode number of the journal file - Ext3 specific
    journal_dev: u32 align(1), // 0xA0 - the device number of the journal file - Ext3 specific
    last_orphan: u32 align(1), // 0xA4 - the first inode number that is not in use - Ext3 specific
    //
    // Directory indexing support
    //
    hash_seed: [4]u32 align(1), // 0xA8 - the seed used for the hash algorithm
    def_hash_version: u8 align(1), // 0xB8 - the default hash version - Ext3 specific
    rsrvd_b: [3]u8 align(1), // 0xB9 - reseved for padding
    //
    // Other options
    //
    default_mount_options: u32 align(1), // 0xB9 - the default mount options - Ext3 specific
    first_meta_bg: u32 align(1), // 0xBD - the first block group that contains metadata blocks - Ext3 specific
    rsrvd_c: [760]u8 align(1), // 0xC1 - unused

    pub fn isMagicValid(self: *const Superblock) bool {
        return self.magic == 0xEF53;
    }

    // We support only the dynamic revision
    pub fn isMajorValid(self: *const Superblock) bool {
        return self.major_rev_level == .dynamic;
    }

    pub fn isRequiredCompat(self: *const Superblock, flags: u32) bool {
        return (self.feature_compat & flags) != 0;
    }

    pub fn getBlockSize(self: *const Superblock) u64 {
        return @as(u64, 1024) << @as(u6, @truncate(self.log_block_size));
    }

    pub fn getFragSize(self: *const Superblock) u64 {
        return if (self.log_frag_size >= 0) @as(u64, 1024) << @as(u6, @truncate(self.log_frag_size)) else @as(u64, 1024) >> @as(u6, @truncate(self.log_frag_size));
    }

    pub fn getBlockGroupsCount(self: *const Superblock) u32 {
        return self.blocks_count / self.blocks_per_group;
    }

    ///ISO Latin-1 (ISO-8859-1) string
    pub fn getName(self: *const Superblock) []const u8 {
        return std.mem.sliceTo(&self.volume_name, 0);
    }

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const fmt_base =
            \\Superblock base fields:
            \\inodes_count: {d}
            \\blocks_count: {d}
            \\rsrvd_blocks_count: {d}
            \\free_blocks_count: {d}
            \\free_inodes_count: {d}
            \\first_data_block: {d}
            \\block_size: {d}
            \\frag_size: {d}
            \\blocks_per_group: {d}
            \\frags_per_group: {d}
            \\inodes_per_group: {d}
            \\block_groups_count: {d}
            \\
            \\state: {}
            \\errors: {}
            \\
            \\minor_rev_level: {d}
            \\major_rev_level: {}
            \\  
        ;

        const fmt_dynamic_rev =
            \\Superblock extended fields:
            \\first_ino: {d}
            \\inode_size: {d}
            \\block_group_nr: {d}
            \\feature_compat: {}
            \\feature_incompat: {}
            \\feature_ro_compat: {}
            \\uuid: {x}
            \\volume_name: {s}
            \\algo_bitmap: {}
            \\
        ;

        const fmt_performance_hints =
            \\Superblock performance hints:
            \\prealloc_blocks: {d}
            \\prealloc_dir_blocks: {d}
            \\
        ;
        const fmt_journaling_support =
            \\Superblock journaling support:
            \\journal_uuid: {x}
            \\journal_inum: {d}
            \\journal_dev: {d}
            \\last_orphan: {d}
            \\hash_seed: {any}
            \\def_hash_version: {d}
            \\
        ;

        const fmt_other_options =
            \\Superblock other options:
            \\default_mount_options: {d}
            \\first_meta_bg: {d}
        ;

        _ = try writer.print(fmt_base, .{ self.inodes_count, self.blocks_count, self.rsrvd_blocks_count, self.free_blocks_count, self.free_inodes_count, self.first_data_block, self.getBlockSize(), self.getFragSize(), self.blocks_per_group, self.frags_per_group, self.inodes_per_group, self.getBlockGroupsCount(), self.state, self.errors, self.minor_rev_level, self.major_rev_level });
        _ = try writer.print(fmt_dynamic_rev, .{ self.first_ino, self.inode_size, self.block_group_nr, self.feature_compat, self.feature_incompat, self.feature_ro_compat, self.uuid, self.getName(), self.algo_bitmap });
        _ = try writer.print(fmt_performance_hints, .{ self.prealloc_blocks, self.prealloc_dir_blocks });
        _ = try writer.print(fmt_journaling_support, .{ self.journal_uuid, self.journal_inum, self.journal_dev, self.last_orphan, self.hash_seed, self.def_hash_version });
        _ = try writer.print(fmt_other_options, .{ self.default_mount_options, self.first_meta_bg });
    }
};
