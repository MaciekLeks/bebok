const std = @import("std");
const NvmeController = @import("deps.zig").NvmeController;
const Device = @import("Device.zig");

const BlockDevice = @This();

alloctr: std.mem.Allocator,
base: *Device,
spec: union(enum) {
    nvme_ctrl: *NvmeController,
},

pub fn init(allocator: std.mem.Allocator, base: *Device) !*BlockDevice {
    var self = try allocator.create(BlockDevice);
    self.alloctr = allocator;
    self.base = base;

    return self;
}

pub fn deinit(self: *BlockDevice) void {
    defer self.alloctr.destroy(self);
    return switch (self) {
        inline else => |it| it.deinit(),
    };
}

pub fn Streamer(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const VTable = struct {
            read: *const fn (comptime T: type, ctx: *anyopaque, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror![]void,
            write: *const fn (comptime T: type, ctx: *anyopaque, offset: usize, buf: []u8) anyerror!void,
        };

        ptr: *anyopaque,
        vtable: VTable,

        pub fn read(self: Self, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror!T {
            return self.vtable.read(T, self.ptr, allocator, offset, total);
        }

        pub fn write(self: Self, offset: usize, buf: []T) anyerror!void {
            return self.vtable.write(T, self.ptr, offset, buf);
        }

        pub fn init(ctx: *anyopaque, vtable: VTable) Self {
            return .{
                .ptr = ctx,
                .vtable = vtable,
            };
        }

        pub fn from(ctx: *anyopaque, TImpl: type) Self {
            const self: *TImpl = @ptrCast(@alignCast(ctx));
            return Streamer(){
                .ptr = self,
                .vtable = &.{ .read = TImpl.read, .write = T.write },
            };
        }
    };
}

pub fn Stream(comptime T: type) type {
    return struct {
        const Self = @This();

        //streamer: Streamer(T),
        streamer: Streamer(T),
        pos: usize,

        pub fn init(streamer: Streamer(T)) Self {
            return .{
                .streamer = streamer,
                .pos = 0,
            };
        }

        pub fn read(self: Self, allocator: std.mem.Allocator, total: usize) anyerror!void {
            return self.streamer.read(T, allocator, self.pos, total);
        }

        pub fn write(self: Self, buf: []u8) anyerror!void {
            return self.streamer.write(self.pos, buf);
        }

        pub fn seek(self: Self, offset: usize) anyerror!void {
            self.pos = offset;
        }
    };
}
