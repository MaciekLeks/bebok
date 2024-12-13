///! Abstract Device implemented with @fieldParentPtr
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
    admin, //TODO one can introduce AdminDevice to hold NvmeController as a tagged union, but it's not needed for now
    char,
};

pub fn deinit(self: *const Device) void {
    return @call(.auto, self.vtable.deinit, .{self});
}
