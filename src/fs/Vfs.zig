const std = @import("std");
const Filesystem = @import("Filesystem.zig");
const File = @import("types.zig").File;
const pathparser = @import("pathparser.zig");
const Partition = @import("devices").Partition;
const FD = @import("types.zig").FD;
const FileDessriptor = @import("types.zig").FileDescriptor;

pub const MountPoint = struct {
    path: []const u8,
    filesystem: Filesystem,
};

pub const Vfs = @This();

alloctr: std.mem.Allocator,
mount_points: std.ArrayList(MountPoint),
root_fs: ?Filesystem,

//var instance: ?*Vfs = null;
//var mutex: std.Thread.Mutex = .{};

// pub fn getInstance() !*Vfs {
//     return if (instance) |i| i else error.NotInitialized;
// }

pub fn init(allocator: std.mem.Allocator) !*Vfs {
    const self = try allocator.create(Vfs);
    self.* = .{
        .alloctr = allocator,
        .mount_points = std.ArrayList(MountPoint).init(allocator),
        .root_fs = null,
    };
    return self;
}

pub fn deinit(self: *Vfs) void {
    for (self.mount_points.items) |mp| {
        self.alloctr.free(mp.path);
        mp.filesystem.deinit();
    }
    self.mount_points.deinit();
    if (self.root_fs) |root_fs| {
        root_fs.deinit();
    }
    self.alloctr.destroy(self);
}

// pub fn addMountedFilesystem(self: *Vfs, partition: *Partition, fs_instance: *Filesystem) !void {
//     // Mount at root if this is the first filesystem
//     const mount_path = if (self.root_fs == null)
//         "/"
//     else
//         try std.fmt.allocPrint(self.alloctr, "/dev/{s}", .{partition.getName()});
//
//     try self.mount(mount_path, fs_instance);
// }

pub fn mount(self: *Vfs, path: []const u8, filesystem: Filesystem) !void {
    const path_copy = try self.alloctr.dupe(u8, path);
    errdefer self.alloctr.free(path_copy);

    // mount root filesystem
    if (path.len == 0 or (path.len == 1 and path[0] == '/')) {
        // Mount as root filesystem
        if (self.root_fs != null) return error.RootAlreadyMounted;
        self.root_fs = filesystem;
    }

    // add mount point (also for the root filesystem)
    try self.mount_points.append(.{
        .path = path_copy,
        .filesystem = filesystem,
    });
}

pub fn findMountPoint(self: *Vfs, path: []const u8) ?*MountPoint {
    // // First check if this is root
    // if (path.len == 0 or (path.len == 1 and path[0] == '/')) {
    //     if (self.root_fs) |_| {
    //         return &self.mount_points.items[0];
    //     }
    //     return null;
    // }

    // Find the longest matching mount point
    var longest_match: ?*MountPoint = null;
    var longest_len: usize = 0;

    for (self.mount_points.items) |*mount_point| {
        if (std.mem.startsWith(u8, path, mount_point.path)) {
            if (mount_point.path.len > longest_len) {
                longest_match = mount_point;
                longest_len = mount_point.path.len;
            }
        }
    }

    return longest_match;
}

pub fn open(self: *Vfs, path: []const u8, mode: FileDessriptor.Mode) !FD {

    // Find mount point
    const mount_point = self.findMountPoint(path) orelse return error.NoMountPoint;

    // Remove mount point prefix from path
    // We remove path.len - 1 to avoid not having "/"
    const fs_path = path[(mount_point.path.len - 1)..];

    // Parse path
    var parser = pathparser.PathParser.init(self.alloctr);
    defer parser.deinit();
    try parser.parse(fs_path);

    // Delegate to filesystem implementation
    return (try mount_point.filesystem.open(self.alloctr, fs_path, mode)).idx;
}
