const std = @import("std");

const Device = @import("deps.zig").Device;
const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const Bus = @import("deps.zig").Bus;
const Registry = @import("Registry.zig");

const log = std.log.scoped(.file_system);

const FileSystem = @This();

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    resolve: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, partition: *Partition, streamer: BlockDevice.Streamer) anyerror!bool,
};

pub fn init(ctx: *anyopaque, vtable: VTable) FileSystem {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub fn resolve(self: *const FileSystem, allocator: std.mem.Allocator, partition: *Partition, streamer: BlockDevice.Streamer) anyerror!bool {
    return @call(.auto, self.vtable.resolve, .{ self.ptr, allocator, partition, streamer });
}

// pub fn setup(self: Driver, dev: *Device) anyerror!void {
//     return @call(.auto, self.vtable.setup, .{ self.ptr, dev });
// }
//
// pub fn deinit(self: Driver) void {
//     return @call(.auto, self.vtable.deinit, .{self.ptr});
// }

pub fn scanBlockDevices(allocator: std.mem.Allocator, bus: *const Bus, registry: *const Registry) !void {
    for (bus.devices.items) |*dev_node| {
        log.warn("Device: {}", .{dev_node});

        if (dev_node.device.kind == Device.Kind.block) {
            const block_dev = BlockDevice.fromDevice(dev_node.device);
            if (block_dev.kind == .logical) {
                for (registry.filesystems.items) |fs| {
                    const found = fs.resolve(allocator, Partition.fromBlockDevice(block_dev), block_dev.streamer()) catch |err| blk: {
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
