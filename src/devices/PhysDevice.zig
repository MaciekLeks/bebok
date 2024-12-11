//! PhysDevice interface
const std = @import("std");
const log = std.log.scoped(.device);

const BusDeviceAddress = @import("deps.zig").BusDeviceAddress;

const Device = @This();

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    //probe: *const fn (ctx: *anyopaque, probe_ctx: *const anyopaque) bool,
    //setup: *const fn (ctx: *anyopaque, setup_ctx: *const anyopaque) anyerror![]*Device,
    ///deinit: *const fn (ctx: *anyopaque) void,
    base: Device.VTable,
    address: *const fn (ctx: *anyopaque) BusDeviceAddress,
};

pub fn init(ctx: *anyopaque, vtable: VTable) Device {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

// pub fn probe(self: Driver, probe_ctx: *const anyopaque) bool {
//     return @call(.auto, self.vtable.probe, .{ self.ptr, probe_ctx });
// }
//
// pub fn setup(self: Driver, setup_ctx: *const anyopaque) anyerror![]*Device {
//     return @call(.auto, self.vtable.setup, .{ self.ptr, setup_ctx });
// }

pub fn deinit(self: Device) void {
    return @call(.auto, self.vtable.deinit, .{self.ptr});
}
