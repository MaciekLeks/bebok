const std = @import("std");

const pcie = @import("pci/PcieBus.zig");
const heap = @import("../../mem/heap.zig").heap;
const Device = @import("../devices/devices.zig").Device;

const log = std.log.scoped(.bus);

pub const BusType = enum {
    pcie,
    usb,
};

pub const BusDeviceAddress = union(BusType) {
    pcie: pcie.PcieAddress,
    usb: struct { //TODO not implemented
        port: u8,
        speed: u8,
    },
};

const DeviceList = std.ArrayList(*Device);

pub const Bus = struct {
    const Self = @This();

    bus: union(BusType) {
        pcie: pcie.Pcie,
    },
    devices: DeviceList,

    pub fn init(self: Self, allocator: std.mem.Allocator) void {
        switch (self.bus) {
            inline else => |it| it.init(allocator),
        }
    }

    pub fn deinit(self: Self) void {
        switch (self.bus) {
            inline else => |it| it.deinit(),
        }
    }

    pub fn scan(self: *Self) !void {
        switch (self.bus) {
            inline else => |it| try it.scan(self),
        }
    }
};
