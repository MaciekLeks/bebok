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

// TODO: can't use generic Steamer(T), see: https://www.reddit.com/r/Zig/comments/1gcexso/dynamic_interface_with_comptime_vtable_functions/
pub const Streamer = struct {
    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror![]u8,
        write: *const fn (ctx: *anyopaque, offset: usize, buf: []u8) anyerror!void,
    };

    ptr: *anyopaque,
    vtable: VTable,

    pub fn read(self: Streamer, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror![]u8 {
        return self.vtable.read(self.ptr, allocator, offset, total);
    }

    pub fn write(self: Streamer, offset: usize, buf: []u8) anyerror!void {
        return self.vtable.write(self.ptr, offset, buf);
    }

    pub fn readAs(self: Streamer, comptime T: type, allocator: std.mem.Allocator, offset: usize, total: usize) ![]T {
        const bytes = try self.read(allocator, offset, total * @sizeOf(T));
        return std.mem.bytesAsSlice(T, bytes);
    }

    pub fn writeFrom(self: Streamer, comptime T: type, offset: usize, data: []const T) !void {
        const bytes = std.mem.sliceAsBytes(data);
        try self.write(offset, bytes);
    }

    pub fn init(ctx: *anyopaque, vtable: VTable) Streamer {
        return .{
            .ptr = ctx,
            .vtable = vtable,
        };
    }

    pub fn from(ctx: *anyopaque, TImpl: type) Streamer {
        const self: *TImpl = @ptrCast(@alignCast(ctx));
        return Streamer(){
            .ptr = self,
            .vtable = &.{ .read = TImpl.read, .write = TImpl.write },
        };
    }
};

pub fn Stream(comptime T: type) type {
    return struct {
        const Self = @This();

        streamer: Streamer,
        pos: usize, //in bytes

        pub fn init(streamer: Streamer) Self {
            return .{
                .streamer = streamer,
                .pos = 0,
            };
        }

        pub fn read(self: *Self, allocator: std.mem.Allocator, total: usize) anyerror![]T {
            const data = try self.streamer.readAs(T, allocator, self.pos, total);
            self.pos += total * @sizeOf(T);
            return data;
        }

        pub fn write(self: *Self, buf: []T) anyerror!void {
            try self.streamer.writeAs(self.pos, buf);
            self.pos += buf.len * @sizeOf(T);
        }

        pub fn seek(self: *Self, offset: usize) anyerror!void {
            self.pos = offset;
        }
    };
}
