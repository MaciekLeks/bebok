const std = @import("std");

const iface = @import("lang").iface;
const Device = @import("devices").Device;
const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Bus = @import("bus").Bus;

const PathParser = @import("PathParser.zig");
const Registry = @import("Registry.zig");
const Node = @import("Node.zig");
const NodeNum = @import("types.zig").NodeNum;
const Vfs = @import("Vfs.zig");
const FD = @import("fd.zig").FD;
const File = @import("File.zig");

const log = std.log.scoped(.vfs_filesystem);

const Filesystem = @This();

pub const Type = enum {
    ext2,
    unknown,
};

//Fields
ptr: *anyopaque,
vtable: *const VTable,
partition: *const Partition,

pub const VTable = struct {
    destroy: iface.Fn(.{}, void),
    //open: iface.Fn(.{ std.mem.Allocator, []const u8, File.Flags, File.Mode }, anyerror!FD),
    //superblock: iface.Fn(.{}, Superblock),
    lookupNodeNum: iface.Fn(.{ []const u8, ?NodeNum }, anyerror!NodeNum), //TODO: do we need it in the impl
    readNode: iface.Fn(.{ std.mem.Allocator, NodeNum }, anyerror!Node),
    getPageSize: iface.Fn(.{}, usize),
};

pub fn init(ctx: anytype, partition: *const Partition) Filesystem {
    return .{ .ptr = ctx, .vtable = iface.gen(@TypeOf(ctx), VTable), .partition = partition };
}

pub fn deinit(_: *const Filesystem) void {
    //do nothing right now
}

pub fn open(self: Filesystem, allocator: std.mem.Allocator, file_path: []const u8, flags: File.Flags, mode: File.Mode) anyerror!*File {
    // Parse path
    var parser = PathParser.init(allocator);
    defer parser.deinit();
    try parser.parse(file_path);

    // Find node number for the file
    const node_num = try self.vtable.lookupNodeNum(self.ptr, .{ file_path, null });

    // Read node
    const node = try self.vtable.readNode(self.ptr, .{ allocator, node_num });
    errdefer node.deinit();

    // Create a file
    return try File.new(allocator, self, node, flags, mode);
}

pub fn getPageSize(self: *const Filesystem) usize {
    return self.vtable.getPageSize(self.ptr, .{});
}

pub fn scanBlockDevices(allocator: std.mem.Allocator, bus: *const Bus, registry: *const Registry, vfs: *Vfs) !void {
    for (bus.devices.items) |*dev_node| {
        //log.warn("Device: {}", .{dev_node}); //TODO:  prontformat method needed to avoid tripple fault

        if (dev_node.device.kind == Device.Kind.block) {
            const block_dev = BlockDevice.fromDevice(dev_node.device);
            if (block_dev.kind == .logical) {
                const partition = Partition.fromBlockDevice(block_dev);
                for (registry.fs_drivers.items) |fs| {
                    const fs_instance = fs.resolve(allocator, partition) catch |err| blk: {
                        log.err("Filesystem resolve error: {}", .{err});
                        break :blk null;
                    };
                    if (fs_instance) |instance| {
                        log.info("Filesystem found and initialized: {}", .{instance});
                        // Initialize filesystem
                        const mount_path = if (vfs.root_fs == null)
                            "/"
                        else //TODO: only to further investigation
                            try std.fmt.allocPrint(allocator, "/dev/{s}/", .{partition.name});

                        try vfs.mount(mount_path, instance);
                        break;
                    }
                }
            }
        }
    }
}
