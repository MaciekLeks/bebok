const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const Bus = @import("deps.zig").Bus;
const Registry = @import("Registry.zig");

const log = std.log.scoped(.file_system_driver);

const Filesystem = @This();
const Descriptor = i32;

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    open: *const fn (ctx: *anyopaque, partition: *Partition) anyerror!Descriptor,
};

pub fn init(ctx: *anyopaque, vtable: VTable) Filesystem {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub fn open(self: *const Filesystem, allocator: std.mem.Allocator, partition: *Partition) anyerror!Descriptor {
    return @call(.auto, self.vtable.open, .{ self.ptr, allocator, partition });
}

pub fn deinit(self: Filesystem) void {
    return @call(.auto, self.vtable.deinit, .{self.ptr});
}
