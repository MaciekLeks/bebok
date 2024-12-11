///! Device interface
const std = @import("std");
const log = std.log.scoped(.device);

const Device = @This();

ptr: *anyopaque,
vtable: VTable,

pub const VTable = struct {
    //probe: *const fn (ctx: *anyopaque, probe_ctx: *const anyopaque) bool,
    //setup: *const fn (ctx: *anyopaque, setup_ctx: *const anyopaque) anyerror![]*Device,
    deinit: *const fn (ctx: *anyopaque) void,
    kind: *const fn (ctx: *anyopaque) Kind,
};

pub fn init(ctx: *anyopaque, vtable: VTable) Device {
    return .{
        .ptr = ctx,
        .vtable = vtable,
    };
}

pub const Kind = enum {
    block,
    admin,
    char,
};

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

pub fn kind(self: Device) Kind {
    return @call(.auto, self.vtable.kind, .{self.ptr});
}

pub fn impl(self: Device, comptime TImpl: type) *TImpl {
    return @ptrCast(@alignCast(self.ptr));
}
