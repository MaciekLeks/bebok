const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const Bus = @import("deps.zig").Bus;
const Registry = @import("Registry.zig");

const log = std.log.scoped(.file_system_driver);

const FileSystem = @This();
const FileDescriptor = i32;

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    open: *const fn (ctx: *anyopaque, partition: *Partition) anyerror!FileDescriptor,
};

pub fn init(ctx: *anyopaque, vtable: VTable) FileSystem {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub fn open(self: *const FileSystem, allocator: std.mem.Allocator, partition: *Partition) anyerror!FileDescriptor {
    return @call(.auto, self.vtable.open, .{ self.ptr, allocator, partition });
}
