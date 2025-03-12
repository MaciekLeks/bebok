const std = @import("std");

const FilesystemDriver = @import("FilesystemDriver.zig");
const Partition = @import("devices").Partition;

const log = std.log.scoped(.vfs_registry);

const Registry = @This();

var alloctr: std.mem.Allocator = undefined;

fs_drivers: std.ArrayList(FilesystemDriver),

pub fn new(allocator: std.mem.Allocator) !*Registry {
    alloctr = allocator;

    var reg = try alloctr.create(Registry);

    reg.fs_drivers = std.ArrayList(FilesystemDriver).init(allocator);

    return reg;
}

pub fn destroy(self: *Registry) void {
    defer self.fs_drivers.deinit();
    for (self.fs_drivers.items) |driver| {
        driver.deinit();
    }
}

pub fn registerFileSystemDriver(self: *Registry, fs: FilesystemDriver) !void {
    try self.fs_drivers.append(fs);
}
