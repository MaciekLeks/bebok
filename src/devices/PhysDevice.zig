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

// helper function to get PhysDevice from Device
pub fn fromDevice(dev: *Device) *PhysDevice {
    return @fieldParentPtr("device", dev);
}
