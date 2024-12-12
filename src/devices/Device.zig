///! Device interface with @fieldParentPtr
const std = @import("std");
const log = std.log.scoped(.device);

const Device = @This();

kind: Kind,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ctx: *Device) void,
};

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

pub fn deinit(self: *const Device) void {
    return @call(.auto, self.vtable.deinit, .{self.ptr});
}
