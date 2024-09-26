const std = @import("std");

const Pcie = @import("Pcie.zig");
const usb = @import("usb.zig");
const heap = @import("../../mem/heap.zig").heap;
const log = std.log.scoped(.bus);

pub const Device = @import("../devices/Device.zig"); //re-export for the all in the directory

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

    var allctr: std.mem.Allocator = undefined;
    impl: union(BusType) {
        pcie: *Pcie,
        usb: *usb.Usb,
    },
    devices: DeviceList,

    pub fn init(allocator: std.mem.Allocator, tag: BusType) !*Self {
        allctr = allocator;

        var bus = try allctr.create(Self);
        bus.impl = switch (tag) {
            .pcie => .{ .pcie = try Pcie.init(allocator, bus) },
            else => unreachable,
        };
        bus.devices = DeviceList.init(allocator);

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
        defer allctr.destroy(self);
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
};
