const Device = @import("../../deps.zig").Device;
const BlockDevice = @import("../../deps.zig").BlockDevice;

fn mockDeviceDeinit(_: *Device) void {
    // noop
}

fn mockStreamer(_: *BlockDevice) BlockDevice.Streamer {
    return BlockDevice.Streamer{
        .read = null,
        .write = null,
    };
}

pub const mockDevice: Device = .{
    .kind = Device.Kind.block,
    .vtable = &.{ .deinit = mockDeviceDeinit },
};

pub const mockBlockDevice: BlockDevice = .{
    .device = &mockDevice,
    .state = .{
        .partition_scheme = null,
        .slba = 0,
        .nlba = 0,
        .lbads = 0,
    },
    .vtable = &.{ .streamer = null },
    .kind = BlockDevice.Kind.logical,
};
