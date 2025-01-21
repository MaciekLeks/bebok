const std = @import("std");

const Device = @import("devices").Device;
const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Bus = @import("bus").Bus;
const Registry = @import("Registry.zig");

const log = std.log.scoped(.file_system_driver);

const Filesystem = @This();
pub const Descriptor = i32;

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

pub fn scanBlockDevices(allocator: std.mem.Allocator, bus: *const Bus, registry: *const Registry) !void {
    for (bus.devices.items) |*dev_node| {
        log.warn("Device: {}", .{dev_node});

        if (dev_node.device.kind == Device.Kind.block) {
            const block_dev = BlockDevice.fromDevice(dev_node.device);
            if (block_dev.kind == .logical) {
                for (registry.fs_drivers.items) |fs| {
                    const found = fs.resolve(allocator, Partition.fromBlockDevice(block_dev)) catch |err| blk: {
                        log.err("Filesystem resolve error: {}", .{err});
                        break :blk false;
                    };
                    if (found) {
                        log.info("Filesystem found: {}", .{fs});
                        break;
                    }
                }
            }
        }
    }
}
