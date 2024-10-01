const std = @import("std");
const log = std.log.scoped(.driver);
const BlockDevice = @import("block/block.zig").BlockDevice;

const BusDeviceAddress = @import("mod.zig").BusDeviceAddress;
const Bus = @import("mod.zig").Bus;
const Driver = @import("mod.zig").Driver;

const Device = @This();

//Fields
alloctr: std.mem.Allocator,
addr: BusDeviceAddress,
spec: union(enum) { //set by the driver
    block_device: BlockDevice,
},
driver: Driver,

pub fn init(allocator: std.mem.Allocator, addr: BusDeviceAddress) !*Device {
    var dev = try allocator.create(Device);
    dev.alloctr = allocator;
    dev.addr = addr;

    return dev;
}

pub fn deinit(self: *Device) void {
    defer self.alloctr.destroy(self);
    switch (self.spec) {
        inline else => |it| it.deinit(),
    }
}
