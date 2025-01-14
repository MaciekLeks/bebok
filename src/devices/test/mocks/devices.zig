const Device = @import("../../Device.zig");

pub const MockBlockDevice: Device = .{
    .kind = Device.Kind.block,
    .vtable = &.{
        .deinit: &fn(ctx: *Device) void {
            // noop
        },
    },
};
