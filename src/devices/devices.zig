const std = @import("std");

const Driver = @import("../drivers/driver.zig").Driver;
const log = std.log.scoped(.driver);

pub const DeviceType = enum {
    graphics_card,
    network_adapter,
    block_device,
};

pub const Device = struct {
    name: []const u8,
    type: DeviceType,
    driver: ?*Driver,

    pub fn attachDriver(self: *Device, driver: *Driver) void {
        self.driver = driver;
        std.debug.print("Attached {s} to {s}\n", .{ driver.name, self.name });
    }
};
