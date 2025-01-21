const std = @import("std");

const Device = @import("deps.zig").Device;
const Bus = @import("deps.zig").Bus;
const BusDeviceAddress = @import("deps.zig").BusDeviceAddress;

const Driver = @This();

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    probe: *const fn (ctx: *anyopaque, probe_ctx: *const anyopaque) bool,
    setup: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, bus: *Bus, address: BusDeviceAddress) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,
};

pub fn init(ctx: *anyopaque, vtable: VTable) Driver {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub fn probe(self: Driver, probe_ctx: *const anyopaque) bool {
    return @call(.auto, self.vtable.probe, .{ self.ptr, probe_ctx });
}

pub fn setup(self: Driver, allocator: std.mem.Allocator, bus: *Bus, address: BusDeviceAddress) anyerror!void {
    return @call(.auto, self.vtable.setup, .{ self.ptr, allocator, bus, address });
}

pub fn deinit(self: Driver) void {
    return @call(.auto, self.vtable.deinit, .{self.ptr});
}
