const std = @import("std");

const Device = @import("devices").Device;
const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Bus = @import("bus").Bus;
const Registry = @import("Registry.zig");
const Superblock = @import("types.zig");
const Vfs = @import("Vfs.zig");

const log = std.log.scoped(.vfs_filesystem);

const Filesystem = @This();
pub const Descriptor = i32;

ptr: *anyopaque,
vtable: VTable,
//sb: *Superblock,

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

pub fn scanBlockDevices(allocator: std.mem.Allocator, bus: *const Bus, registry: *const Registry, vfs: *Vfs) !void {
    for (bus.devices.items) |*dev_node| {
        log.warn("Device: {}", .{dev_node});

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
                            try std.fmt.allocPrint(allocator, "/dev/{s}", .{partition.name});

                        try vfs.mount(mount_path, instance);
                        break;
                    }
                }
            }
        }
    }
}
