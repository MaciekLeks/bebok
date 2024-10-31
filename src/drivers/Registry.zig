const std = @import("std");

const Driver = @import("Driver.zig");
const Device = @import("mod.zig").Device;

const Registry = @This();

var alloctr: std.mem.Allocator = undefined;

drivers: std.ArrayList(Driver),

pub fn init(allocator: std.mem.Allocator) !*Registry {
    alloctr = allocator;

    var reg = try alloctr.create(Registry);

    reg.drivers = std.ArrayList(Driver).init(allocator);

    return reg;
}

pub fn deinit(self: *Registry) void {
    defer self.drivers.deinit();
    for (self.drivers.items) |driver| {
        driver.deinit();
    }
}

pub fn registerDriver(self: *Registry, driver: Driver) !void {
    try self.drivers.append(driver);
}

// pub fn findDriverForDevice(self: *Registry, device: *Device) ?*Driver {
//     for (self.drivers.items) |driver| {
//         if (driver.probe(device)) {
//             return driver;
//         }
//     }
//     return null;
// }
pub fn findDriverForDevice(self: *Registry, device: *Device) ?Driver {
    for (self.drivers.items) |driver| {
        if (driver.probe(device)) {
            return driver;
        }
    }
    return null;
}
