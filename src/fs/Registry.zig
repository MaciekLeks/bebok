const std = @import("std");

const FilesystemDriver = @import("FilesystemDriver.zig");

const Registry = @This();

var alloctr: std.mem.Allocator = undefined;

fs_drivers: std.ArrayList(FilesystemDriver),

pub fn init(allocator: std.mem.Allocator) !*Registry {
    alloctr = allocator;

    var reg = try alloctr.create(Registry);

    reg.fs_drivers = std.ArrayList(FilesystemDriver).init(allocator);

    return reg;
}

pub fn deinit(self: *Registry) void {
    defer self.fs_drivers.deinit();
    for (self.fs_drivers.items) |fs| {
        fs.deinit();
    }
}

pub fn registerFileSystemDriver(self: *Registry, fs: FilesystemDriver) !void {
    try self.fs_drivers.append(fs);
}

// pub fn findDriverForDevice(self: *Registry, device: *Device) ?FileSystem {
//     for (self.drivers.items) |driver| {
//         if (driver.probe(device)) {
//             return driver;
//         }
//     }
//     return null;
// }
