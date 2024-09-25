const std = @import("std");
const log = std.log.scoped(.driver);
const BlockDevice = @import("block/block_device.zig").BlockDevice;

pub const BusDeviceAddress = @import("../bus/bus.zig").BusDeviceAddress;
const Driver = @import("../drivers/driver.zig").Driver;

pub const Device = @This();

addr: BusDeviceAddress,
spec: union(enum) {
    block_device: BlockDevice,
},
driver: union(enum) {
    nvme: Driver,
},


