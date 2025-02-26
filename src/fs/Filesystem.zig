const std = @import("std");

const iface = @import("lang").iface;
const Device = @import("devices").Device;
const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Bus = @import("bus").Bus;
const Registry = @import("Registry.zig");
const Superblock = @import("types.zig").Superblock;
const Inode = @import("types.zig").Inode;
const Vfs = @import("Vfs.zig");
const FileDescriptor = @import("types.zig").FileDescriptor;

const log = std.log.scoped(.vfs_filesystem);

const Filesystem = @This();
pub const Descriptor = i32;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    destroy: iface.Fn(.{}, void),
    open: iface.Fn(.{ std.mem.Allocator, [:0]const u8, FileDescriptor.Mode }, anyerror!FileDescriptor),
    superblock: iface.Fn(.{}, Superblock),
};

pub fn init(ctx: anytype) Filesystem {
    return .{
        .ptr = ctx,
        .vtable = iface.gen(@TypeOf(ctx), VTable),
    };
}

// TODO: do not remove code below to see the power of the iface functions
// pub const VTable = struct {
//     destroy: *const fn (ctx: *anyopaque) void,
//     open: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, file_path: [:0]const u8, mode: FileDescriptor.Mode) anyerror!FileDescriptor,
//     superblock: *const fn (ctx: *anyopaque) Superblock,
// };
/// VTable container
// fn VTableContainer(comptime T: type) type {
//     return struct {
//         const Self = @This();
//
//         // we need vtable address
//         pub const vtable = VTable{
//             .destroy = struct {
//                 fn destroyInt(ctx: *anyopaque) void {
//                     const self: T = @ptrCast(@alignCast(ctx));
//                     return self.destroy();
//                 }
//             }.destroyInt,
//             .open = struct {
//                 fn openInt(ctx: *anyopaque, allocator: std.mem.Allocator, file_path: [:0]const u8, mode: FileDescriptor.Mode) anyerror!FileDescriptor {
//                     const self: T = @ptrCast(@alignCast(ctx));
//                     return self.open(allocator, file_path, mode);
//                 }
//             }.openInt,
//             .superblock = struct {
//                 fn superblockInt(ctx: *anyopaque) Superblock {
//                     const self: T = @ptrCast(@alignCast(ctx));
//                     return self.superblock();
//                 }
//             }.superblockInt,
//         };
//     };
// }

// strong static typing for the interface
// fn createVTable(comptime T: type) VTable {
//     return .{
//         .destroy = struct {
//             fn destroyInt(ctx: *anyopaque) void {
//                 const self: T = @ptrCast(@alignCast(ctx));
//                 return self.destroy();
//             }
//         }.destroyInt,
//     };
// }
// pub fn init(ctx: anytype) Filesystem {
//     const T = @TypeOf(ctx);
//     comptime if (@typeInfo(T) != .pointer) @compileError("Filesystem must be a struct");
//     const VT = VTableContainer(@TypeOf(ctx));
//
//     return .{
//         .ptr = ctx,
//         .vtable = &VT.vtable,
//     };
// }

pub fn open(self: *const Filesystem, allocator: std.mem.Allocator, file_path: [:0]const u8, mode: FileDescriptor.Mode) anyerror!FileDescriptor {
    return self.vtable.open(self.ptr, .{ allocator, file_path, mode });
}

pub fn deinit(self: Filesystem) void {
    return self.vtable.destroy(self.ptr, .{});
}

pub fn scanBlockDevices(allocator: std.mem.Allocator, bus: *const Bus, registry: *const Registry, vfs: *Vfs) !void {
    for (bus.devices.items) |*dev_node| {
        //log.warn("Device: {}", .{dev_node}); //TODO:  prontformat method needed to avoid tripple fault

        if (dev_node.device.kind == Device.Kind.block) {
            const block_dev = BlockDevice.fromDevice(dev_node.device);
            if (block_dev.kind == .logical) {
                const partition = Partition.fromBlockDevice(block_dev);
                for (registry.fs_drivers.items) |fs| {
                    const fs_instance = fs.resolve(allocator, partition) catch |err| blk: {
                        log.err("Filesystem resolve error: {}", .{err});
                        break :blk null;
                    };
                    if (fs_instance) |instance| {
                        log.info("Filesystem found and initialized: {}", .{instance});
                        // Initialize filesystem
                        const mount_path = if (vfs.root_fs == null)
                            "/"
                        else //TODO: only to further investigation
                            try std.fmt.allocPrint(allocator, "/dev/{s}/", .{partition.name});

                        try vfs.mount(mount_path, instance);
                        break;
                    }
                }
            }
        }
    }
}
