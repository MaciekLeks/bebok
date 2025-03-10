const std = @import("std");
const testing = std.testing;

const mdev = @import("devices");
const mnode = @import("mocks/node.zig");
const mfs = @import("mocks/filesystem.zig");
const MockPage = @import("mocks/page.zig").MockPage;

const File = @import("../File.zig");

const pages = [_]MockPage{
    .{ .b01 = 0, .b02 = 0 },
    .{ .b01 = 1, .b02 = 1 },
    .{ .b01 = 2, .b02 = 2 },
    .{ .b01 = 3, .b02 = 3 },
    .{ .b01 = 4, .b02 = 4 },
    .{ .b01 = 5, .b02 = 5 },
    .{ .b01 = 6, .b02 = 6 },
    .{ .b01 = 7, .b02 = 7 },
    .{ .b01 = 8, .b02 = 8 },
    .{ .b01 = 9, .b02 = 9 },
    .{ .b01 = 10, .b02 = 10 },
    .{ .b01 = 11, .b02 = 11 },
    .{ .b01 = 12, .b02 = 12 },
    .{ .b01 = 13, .b02 = 13 },
    .{ .b01 = 14, .b02 = 14 },
    .{ .b01 = 15, .b02 = 15 },
};

test "File read" {
    const allocator = std.testing.allocator;

    const pg_slice: []const MockPage = pages[0..];

    const mocknode = try mnode.createMockNode(allocator, pg_slice);
    mocknode.deinit();

    // we create partition here cause in real life it's created by the kernelthe bus/devices layer and it's managed from there
    const mpartition = try mdev.createMockPartition(allocator);
    defer mpartition.destroy();

    const mockfs = try mfs.createMockFilesystem(allocator, @sizeOf(MockPage), mpartition);
    defer mockfs.deinit();

    var file = try File.new(std.testing.allocator, mockfs, mocknode, .{ .read = true }, .{});
    try file.destroy();
}
