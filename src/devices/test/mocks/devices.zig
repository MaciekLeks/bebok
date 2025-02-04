const std = @import("std");
const Device = @import("../../Device.zig");
const BlockDevice = @import("../../BlockDevice.zig");
const Streamer = BlockDevice.Streamer;

fn mockDeviceDeinit(_: *Device) void {
    // noop
}

fn mockStreamerRead(_: *const anyopaque, _: std.mem.Allocator, _: u64, _: u16) anyerror![]u8 {
    @panic("Not implemented");
}

fn mockStreamerWrite(_: *const anyopaque, _: std.mem.Allocator, _: u64, _: []const u8) anyerror!void {
    @panic("Not implemented");
}

fn mockStreamerCalculate(_: *const anyopaque, _: usize, _: usize) anyerror!Streamer.LbaPos {
    @panic("Not implemented");
}

const streamerVTable = Streamer.VTable{
    .read = &mockStreamerRead,
    .write = &mockStreamerWrite,
    .calculate = &mockStreamerCalculate,
};

fn mockStreamer(_: *BlockDevice) BlockDevice.Streamer {
    return BlockDevice.Streamer{
        .ptr = &struct {},
        .vtable = streamerVTable,
    };
}

const mockBlockDeviceVTable: BlockDevice.VTable = .{
    .streamer = mockStreamer,
};

pub const mockDevice: Device = .{
    .kind = Device.Kind.block,
    .vtable = &.{ .deinit = mockDeviceDeinit },
};

pub var mockBlockDevice: BlockDevice = .{
    .device = mockDevice,
    .state = .{
        .partition_scheme = null,
        .slba = 0,
        .nlba = 0,
        .lbads = 0,
    },
    .vtable = &mockBlockDeviceVTable,
    .kind = BlockDevice.Kind.logical,
};
