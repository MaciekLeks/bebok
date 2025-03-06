const std = @import("std");
const Filesystem = @import("Filesystem.zig");
const File = @import("File.zig");
const PathParser = @import("PathParser.zig");
const Partition = @import("devices").Partition;
const FD = @import("fd.zig").FD;
const Task = @import("sched").Task;

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

// VFS functions

pub fn open(self: *Vfs, task: *Task, path: []const u8, flags: File.Flags, mode: File.Mode) !FD {
    // Find mount point
    const mount_point = self.findMountPoint(path) orelse return error.NoMountPoint;

    // Remove mount point prefix from path
    // We remove path.len - 1 to avoid not having "/"
    const fs_path = path[(mount_point.path.len - 1)..];

    // Delegate to filesystem implementation
    const file = try mount_point.filesystem.open(self.alloctr, fs_path, flags, mode);

    //Add file to FD table and get file descriptor
    return task.fds.getNewFD(file);
}

pub fn read(_: *Vfs, task: *Task, fd: FD, buf: []u8) !usize {
    const file = try task.fds.getFile(fd);
    return file.read(buf);
}

pub fn close(_: *Vfs, task: *Task, fd: FD) !void {
    const file = try task.fds.getFile(fd);

    file.destroy() catch |err| {
        switch (err) {
            File.Error.StillInUse => {
                return;
            },
            else => {
                return err;
            },
        }
    };
}

pub fn lseek(_: *Vfs, task: *Task, fd: FD, offset: isize, whence: File.SeekWhence) !usize {
    const file = try task.fds.getFile(fd);
    return try file.lseek(offset, whence);
}
