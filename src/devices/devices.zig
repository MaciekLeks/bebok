const std = @import("std");
const BlockDevice = @import("block_device.zig").BlockDevice;
const BusDeviceSpec = @import("../io/bus/bus.zig").BusDeviceSpec;

const Driver = @import("../drivers/driver.zig").Driver;
const log = std.log.scoped(.driver);

pub const Device = struct {
    spec: BusDeviceSpec,
    dev: union(enum) {
        block_device: BlockDevice,
    },
};
