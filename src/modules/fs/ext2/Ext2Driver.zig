const std = @import("std");

const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Filesystem = @import("fs").Filesystem;
const FilesystemDriver = @import("fs").FilesystemDriver;
const Superblock = @import("types.zig").Superblock;
const BlockGroupDescriptor = @import("types.zig").BlockGroupDescriptor;

const Ext2 = @import("Ext2.zig");
const BlockAddressing = @import("types.zig").BlockAddressing;
const Inode = @import("types.zig").Inode;

const pmm = @import("mem").pmm; //block size should be the same as the page size
const block_size = pmm.page_size;
const heap = @import("mem").heap;

const log = std.log.scoped(.ext2);

const Ext2Driver = @This();

//Fields
alloctr: std.mem.Allocator,

pub fn new(allocator: std.mem.Allocator) !*Ext2Driver {
    const self = try allocator.create(Ext2Driver);
    self.* = .{};
}

pub fn destroy(self: *Ext2Driver) void {
    self.alloctr.destroy(self);
}

// Resolve ext2 filesystem and attach it to the partition
// From now on, the partition will be able to use the filesystem and must deinit it later
pub fn resolve(_: *Ext2Driver, allocator: std.mem.Allocator, partition: *Partition) !?Filesystem {
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
        return null;
    }

    if (!superblock.isMajorValid()) {
        log.warn("Unsupported major revision level: {}", .{superblock.major_rev_level});
        return null;
    }

    if (!superblock.isBlockSizeValid(pmm.page_size)) {
        log.warn("Unsupported block size: {}", .{superblock.getBlockSize()});
        return null;
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
    const ext_fs = try Ext2.new(allocator, partition, superblock, bgdt);
    //partition.filesystem = ext_fs.filesystem();

    //{TODO: remove this
    // var tmp_arena = std.heap.ArenaAllocator.init(heap.page_allocator);
    // defer tmp_arena.deinit();
    // const tmp_alloc = tmp_arena.allocator();
    // const block_buffer = try tmp_alloc.alloc(u8, superblock.getBlockSize());
    //
    // const inode = try ext_fs.readInodeInternal(2, block_buffer);
    // var diter = try ext_fs.linkedDirectoryIterator(tmp_alloc, &inode);
    // var name_buffer: [256]u8 = undefined;
    // while (diter.next(&name_buffer)) |opt_entry| {
    //     if (opt_entry) |entry|
    //         log.debug("Entry: header: {} name: {s}", .{ entry.header, entry.getName() })
    //     else
    //         break;
    // } else |err| {
    //     log.err("Error: {}", .{err});
    // }
    //
    // //_ = ext_fs.findInodeByPath("/dir01/", null) catch |err| {
    // //_ = ext_fs.findInodeByPath("test-file2.txt", 16385) catch |err| { //16385 is the inode number of the dir01 directory
    // _ = ext_fs.findInodeByPath("/file01.txt", null) catch |err| {
    //     //_ = ext_fs.findInodeByPath("/", null) catch |err| {
    //     //? _ = ext_fs.findInodeByPath("/no-file-there", null) catch |err| {
    //     log.err("findInodeByPath error: {any}", .{err});
    // };

    return ext_fs.filesystem();
}

pub fn driver(self: *Ext2Driver) FilesystemDriver {
    return FilesystemDriver.init(self);
}
