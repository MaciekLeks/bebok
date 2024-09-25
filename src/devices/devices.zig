const std = @import("std");
const BlockDevice = @import("block/block_device.zig").BlockDevice;
const BusDeviceSpec = @import("../io/bus/bus.zig").BusDeviceSpec;

const Driver = @import("../drivers/driver.zig").Driver;
const log = std.log.scoped(.driver);

pub const Device = struct {
    addr: BusDeviceSpec,
    spec: union(enum) {
        block_device: BlockDevice,
    },
    driver: union(enum) {
        nvme: Driver,
    },
};
