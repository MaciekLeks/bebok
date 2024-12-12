//! PhysDevice interface
const std = @import("std");
const log = std.log.scoped(.device);

const Device = @import("Device.zig");

const BusDeviceAddress = @import("deps.zig").BusDeviceAddress;

const PhysDevice = @This();

device: Device, //base Device interface
address: BusDeviceAddress,
vtable: *const VTable,

pub const VTable = struct {
    //add example function as. someFn(physdev: *PhysDevice ) and then implement fn(*PhysDevice) in the implementator
};

// pub fn probe(self: Driver, probe_ctx: *const anyopaque) bool {
//     return @call(.auto, self.vtable.probe, .{ self.ptr, probe_ctx });
// }
//
// pub fn setup(self: Driver, setup_ctx: *const anyopaque) anyerror![]*Device {
//     return @call(.auto, self.vtable.setup, .{ self.ptr, setup_ctx });
// }

// pub fn deinit(self: Device) void {
//     return @call(.auto, self.vtable.deinit, .{self.ptr});
// }

pub fn fromDevice(dev: *Device) *PhysDevice {
    return @fieldParentPtr("device", dev);
}
