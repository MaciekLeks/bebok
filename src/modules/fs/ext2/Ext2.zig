const std = @import("std");

const log = std.log.scoped(.ext2);

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const FileSystem = @import("deps.zig").FileSystem;

const Ext2 = @This();

pub fn resolve(_: *anyopaque, partition: Partition, streamer: BlockDevice.Streamer) !void {
    _ = partition;
    _ = streamer;

    log.info("resolving ext2 filesystem", .{});

    return;
}

pub fn filesystem(self: *Ext2) FileSystem {
    const vtable = FileSystem.VTable{
        .resolve = resolve,
    };
    return FileSystem.init(self, vtable);
}
