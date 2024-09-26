const std = @import("std");
const log = std.log.scoped(.driver);
const BlockDevice = @import("block/block.zig").BlockDevice;

pub const BusDeviceAddress = @import("../bus/bus.zig").BusDeviceAddress;
//const Driver = @import("../drivers/driver.zig").Driver;

pub const Device = @This();

//variables
var allctr: std.mem.Allocator = undefined;

//Fields
addr: BusDeviceAddress,
spec: union(enum) {
    block_device: BlockDevice,
},
// driver: union(enum) {
//     nvme: Driver,
// },

pub fn init(allocator: std.mem.Allocator, addr: BusDeviceAddress) !*Device {
    allctr = allocator;

    var dev = try allctr.create(Device);
    dev.addr = addr;

    return dev;
}

pub fn deinit(self: *Device) void {
    defer allctr.destroy(self);
}
