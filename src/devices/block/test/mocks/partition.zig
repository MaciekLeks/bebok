const std = @import("std");
const Partition = @import("../../Partition.zig");
//var mockBlockDevice = @import("../../../test/mocks/devices.zig").mockBlockDevice;
const mdev = @import("../../../test/mocks/devices.zig");

pub fn createMockPartition(allocator: std.mem.Allocator) !*Partition {
    const pname = allocator.dupe(u8, &[_]u8{ 't', 'e', 's', 't' }) catch unreachable;
    const mock = try allocator.create(Partition);
    mock.* = .{ .alloctr = allocator, .block_device = mdev.mockBlockDevice, .parent = &mdev.mockBlockDevice, .partition_type = Partition.Type.unknown, .attributes = Partition.Attributes{ .required_to_function = false, .type_guid_specific = 0 }, .name = pname, .filesystem = null };
    return mock;
}
