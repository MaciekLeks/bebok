const std = @import("std");
const log = std.log.scoped(.driver);
const AdminDevice = @import("AdminDevice.zig");
const BlockDevice = @import("BlockDevice.zig");

const BusDeviceAddress = @import("deps.zig").BusDeviceAddress;
const Bus = @import("deps.zig").Bus;
const Driver = @import("deps.zig").Driver;

const LogicDevice = @This();

//Fields
alloctr: std.mem.Allocator,
spec: union(enum) { //set by the driver
    block: *BlockDevice,
},
driver: Driver, //Driver is an interface only
owner: *const Device, //who owns me

pub fn init(allocator: std.mem.Allocator, addr: BusDeviceAddress, owner: *const Device) !*LogicDevice {
    var dev = try allocator.create(LogicDevice);
    dev.alloctr = allocator;
    dev.addr = addr;
    dev.owner = owner;

    return dev;
}

pub fn deinit(self: *LogicDevice) void {
    defer self.alloctr.destroy(self);
    switch (self.spec) {
        inline else => |it| it.deinit(),
    }
}
