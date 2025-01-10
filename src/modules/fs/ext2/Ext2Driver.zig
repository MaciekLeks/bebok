const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const FilesystemDriver = @import("deps.zig").FilesystemDriver;
const Superblock = @import("types.zig").Superblock;
const BlockGroupDescriptor = @import("types.zig").BlockGroupDescriptor;

const Ext2 = @import("Ext2.zig");
const BlockAddressing = @import("types.zig").BlockAddressing;
const Inode = @import("types.zig").Inode;

const pmm = @import("deps.zig").pmm; //block size should be the same as the page size
const block_size = pmm.page_size;

const log = std.log.scoped(.ext2);

const Ext2Driver = @This();

// Resolve ext2 filesystem and attach it to the partition
// From now on, the partition will be able to use the filesystem and must deinit it later
pub fn resolve(_: *anyopaque, allocator: std.mem.Allocator, partition: *Partition) !bool {
    log.info("Resolving ext2 filesystem", .{});
    const streamer = partition.block_device.streamer();
    var stream = BlockDevice.Stream(u8).init(streamer);
    // Go to superblock position, always 1024 in the ext2 partition
    stream.seek(Superblock.offset, .start);

    var superblock = try allocator.create(Superblock);
    errdefer allocator.destroy(superblock); //TODO: until we now what to do with it
    try stream.readAll(std.mem.asBytes(superblock));

    if (!superblock.isMagicValid()) {
        log.debug("Invalid magic number: {x}", .{superblock.magic});
        return false;
    }

    if (!superblock.isMajorValid()) {
        log.warn("Unsupported major revision level: {}", .{superblock.major_rev_level});
        return false;
    }

    if (!superblock.isBlockSizeValid(pmm.page_size)) {
        log.warn("Unsupported block size: {}", .{superblock.getBlockSize()});
        return false;
    }

    log.info("Ext2 filesystem detected", .{});

    const bgdt = try allocator.alloc(BlockGroupDescriptor, superblock.getBlockGroupsCount());
    errdefer allocator.free(bgdt);

    var stream_bgdt = BlockDevice.Stream(BlockGroupDescriptor).init(streamer);
    stream_bgdt.seek(BlockGroupDescriptor.getTableOffset(pmm.page_size), .start);

    try stream_bgdt.readAll(bgdt);
    for (bgdt, 0..) |*bgd, i| {
        log.debug("pos:{d} Block Group Descriptor[{d}]:{}", .{ stream.pos, i, bgd });
        //try listInodes(allocator, superblock, bgd, streamer);
    }

    log.debug("Superblock: {}", .{superblock});

    // Attach filesystem to the partition
    const ext_fs = try Ext2.init(allocator, partition, superblock, bgdt);
    partition.filesystem = ext_fs.filesystem();

    //{TODO: remove this
    const block_buffer = try allocator.alloc(u8, superblock.getBlockSize());
    defer allocator.free(block_buffer);

    const inode = try ext_fs.readInode(2, block_buffer);
    var diter = ext_fs.linkedDirectoryIterator(&inode, block_buffer);
    var name_buffer: [256]u8 = undefined;
    while (diter.next(&name_buffer)) |opt_entry| {
        if (opt_entry) |entry|
            log.debug("Entry: header: {} name: {s}", .{ entry.header, entry.getName() })
        else
            break;
    } else |err| {
        log.err("Error: {}", .{err});
    }

    // _ = ext_fs.findInodeByPath("/dir01/test-file2.txt", null) catch |err| {
    //_ = ext_fs.findInodeByPath("/dir01/", null) catch |err| {
    // _ = ext_fs.findInodeByPath("test-file2.txt", 16385) catch |err| { //16385 is the inode number of the dir01 directory
    // _ = ext_fs.findInodeByPath("/test-file1.txt", null) catch |err| {
    //_ = ext_fs.findInodeByPath("/", null) catch |err| {
    _ = ext_fs.findInodeByPath("/no-file-there", null) catch |err| {
        log.err("findInodeByPath error: {any}", .{err});
    };

    return true;
}

// fn listInodes(allocator: std.mem.Allocator, sb: *const Superblock, bgd: *const BlockGroupDescriptor, streamer: BlockDevice.Streamer) !void {
//     //find block id in Block Group Descriptor
//     const inode_size = sb.inode_size;
//     const inode_count = sb.inodes_per_group;
//     const inode_table_size = inode_size * inode_count;
//
//     var inode_stream = BlockDevice.Stream(u8).init(streamer);
//     inode_stream.seek(BlockAddressing.blockIdToOffset(block_size, bgd.inode_table_id), .start);
//
//     const raw_inode_table = try allocator.alloc(u8, inode_table_size);
//     defer allocator.free(raw_inode_table);
//
//     try inode_stream.readAll(raw_inode_table);
//
//     // map inode_count Inodes from []u8
//     for (0..inode_count) |i| {
//         const inode_table = raw_inode_table[i * inode_size .. (i + 1) * inode_size];
//         const inode: *const Inode = @ptrCast(@alignCast(inode_table.ptr));
//         log.debug("Inode[{d}]: {}", .{ i, inode.* });
//     }
// }
//
pub fn driver(self: *Ext2Driver) FilesystemDriver {
    const vtable = FilesystemDriver.VTable{
        .resolve = resolve,
    };
    return FilesystemDriver.init(self, vtable);
}
