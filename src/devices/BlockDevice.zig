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

pub const Streamer = struct {
    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror![]u8,
        write: *const fn (ctx: *anyopaque, buf: []u8, offset: usize) anyerror!void,
    };

    ptr: *anyopaque,
    vtable: VTable,

    pub fn read(self: Streamer, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror!void {
        return self.vtable.read(self.ptr, allocator, offset, total);
    }

    pub fn write(self: Streamer, buf: []u8, offset: usize) anyerror!void {
        return self.vtable.write(self.ptr, buf, offset);
    }
};

pub const Stream = struct {
    streamer: Streamer,
    pos: usize,

    pub fn init(streamer: Streamer) Stream {
        return .{
            .streamer = streamer,
            .pos = 0,
        };
    }

    pub fn read(self: Stream, allocator: std.mem.Allocator, total: usize) anyerror!void {
        return self.streamer.read(allocator, self.pos, total);
    }

    pub fn write(self: Stream, buf: []u8) anyerror!void {
        return self.streamer.write(buf, self.pos);
    }

    pub fn seek(self: Stream, offset: usize) anyerror!void {
        self.pos = offset;
    }
};
