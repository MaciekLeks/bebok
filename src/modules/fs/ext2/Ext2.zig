const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const FileSystem = @import("deps.zig").FileSystem;
const Superblock = @import("types.zig").Superblock;
const BlockGroupDescriptor = @import("types.zig").BlockGroupDescriptor;

const log = std.log.scoped(.ext2);

const Ext2 = @This();

pub fn resolve(_: *anyopaque, allocator: std.mem.Allocator, partition: *Partition, streamer: BlockDevice.Streamer) !bool {
    _ = partition;
    var offset: usize = 0;

    log.info("Resolving ext2 filesystem", .{});
    var stream = BlockDevice.Stream(u8).init(streamer);
    // Go to superblock position, always 1024 in the ext2 partition
    offset = offset + 0x400;
    stream.seek(offset, .start);

    var superblock = try allocator.create(Superblock);
    defer allocator.destroy(superblock); //TODO: until we now what to do with it
    try stream.readAll(std.mem.asBytes(superblock));

    if (!superblock.isMagicValid()) {
        log.debug("Invalid magic number: {x}", .{superblock.magic});
        return false;
    }

    if (!superblock.isMajorValid()) {
        log.warn("Unsupported major revision level: {}", .{superblock.major_rev_level});
        return false;
    }

    log.info("Ext2 filesystem detected", .{});

    const bgdt = try allocator.alloc(BlockGroupDescriptor, superblock.getBlockGroupsCount());
    defer allocator.free(bgdt);
    
    var stream_bgdt = BlockDevice.Stream(BlockGroupDescriptor).init(streamer);
    offset = offset + 0x400;
    stream_bgdt.seek(offset, .start);

    try stream_bgdt.readAll(bgdt);
    for (bgdt,0..) |*bgd,i| {
        log.debug("Block Group Descriptor[{d}]:{}", .{i, bgd});
    }


    log.debug("Superblock: {}", .{superblock});

    return true;
}

pub fn filesystem(self: *Ext2) FileSystem {
    const vtable = FileSystem.VTable{
        .resolve = resolve,
    };
    return FileSystem.init(self, vtable);
}
