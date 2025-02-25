const std = @import("std");

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
    resolve: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem,
    destroy: *const fn (ctx: *anyopaque) void,
};

/// VTable container
fn VTableContainer(comptime T: type) type {
    return struct {
        const Self = @This();

        // we need vtable address
        pub const vtable = VTable{
            .resolve = struct {
                fn resolveInt(ctx: *anyopaque, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem {
                    const self: T = @ptrCast(@alignCast(ctx));
                    return self.resolve(allocator, partition);
                }
            }.resolveInt,
            .destroy = struct {
                fn destroyInt(ctx: *anyopaque) void {
                    const self: T = @ptrCast(@alignCast(ctx));
                    return self.destroy();
                }
            }.destroyInt,
        };
    };
}

pub fn init(ctx: anytype) FilesystemDriver {
    const T = @TypeOf(ctx);
    comptime if (@typeInfo(T) != .pointer) @compileError("FilesystemDriver.init() requires a pointer to the struct");
    const VT = VTableContainer(@TypeOf(ctx));

    return .{
        .ctx = ctx,
        .vtable = &VT.vtable,
    };
}

pub fn deinit(self: *const FilesystemDriver) void {
    return self.vtable.destroy(self.ctx);
}

pub fn resolve(self: *const FilesystemDriver, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem {
    return self.vtable.resolve(self.ctx, allocator, partition);
}
