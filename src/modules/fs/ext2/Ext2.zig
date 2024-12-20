const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const FileSystem = @import("deps.zig").FileSystem;
const Superblock = @import("structs.zig").Superblock;

const log = std.log.scoped(.ext2);

const Ext2 = @This();

pub fn resolve(_: *anyopaque, allocator: std.mem.Allocator, partition: *Partition, streamer: BlockDevice.Streamer) !bool {
    _ = partition;

    log.info("Resolving ext2 filesystem", .{});
    var stream = BlockDevice.Stream(u8).init(streamer);
    // Go to superblock position, always 1024 in the ext2 partition
    stream.seek(0x400);

    var superblock = try allocator.create(Superblock);
    defer allocator.destroy(superblock); //TODO until we now what to do with it
    try stream.readAll(std.mem.asBytes(superblock));

    log.info("Superblock magic: {x}", .{superblock.magic});

    if (!superblock.isMagicValid()) {
        return false;
    }

    log.info("Ext2 filesystem detected", .{});

    log.info("Superblock: {}", .{superblock});

    return true;
}

pub fn filesystem(self: *Ext2) FileSystem {
    const vtable = FileSystem.VTable{
        .resolve = resolve,
    };
    return FileSystem.init(self, vtable);
}
