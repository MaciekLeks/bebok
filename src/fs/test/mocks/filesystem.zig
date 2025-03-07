const std = @import("std");

const mdev = @import("devices");

const Filesystem = @import("../../Filesystem.zig");
const Node = @import("../../Node.zig");
const NodeNum = @import("../../types.zig").NodeNum;

pub fn createMockFilesystem(allocator: std.mem.Allocator, pg_size: comptime_int) !Filesystem {
    const MockFilesystemImpl = struct {
        const Self = @This();

        //Fields
        alloctr: std.mem.Allocator,

        pub fn new(a: std.mem.Allocator) !*Self {
            const self = try a.create(Self);
            self.* = .{
                .alloctr = a,
            };
            return self;
        }

        pub fn destroy(self: *const Self) void {
            self.alloctr.destroy(self);
            std.debug.print("MockFilesystem destroy\n", .{});
        }

        pub fn lookupNodeNum(_: *const Self, _: []const u8, _: ?NodeNum) anyerror!NodeNum {
            return error.NotImplemented;
        }

        pub fn readNode(_: *const Self, _: std.mem.Allocator, _: NodeNum) anyerror!Node {
            return error.NotImplemented;
        }

        pub fn getPageSize(_: *const Self) usize {
            return pg_size;
        }
    };

    const mockFilesystemImpl = try MockFilesystemImpl.new(allocator);
    return Filesystem.init(mockFilesystemImpl, try mdev.createMockPartition(allocator));
}
