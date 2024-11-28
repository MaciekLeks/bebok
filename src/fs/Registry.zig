const std = @import("std");

const FileSystem = @import("FileSystem.zig");

const Registry = @This();

var alloctr: std.mem.Allocator = undefined;

filesystems: std.ArrayList(FileSystem),

pub fn init(allocator: std.mem.Allocator) !*Registry {
    alloctr = allocator;

    var reg = try alloctr.create(Registry);

    reg.filesystems = std.ArrayList(FileSystem).init(allocator);

    return reg;
}

pub fn deinit(self: *Registry) void {
    defer self.filesystems.deinit();
    for (self.filesystems.items) |fs| {
        fs.deinit();
    }
}

pub fn registerFileSystem(self: *Registry, fs: FileSystem) !void {
    try self.filesystems.append(fs);
}

// pub fn findDriverForDevice(self: *Registry, device: *Device) ?FileSystem {
//     for (self.drivers.items) |driver| {
//         if (driver.probe(device)) {
//             return driver;
//         }
//     }
//     return null;
// }
