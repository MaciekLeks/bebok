const Ext2 = @import("../Ext2.zig");
const types = @import("../types.zig");
const Partition = @import("/deps.zig").Partition;

fn mockExt2(allocator: std.mem.allocator) Ext2 {
    return .{ .allocator = allocator, .partition = &Partition{} };
}
