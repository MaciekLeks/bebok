const std = @import("std");

const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Bus = @import("bus").Bus;
const Registry = @import("Registry.zig");
const Filesystem = @import("Filesystem.zig");

const log = std.log.scoped(.vfs_filesystem_driver);

const FilesystemDriver = @This();

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    resolve: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem,
};

pub fn init(ctx: *anyopaque, vtable: VTable) FilesystemDriver {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub fn resolve(self: *const FilesystemDriver, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem {
    return @call(.auto, self.vtable.resolve, .{ self.ptr, allocator, partition });
}
