const std = @import("std");
const builtin = @import("builtin");

// pub const BlockAddressing = struct {
//     /// Convert byte offset to block number
//     pub fn getBlockId(comptime block_size: usize, offset: usize) usize {
//         return offset / block_size;
//     }
//
//     /// Get offset within a block
//     pub fn getOffsetInBlock(comptime block_size: usize, offset: usize) usize {
//         return offset % block_size;
//     }
//
//     /// Convert block number to byte offset
//     pub fn blockIdToOffset(comptime block_size: usize, block_id: usize) usize {
//         return block_id * block_size;
//     }
//
//     /// Get block number containing BGDT
//     /// Returns 2 for 1024-byte blocks, 1 for larger blocks
//     pub fn getBGDTStartBlockId(comptime block_size: usize) usize {
//         if (block_size <= 1024) {
//             return 2;
//         }
//         return 1;
//     }
// };

pub const BlockNum = u32;

pub const Superblock = extern struct {
    comptime {
        //@compileLog("Superblock size: {}\n", .{ @sizeOf(@This()) });
        if (@sizeOf(@This()) != 1024) {
            @compileError("Superblock size must be 1024 bytes");
        }
    }

    //Constants
    /// Superblock always starts at byte 1024
    pub const offset: usize = 1024;

    ///Features that can be safely ignored - filesystem can be mounted (for read/write even if these features are not supported)
    const FeatureCompatFlags = packed struct(u32) {
        dir_prealloc: bool = false,
        imagic_inodes: bool = false,
        has_journal: bool = false,
        ext_attr: bool = false,
        resize_inode: bool = false,
        dir_index: bool = false,
        rsrvd: u26 = 0,
    };
    ///Features that must be supported to mount filesystem at all - Mount will fail if any of these features is not supported
    const FeatureIncompatFlags = packed struct(u32) {
        compression: bool = false,
        file_type: bool = false,
        needs_recovery: bool = false,
        journal_dev: bool = false,
        meta_bg: bool = false,

        rsrvd: u27 = 0,
    };

    ///Features that must be supported for write operations - Filesystem can be mounted read-only if these features are not supported
    const FeatureRoCompatFlags = packed struct(u32) {
        sparse_super: bool = false,
        large_file: bool = false,
        btrees: bool = false,
        rsrvd: u29 = 0,
    };
    const CompressionAlgorithm = packed struct(u32) {
        lzv1: bool = false,
        lzrw3a: bool = false,
        gzip: bool = false,
        bzip2: bool = false,
        lzo: bool = false,
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
    last_mounted: [64]u8 align(1), // 0x88 - the directory where the file system was last mounted
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

    pub fn isBlockSizeValid(self: *const Superblock, comptime page_size: usize) bool {
        return self.getBlockSize() == page_size;
    }

    pub fn isRequiredCompat(self: *const Superblock, flags: u32) bool {
        return (self.feature_compat & flags) != 0;
    }

    pub fn getBlockSize(self: *const Superblock) u64 {
        return if (!builtin.is_test) @as(u64, 1024) << @as(u6, @truncate(self.log_block_size)) else 2;
    }

    pub fn getFragSize(self: *const Superblock) u64 {
        return if (self.log_frag_size >= 0) @as(u64, 1024) << @as(u6, @truncate(self.log_frag_size)) else @as(u64, 1024) >> @as(u6, @truncate(self.log_frag_size));
    }

    /// Block groups count is a ceiling division of blocks_count by blocks_per_group
    pub fn getBlockGroupsCount(self: *const Superblock) u32 {
        return std.math.divCeil(u32, self.blocks_count, self.blocks_per_group) catch blk: {
            break :blk 0;
        };
    }

    ///ISO Latin-1 (ISO-8859-1) string
    pub fn getName(self: *const Superblock) []const u8 {
        return std.mem.sliceTo(&self.volume_name, 0);
    }

    pub fn getLastMounted(self: *const Superblock) []const u8 {
        return std.mem.sliceTo(&self.last_mounted, 0);
    }

    /// Get block number containing superblock
    /// Returns 1 for 1024-byte blocks, 0 for larger blocks
    pub fn getBlockNum(comptime block_size: usize) usize {
        if (block_size <= 1024) {
            return 1;
        }
        return 0;
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
            \\last_mounted: {s}
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
        _ = try writer.print(fmt_dynamic_rev, .{ self.first_ino, self.inode_size, self.block_group_nr, self.feature_compat, self.feature_incompat, self.feature_ro_compat, self.uuid, self.getName(), self.getLastMounted(), self.algo_bitmap });
        _ = try writer.print(fmt_performance_hints, .{ self.prealloc_blocks, self.prealloc_dir_blocks });
        _ = try writer.print(fmt_journaling_support, .{ self.journal_uuid, self.journal_inum, self.journal_dev, self.last_orphan, self.hash_seed, self.def_hash_version });
        _ = try writer.print(fmt_other_options, .{ self.default_mount_options, self.first_meta_bg });
    }
};

pub const BlockGroupDescriptor = extern struct {
    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }

    block_bitmap: u32 align(1), // 0x0 - the block number of the block containing the block bitmap for this group
    inode_bitmap: u32 align(1), // 0x4 - the block number of the block containing the inode bitmap for this group
    inode_table: u32 align(1), // 0x8 - the block number of the block containing the inode table for this group
    free_blocks_count: u16 align(1), // 0xC - the total number of free blocks in the block group
    free_inodes_count: u16 align(1), // 0xE - the total number of free inodes in the block group
    used_dirs_count: u16 align(1), // 0x10 - the total number of inodes allocated to directories in the block group
    pad: u16 align(1), // 0x12 - padding
    rsrvd: [12]u8 align(1), // 0x14 - reserved

    pub fn getTableOffset(comptime block_size: usize) usize {
        return block_size * (Superblock.getBlockNum(block_size) + 1);
    }
};

pub const Inode = extern struct {
    const Mode = packed struct(u16) {
        pub const Format = enum(u4) {
            none = 0x0,
            fifo = 0x1,
            character_device = 0x2,
            directory = 0x4,
            block_device = 0x6,
            regular_file = 0x8,
            symbolic_link = 0xA,
            socket = 0xC,
            _,
        };
        permissions: packed struct(u9) {
            other_execute: bool = false,
            other_write: bool = false,
            other_read: bool = false,
            group_execute: bool = false,
            group_write: bool = false,
            group_read: bool = false,
            user_execute: bool = false,
            user_write: bool = false,
            user_read: bool = false,
        },
        process_flags: packed struct(u3) {
            sticky_bit: bool = false,
            set_process_gid: bool = false,
            set_process_user_id: bool = false,
        },
        format: Format,
    };
    const Flags = packed struct(u32) {
        secure_deletion: bool = false, //0x00000001
        keep_copy: bool = false, //0x00000002
        file_compression: bool = false, //0x00000004
        sync_updates: bool = false, //0x00000008
        immutable_file: bool = false, //0x00000010
        append_only: bool = false, //0x00000020
        no_dump: bool = false, //0x00000040
        no_atime: bool = false, //0x00000080
        //Reserved for compression usage
        dirty_compression: bool = false, //0x00000100
        compress_blocks: bool = false, //0x00000200
        no_commpress: bool = false, //0x00000400
        error_compress: bool = false, //0x00000800
        //Reserved for encryption usage
        btree: bool = false, //0x00001000
        index: bool = false, //0x00002000
        afs: bool = false, //0x00004000
        journal: bool = false, //0x00008000
        rsrvd: u16 = 0,
    };
    // Fixed part (128 bytes)
    mode: Mode align(1), // File mode and permissions
    uid: u16 align(1), // Owner's user ID
    size: u32 align(1), // Size in bytes,In revision 1 and later revisions, and only for regular files, this represents the lower 32-bit of the file size; the upper 32-bit is located in the dir_acl.
    atime: u32 align(1), // The number of seconds since january 1st 1970 of the last time this inode was accessed
    ctime: u32 align(1), // Creation time, the same alg as for atime
    mtime: u32 align(1), // Last modification time, the same alg as for atime
    dtime: u32 align(1), // Deletion time, the same alg as for atime
    gid: u16 align(1), // The POSIX group ID
    links_count: u16 align(1), // Number of hard links (value indicating how many times this particular inode is linked. Most files will have a link count of 1. Files with hard links pointing to them will have an additional count for each hard link.)
    blocks: u32 align(1), // Number of 512-byte blocks [Since this value represents 512-byte blocks and not file system blocks, this value should not be directly used as an index to the i_block array. Rather, the maximum index of the i_block array should be computed from i_blocks / ((1024<<s_log_block_size)/512), or once simplified, i_blocks/(2<<s_log_block_size).]
    flags: Flags align(1), // Value indicating how the ext2 implementation should behave when accessing the data for this inode
    osd1: u32 align(1), // OS-specific value
    block: [15]u32 align(1), // Pointers to data blocks
    generation: u32 align(1), // File version number
    file_acl: u32 align(1), // Extended attribute block
    dir_acl: u32 align(1), // Extended attribute block for directory, In revision 1, for regular files this 32bit value contains the high 32 bits of the 64bit file size.
    faddr: u32 align(1), // Fragment address,
    osd2: [3]u32 align(1), // OS-specific values

    // Extended part (size depends on inode size)
    extra_isize: u16 align(1), // Size of extra fields
    pad1: u16 align(1), // Padding
    ctime_extra: u32 align(1), // Extra change time (nanoseconds)
    mtime_extra: u32 align(1), // Extra modification time (nanoseconds)
    atime_extra: u32 align(1), // Extra access time (nanoseconds)
    crtime: u32 align(1), // File creation time
    crtime_extra: u32 align(1), // Extra creation time (nanoseconds)
    version_hi: u32 align(1), // High 32 bits for 64-bit version

    pub fn isDirectory(self: *const Inode) bool {
        return self.mode.format == Mode.Format.directory;
    }
};

pub const LinkedDirectoryEntry = struct {
    const Self = @This();
    const FileType = enum(u8) {
        unknown = 0,
        regular_file = 1,
        directory = 2,
        character_device = 3,
        block_device = 4,
        fifo = 5,
        socket = 6,
        symbolic_link = 7,
    };

    const Header = packed struct {
        inode: u32, // 0x0 - the inode number of the file entry
        rec_len: u16, // 0x4 - the length of this directory entry
        name_len: u8, // 0x6 - the length of the file name
        file_type: FileType, // 0x7 - the type of the file
    };

    header: Header, // 0x0 - the header of the directory entry
    name_buffer: []u8, // 0x8 - the name of the file

    pub inline fn getRecordLength(self: *const Self) u16 {
        return self.header.rec_len;
    }

    pub fn getName(self: *const Self) []const u8 {
        return self.name_buffer[0..self.header.name_len];
    }

    pub fn readFrom(reader: anytype, name_buffer: []u8) !LinkedDirectoryEntry {
        //Read the constant part of the directory entry
        const header = try reader.readStructEndian(Header, .little);

        //Check space in the buffer
        if (name_buffer.len < header.name_len) return error.BufferToSmall;

        //Read the name
        const name_len = try reader.readAll(name_buffer[0..header.name_len]);
        if (name_len != header.name_len) return error.UnexpectedEOF;

        //Read padding (every record is multiple of 4 bytes)
        const padding = header.rec_len - header.name_len - @sizeOf(Header);
        try reader.skipBytes(padding, .{});

        return LinkedDirectoryEntry{ .header = header, .name_buffer = name_buffer[0..header.name_len] };
    }
};
