const std = @import("std");
const testing = std.testing;

const mdev = @import("devices");
const mnode = @import("mocks/node.zig");
const mfs = @import("mocks/filesystem.zig");
const MockPage = @import("mocks/page.zig").MockPage;

const File = @import("../File.zig");

const page_size = 16;
const pages = [page_size]MockPage{
    .{ .b01 = 0, .b02 = 1 },
    .{ .b01 = 2, .b02 = 3 },
    .{ .b01 = 4, .b02 = 5 },
    .{ .b01 = 6, .b02 = 7 },
    .{ .b01 = 8, .b02 = 9 },
    .{ .b01 = 10, .b02 = 11 },
    .{ .b01 = 12, .b02 = 13 },
    .{ .b01 = 14, .b02 = 15 },
    .{ .b01 = 16, .b02 = 17 },
    .{ .b01 = 18, .b02 = 19 },
    .{ .b01 = 20, .b02 = 21 },
    .{ .b01 = 22, .b02 = 23 },
    .{ .b01 = 24, .b02 = 25 },
    .{ .b01 = 26, .b02 = 27 },
    .{ .b01 = 28, .b02 = 29 },
    .{ .b01 = 30, .b02 = 31 },
};

test "File: read from beginning with varying buffer sizes" {
    const allocator = std.testing.allocator;

    // Create a mock node with the pages slice
    const mocknode = try mnode.createMockNode(allocator, &pages);
    defer mocknode.deinit();

    // Create a mock partition
    const mpartition = try mdev.createMockPartition(allocator);
    defer mpartition.destroy();

    // Create a mock filesystem
    const mockfs = try mfs.createMockFilesystem(allocator, @sizeOf(MockPage), mpartition);
    defer mockfs.deinit();

    // Create a new file object
    var file = try File.new(std.testing.allocator, mockfs, mocknode, .{ .read = true }, .{});

    // Convert the pages slice to a byte slice
    const pages_as_bytes = std.mem.sliceAsBytes(&pages);

    var pos: usize = 0;

    // Read 0 bytes
    var buf_zero_bytes: [0]u8 = undefined;
    const read_zero_bytes_count = try file.read(&buf_zero_bytes);
    try testing.expectEqual(read_zero_bytes_count, 0);

    // Read 1 byte
    var buf_one_byte: [1]u8 = undefined;
    pos = try file.lseek(0, .set); // Reset the file position
    try testing.expectEqual(pos, 0);
    const read_one_byte_count = try file.read(&buf_one_byte);
    try testing.expectEqual(read_one_byte_count, 1);
    try testing.expectEqualSlices(u8, pages_as_bytes[0..1], buf_one_byte[0..]);

    // Read 3 bytes
    var buf_three_bytes: [3]u8 = undefined;
    pos = try file.lseek(0, .set); // Reset the file position
    try testing.expectEqual(pos, 0);
    const read_three_bytes_count = try file.read(&buf_three_bytes);
    try testing.expectEqual(read_three_bytes_count, 3);
    try testing.expectEqualSlices(u8, pages_as_bytes[0..3], buf_three_bytes[0..]);

    // Read 8 bytes
    var buf_eight_bytes: [8]u8 = undefined;
    pos = try file.lseek(0, .set); // Reset the file position
    try testing.expectEqual(pos, 0);
    const read_eight_bytes_count = try file.read(&buf_eight_bytes);
    try testing.expectEqual(read_eight_bytes_count, 8);
    try testing.expectEqualSlices(u8, pages_as_bytes[0..8], buf_eight_bytes[0..]);

    // Read 16 bytes
    var buf_sixteen_bytes: [16]u8 = undefined;
    pos = try file.lseek(0, .set); // Reset the file position
    try testing.expectEqual(pos, 0);
    const read_sixteen_bytes_count = try file.read(&buf_sixteen_bytes);
    try testing.expectEqual(read_sixteen_bytes_count, 16);
    try testing.expectEqualSlices(u8, pages_as_bytes[0..16], buf_sixteen_bytes[0..]);

    // Read 40 bytes
    var buf_twenty_bytes: [40]u8 = .{0} ** 40;
    pos = try file.lseek(0, .set); // Reset the file position
    try testing.expectEqual(pos, 0);
    const read_twenty_bytes_count = try file.read(&buf_twenty_bytes);
    try testing.expectEqual(read_twenty_bytes_count, 32);
    try testing.expectEqualSlices(u8, pages_as_bytes[0..32], buf_twenty_bytes[0..32]);
    try testing.expectEqual(0, buf_twenty_bytes[32]); //16th byte can't be overwritten

    try file.destroy();
}

test "File: Seek and read" {
    const allocator = std.testing.allocator;

    // Create a mock node with the pages slice
    const mocknode = try mnode.createMockNode(allocator, &pages);
    defer mocknode.deinit();

    // Create a mock partition
    const mpartition = try mdev.createMockPartition(allocator);
    defer mpartition.destroy();

    // Create a mock filesystem
    const mockfs = try mfs.createMockFilesystem(allocator, @sizeOf(MockPage), mpartition);
    defer mockfs.deinit();

    // Create a new file object
    var file = try File.new(std.testing.allocator, mockfs, mocknode, .{ .read = true }, .{});

    // Convert the pages slice to a byte slice
    const pages_as_bytes = std.mem.sliceAsBytes(&pages);

    // Test seeking from the beginning
    var buf: [1]u8 = undefined;
    var pos = try file.lseek(5, .set); // Jump to position 5
    try testing.expectEqual(pos, 5);
    const read_count = try file.read(&buf);
    try testing.expectEqual(read_count, 1);
    try testing.expectEqualSlices(u8, pages_as_bytes[5..6], buf[0..]);
    try testing.expectEqual(6, file.bytes_read); //we read one byte

    // Test seeking from the current position
    pos = try file.lseek(3, .cur); // Jump 3 positions forward
    try testing.expectEqual(pos, 9);
    const read_count_2 = try file.read(&buf);
    try testing.expectEqual(read_count_2, 1);
    try testing.expectEqualSlices(u8, pages_as_bytes[9..10], buf[0..]);

    // Test seeking from the end
    pos = try file.lseek(-2, .end); // Jump to 2 positions before the end
    try testing.expectEqual(pos, pages_as_bytes.len - 2);
    const read_count_3 = try file.read(&buf);
    try testing.expectEqual(read_count_3, 1);
    try testing.expectEqualSlices(u8, pages_as_bytes[pages_as_bytes.len - 2 .. pages_as_bytes.len - 1], buf[0..]);

    try file.destroy();
}
