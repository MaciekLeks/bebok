const std = @import("std");

const Pcie = @import("Pcie.zig");
const usb = @import("usb.zig");
const log = std.log.scoped(.bus);

const Device = @import("deps.zig").Device; //re-export for the all in the directory
const Driver = @import("deps.zig").Driver; //re-export for the all in the directory
const Registry = @import("deps.zig").Registry; //re-export for the all in the directory

pub const BusType = enum {
    pcie,
    usb,
};

pub const BusDeviceAddress = union(BusType) {
    pcie: Pcie.PcieAddress,
    usb: struct { //TODO not implemented
        port: u8,
        speed: u8,
    },
};

const DeviceList = std.ArrayList(*Device);

pub const Bus = struct {
    const Self = @This();

    var alloctr: std.mem.Allocator = undefined;
    impl: union(BusType) {
        pcie: *Pcie,
        usb: *usb.Usb,
    },
    devices: DeviceList,
    registry: *const Registry,

    pub fn init(allocator: std.mem.Allocator, tag: BusType, registry: *const Registry) !*Self {
        alloctr = allocator;

        var bus = try alloctr.create(Self);
        bus.impl = switch (tag) {
            .pcie => .{ .pcie = try Pcie.init(allocator, bus) },
            else => unreachable,
        };
        bus.devices = DeviceList.init(allocator);
        bus.registry = registry;

        return bus;
    }

    // pub fn destroy(self: *Self) void {
    //     defer allctr.destroy(self);
    //     self.devices.deinit();
    //     switch (self.impl) {
    //         inline else => |it| it.destroy(),
    //     }
    // }

    // pub fn init(self: *Self) void {
    //     switch (self.impl) {
    //         inline else => |it| it.init(),
    //     }
    // }

    pub fn deinit(self: *Self) void {
        defer alloctr.destroy(self);
        defer self.devices.deinit();

        for (self.devices) |dev| {
            dev.deinit();
        }

        switch (self.impl) {
            inline else => |it| it.deinit(),
        }
    }

    pub fn scan(self: *Self) !void {
        switch (self.impl) {
            inline else => |it| try it.scan(),
        }
    }

    /// List devices on the bus
    pub fn listDevices(self: *Self) !DeviceList {
        return self.devices;
    }
};
