const std = @import("std");
const log = std.log.scoped(.driver);
const BlockDevice = @import("block/block.zig").BlockDevice;

pub const BusDeviceAddress = @import("../bus/bus.zig").BusDeviceAddress;
//const Driver = @import("../drivers/driver.zig").Driver;

pub const Device = @This();

//variables
var alloctr: std.mem.Allocator = undefined;

//Fields
addr: BusDeviceAddress,
spec: union(enum) {
    block_device: BlockDevice,
},
// driver: union(enum) {
//     nvme: Driver,
// },

pub fn init(allocator: std.mem.Allocator, addr: BusDeviceAddress) !*Device {
    alloctr = allocator;

    var dev = try alloctr.create(Device);
    dev.addr = addr;

    return dev;
}

pub fn deinit(self: *Device) void {
    defer alloctr.destroy(self);
}
