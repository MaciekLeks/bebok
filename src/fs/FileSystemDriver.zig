const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const Bus = @import("deps.zig").Bus;
const Registry = @import("Registry.zig");

const log = std.log.scoped(.file_system_driver);

const FileSystemDriver = @This();

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    resolve: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, partition: *Partition) anyerror!bool,
};

pub fn init(ctx: *anyopaque, vtable: VTable) FileSystemDriver {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub fn resolve(self: *const FileSystemDriver, allocator: std.mem.Allocator, partition: *Partition) anyerror!bool {
    return @call(.auto, self.vtable.resolve, .{ self.ptr, allocator, partition });
}
