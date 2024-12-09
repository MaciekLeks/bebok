const std = @import("std");
const log = std.log.scoped(.driver);
const LogicDevice = @import("LogicDevice.zig");
const PhysDevice = @import("PhysDevice.zig");

const Device = @This();

pub const DeviceSpec = union(enum) {
    logic: *LogicDevice,
    phys: *PhysDevice,
};

//Fields
alloctr: std.mem.Allocator,
spec: DeviceSpec,
children: std.ArrayList(*Device),
parent: ?*const Device, //who is above me

pub fn init(allocator: std.mem.Allocator, spec: DeviceSpec, parent: *const Device) !*Device {
    var dev = try allocator.create(Device);
    dev.alloctr = allocator;
    dev.spec = spec;
    dev.children = std.ArrayList(*Device).init(allocator);
    dev.parent = parent;

    return dev;
}

pub fn deinit(self: *Device) void {
    defer self.alloctr.destroy(self);
    for (self.children.items) |child| {
        child.deinit();
    }
    self.children.deinit();
    switch (self.spec) {
        inline else => |it| it.deinit(),
    }
}

pub fn addChild(self: *Device, child: *Device) !void {
    try self.children.append(child);
}
