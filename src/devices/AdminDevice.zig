const std = @import("std");
const NvmeController = @import("deps.zig").NvmeController;
const Device = @import("Device.zig");

const heap = @import("deps.zig").heap; //TODO: tbd

const log = std.log.scoped(.blockl_device);

const AdminDevice = @This();

const AdminDeviceSpec = union(enum) {
    nvme_ctrl: *NvmeController,
};

alloctr: std.mem.Allocator,
base: *Device,
spec: AdminDeviceSpec,

pub fn init(
    allocator: std.mem.Allocator,
    base: *Device,
    admin_device_spec: AdminDeviceSpec,
) !*AdminDevice {
    var self = try allocator.create(AdminDevice);
    self.alloctr = allocator;
    self.base = base;
    self.base.spec.block = self;
    self.spec = admin_device_spec;

    return self;
}

pub fn deinit(self: *AdminDevice) void {
    defer self.alloctr.destroy(self);

    return switch (self.spec) {
        inline else => |it| it.deinit(),
    };
}
