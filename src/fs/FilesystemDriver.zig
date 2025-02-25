const std = @import("std");
const iface = @import("lang").iface;

const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Bus = @import("bus").Bus;
const Registry = @import("Registry.zig");
const Filesystem = @import("Filesystem.zig");

const log = std.log.scoped(.vfs_filesystem_driver);

const FilesystemDriver = @This();

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    resolve: iface.Fn(.{ std.mem.Allocator, *Partition }, anyerror!?Filesystem),
    destroy: iface.Fn(.{}, void),
};
pub fn init(ctx: anytype) FilesystemDriver {
    return .{
        .ctx = ctx,
        .vtable = iface.gen(@TypeOf(ctx), VTable),
    };
}

pub fn deinit(self: *const FilesystemDriver) void {
    return self.vtable.destroy(self.ctx, .{});
}

pub fn resolve(self: *const FilesystemDriver, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem {
    return self.vtable.resolve(self.ctx, .{ allocator, partition });
}
