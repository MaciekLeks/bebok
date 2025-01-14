const Device = @import("../../Device.zig");

fn mockDeviceDeinit(_: *Device) void {
    // noop
}

pub const MockBlockDevice: Device = .{
    .kind = Device.Kind.block,
    .vtable = &.{ .deinit = mockDeviceDeinit },
};
