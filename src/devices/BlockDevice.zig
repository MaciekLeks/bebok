const std = @import("std");
const NvmeController = @import("deps.zig").NvmeController;
const Device = @import("Device.zig");

const BlockDevice = @This();

alloctr: std.mem.Allocator,
base: *Device,
spec: union(enum) {
    nvme_ctrl: *NvmeController,
},

pub fn init(allocator: std.mem.Allocator, base: *Device) !*BlockDevice {
    var self = try allocator.create(BlockDevice);
    self.alloctr = allocator;
    self.base = base;

    return self;
}

pub fn deinit(self: *BlockDevice) void {
    defer self.alloctr.destroy(self);
    return switch (self) {
        inline else => |it| it.deinit(),
    };
}
