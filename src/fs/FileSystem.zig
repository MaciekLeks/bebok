const std = @import("std");

pub const BlockDevice = @import("deps.zig").BlockDevice;
pub const Partition = @import("deps.zig").Partition;

const FileSystem = @This();

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    resolve: *const fn (ctx: *anyopaque, partition: Partition, streamer: BlockDevice.Streamer) anyerror!void,
};

pub fn init(ctx: *anyopaque, vtable: VTable) FileSystem {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub fn resolve(self: FileSystem, partition: Partition, streamer: BlockDevice.Streamer) anyerror!void {
    return @call(.auto, self.vtable.probe, .{ self.ptr, partition, streamer });
}

// pub fn setup(self: Driver, dev: *Device) anyerror!void {
//     return @call(.auto, self.vtable.setup, .{ self.ptr, dev });
// }
//
// pub fn deinit(self: Driver) void {
//     return @call(.auto, self.vtable.deinit, .{self.ptr});
// }
