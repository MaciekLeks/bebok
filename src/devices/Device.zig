const std = @import("std");
const log = std.log.scoped(.driver);
const BlockDevice = @import("BlockDevice.zig");

const BusDeviceAddress = @import("deps.zig").BusDeviceAddress;
const Bus = @import("deps.zig").Bus;
const Driver = @import("deps.zig").Driver;

const Device = @This();

//Fields
alloctr: std.mem.Allocator,
addr: BusDeviceAddress,
spec: union(enum) { //set by the driver
    block: *BlockDevice,
},
driver: Driver, //Driver is an interface only

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
