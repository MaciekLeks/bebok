const std = @import("std");

const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Bus = @import("bus").Bus;
const Registry = @import("Registry.zig");
const Filesystem = @import("Filesystem.zig");

const log = std.log.scoped(.vfs_filesystem_driver);

const FilesystemDriver = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    resolve: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem,
    destroy: *const fn (ctx: *anyopaque) void,
};

// string static typing for the interface
// fn createVTable(comptime T: type) VTable {
//     return .{
//         .resolve = struct {
//             fn resolveInt(ctx: *anyopaque, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem {
//                 const self: T = @ptrCast(@alignCast(ctx));
//                 return self.resolve(allocator, partition);
//             }
//         }.resolveInt,
//         .destroy = struct {
//             fn destroyInt(ctx: *anyopaque) void {
//                 const self: T = @ptrCast(@alignCast(ctx));
//                 return self.destroy();
//             }
//         }.destroyInt,
//     };
// }

/// VTable container
fn VTableContainer(comptime T: type) type {
    return struct {
        const Self = @This();

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
    // const vtable = createVTable(T);
    log.debug("XYZ-00-a", .{});
    const VT = VTableContainer(@TypeOf(ctx));
    log.debug("XYZ-00-b", .{});

    return .{
        .ptr = ctx,
        .vtable = &VT.vtable,
    };
}

pub fn deinit(self: *const FilesystemDriver) void {
    return self.vtable.destroy(self.ptr);
}

pub fn resolve(self: *const FilesystemDriver, allocator: std.mem.Allocator, partition: *Partition) anyerror!?Filesystem {
    return self.vtable.resolve(self.ptr, allocator, partition);
}
