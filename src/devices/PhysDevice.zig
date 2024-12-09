const std = @import("std");
const log = std.log.scoped(.driver);
const AdminDevice = @import("AdminDevice.zig");
const BlockDevice = @import("BlockDevice.zig");

const BusDeviceAddress = @import("deps.zig").BusDeviceAddress;
const Bus = @import("deps.zig").Bus;
const Driver = @import("deps.zig").Driver;

const Device = @This();

//Fields
alloctr: std.mem.Allocator,
addr: BusDeviceAddress,
spec: union(enum) { //set by the driver
    admin: *AdminDevice,
},
driver: Driver, //Driver is an interface only
owner: *const Device, //who owns me

pub fn init(allocator: std.mem.Allocator, addr: BusDeviceAddress, owner: *const Device) !*Device {
    var dev = try allocator.create(Device);
    dev.alloctr = allocator;
    dev.addr = addr;
    dev.owner = owner;

    return dev;
}

pub fn deinit(self: *Device) void {
    defer self.alloctr.destroy(self);
    switch (self.spec) {
        inline else => |it| it.deinit(),
    }
}
