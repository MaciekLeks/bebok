const std = @import("std");
const Partition = @import("../../deps.zig").Partition;
const mdev = @import("../../../test/mocks/devices.zig");

pub fn mockPartition(allocator: std.mem.Allocator) Partition {
    return .{
        .alloctr = allocator,
        .block_device = mdev.mockBlockDevice,
        .parent = &mdev.mockBlockDevice,
        .partition_type = Partition.Type.unknown,
        .attributes = Partition.Attributes{ .required_to_function = false, .type_guid_specific = 0 },
        .name = &[_]u8{"test"},
        .name_len = 4,
    };
}
