const std = @import("std");
pub const ext2 = @import("ext2");
//const builtin = @import("builtin");
//
// pub usingnamespace switch (builtin.cpu.arch) {
//     .x86_64 => @import("arch/x86_64/tests.zig"),
//     else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
// };

// pub const Device = @import("devices/Device.zig");
// pub const PhysDevice = @import("devices/PhysDevice.zig");
// pub const BlockDevice = @import("devices/mod.zig").BlockDevice;
// pub const PartitionScheme = @import("devices/mod.zig").PartitionScheme;
// pub const Partition = @import("devices/mod.zig").Partition;

test "root" {}

test {
    std.testing.refAllDecls(@This());
    _ = @import("ext2");
    std.testing.refAllDecls(ext2);
}
