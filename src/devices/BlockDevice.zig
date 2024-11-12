const std = @import("std");
const NvmeController = @import("deps.zig").NvmeController;
const Device = @import("Device.zig");

const heap = @import("deps.zig").heap; //TODO: tbd

const log = std.log.scoped(.blockl_device);

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
    pub const LbaPos = struct {
        slba: u64,
        nlba: u16,
        slba_offset: u64,
    };

    pub const VTable = struct {
        //read: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror![]u8,
        read: *const fn (ctx: *const anyopaque, allocator: std.mem.Allocator, offset: u64, total: u16) anyerror![]u8,
        //write: *const fn (ctx: *anyopaque, offset: usize, buf: []u8) anyerror!void,
        write: *const fn (ctx: *const anyopaque, allocator: std.mem.Allocator, slba: u64, data: []const u8) anyerror!void,
        calculate: *const fn (ctx: *const anyopaque, offset: usize, total: usize) anyerror!Streamer.LbaPos,
    };

    ptr: *const anyopaque,
    vtable: VTable,

    pub fn read(self: Streamer, comptime T: type, inalloctr: std.mem.Allocator, allocator: std.mem.Allocator, offset: usize, total: usize) anyerror![]T {
        const total_bytes = total * @sizeOf(T);
        const lba = try self.vtable.calculate(self.ptr, offset, total_bytes);
        log.debug("read(): Calculated slba: {d}, nlba: {d}, offset: {d}", .{ lba.slba, lba.nlba, lba.slba_offset });

        const data = try self.vtable.read(self.ptr, inalloctr, lba.slba, lba.nlba);
        defer inalloctr.free(data);

        const buf = allocator.alloc(T, total) catch |err| {
            log.err("read(): Failed to allocate memory for data buffer: {}", .{err});
            return error.OutOfMemory;
        };

        @memcpy(buf, std.mem.bytesAsSlice(T, data[lba.slba_offset .. lba.slba_offset + total_bytes]));

        return buf;
    }

    pub fn write(self: Streamer, comptime T: type, inalloctr: std.mem.Allocator, offset: usize, buf: []const T) anyerror!void {
        const total_bytes = buf.len * @sizeOf(T);
        const lba = try self.vtable.calculate(self.ptr, offset, total_bytes);
        log.debug("read(): Calculated LBA: {d}, NLBA: {d}, Offset: {d}", .{ lba.slba, lba.nlba, lba.slba_offset });

        //TODO: cache needed
        const data = try self.vtable.read(self.ptr, inalloctr, lba.slba, lba.nlba);
        defer inalloctr.free(data);

        // copy buffer into data starting from lba.slba_offset
        const buf_bytes = std.mem.bytesAsSlice(u8, buf);
        @memcpy(data[lba.slba_offset .. lba.slba_offset + total_bytes], buf_bytes);

        try self.vtable.write(self.ptr, inalloctr, lba.slba, data);
    }

    pub fn init(ctx: *const anyopaque, vtable: VTable) Streamer {
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
        alloctr: std.mem.Allocator,

        pub fn init(streamer: Streamer) Self {
            return .{
                .streamer = streamer,
                .pos = 0,
                .alloctr = heap.page_allocator, //TODO: make more flexible
            };
        }

        pub fn read(self: *Self, allocator: std.mem.Allocator, total: usize) anyerror![]T {
            const data = try self.streamer.read(T, self.alloctr, allocator, self.pos, total);
            self.pos += total * @sizeOf(T);
            return data;
        }

        pub fn write(self: *Self, buf: []const T) anyerror!void {
            try self.streamer.write(T, self.alloctr, self.pos, buf);
            self.pos += buf.len * @sizeOf(T);
        }

        pub fn seek(self: *Self, offset: usize) void {
            self.pos = offset;
        }
    };
}
