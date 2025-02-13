const std = @import("std");

const Pcie = @import("Pcie.zig");
const usb = @import("usb.zig");
const log = std.log.scoped(.bus);

const Device = @import("devices").Device; //re-export for the all in the directory
const Driver = @import("drivers").Driver; //re-export for the all in the directory
const Registry = @import("drivers").Registry; //re-export for the all in the directory

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

pub const Bus = struct {
    const Self = @This();

    pub const DeviceNode = struct {
        alloctr: std.mem.Allocator,
        device: *Device,
        parent: ?*DeviceNode,
        children: std.ArrayList(*DeviceNode),

        pub fn init(allocator: std.mem.Allocator, device: *Device) !DeviceNode {
            return .{
                .alloctr = allocator,
                .device = device,
                .parent = null,
                .children = std.ArrayList(*DeviceNode).init(allocator),
            };
        }

        pub fn deinit(self: *DeviceNode) void {
            defer self.allocr.destroy(self);
            self.device.deinit();
            self.children.deinit();
        }
    };

    var alloctr: std.mem.Allocator = undefined;
    impl: union(BusType) {
        pcie: *Pcie,
        usb: *usb.Usb,
    },
    devices: std.ArrayList(DeviceNode),
    registry: *const Registry,

    pub fn init(allocator: std.mem.Allocator, tag: BusType, registry: *const Registry) !*Self {
        alloctr = allocator;

        var bus = try alloctr.create(Self);
        bus.impl = switch (tag) {
            .pcie => .{ .pcie = try Pcie.init(allocator, bus) },
            else => unreachable,
        };
        bus.devices = std.ArrayList(DeviceNode).init(allocator);
        bus.registry = registry;

        return bus;
    }

    pub fn deinit(self: *Self) void {
        defer alloctr.destroy(self);
        defer self.devices.deinit();

        for (self.devices.items) |dev| {
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

    /// Add devices sequentially while maintaining logical tree structure
    pub fn addDevice(self: *Bus, device: *Device, parent: ?*DeviceNode) !*DeviceNode {
        var node = try DeviceNode.init(alloctr, device);

        // Logical tree structure
        if (parent) |p| {
            try p.children.append(&node);
            node.parent = p;
        }

        // Add sequentially
        try self.devices.append(node);
        return &self.devices.items[self.devices.items.len - 1];
    }
};
