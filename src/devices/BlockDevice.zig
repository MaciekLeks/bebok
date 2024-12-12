const std = @import("std");
//const NvmeController = @import("deps.zig").NvmeController;
const NvmeNamespace = @import("deps.zig").NvmeNamespace;
const Device = @import("Device.zig");

const PartitionScheme = @import("block/PartitionScheme.zig");

const heap = @import("deps.zig").heap; //TODO: tbd

const log = std.log.scoped(.blockl_device);

const BlockDevice = @This();

const BlockDeviceSpec = union(enum) {
    //nvme_ctrl: *NvmeController,
    nvme_namespace: *const NvmeNamespace,
};

const State = struct {
    partition_scheme: ?*const PartitionScheme, // null means partitionless device
};

alloctr: std.mem.Allocator,
device: Device, //Device interface implemented as @fieldParentPtr pattern
spec: BlockDeviceSpec,
state: State,

// Device interface vtable for NvmeController
const device_vtable = Device.VTable{
    .deinit = deinit,
};

pub fn init(
    allocator: std.mem.Allocator,
    block_device_spec: BlockDeviceSpec,
) !*BlockDevice {
    const self = try allocator.create(BlockDevice);
    self.* = .{
        .alloctr = allocator,
        .device = .{ .kind = Device.Kind.block, .vtable = &device_vtable },
        .spec = block_device_spec,
        .state = .{ .partition_scheme = null },
    };

    return self;
}

pub fn deinit(dev: *Device) void {
    const self: *BlockDevice = @fieldParentPtr("device", dev);
    defer self.alloctr.destroy(self);

    if (self.state.partition_scheme) |scheme| {
        scheme.deinit();
    }
    return switch (self.spec) {
        inline else => |it| it.deinit(),
    };
}

pub fn fromDevice(dev: *Device) *BlockDevice {
    return @fieldParentPtr("device", dev);
}

pub fn streamer(self: *BlockDevice) Streamer {
    return switch (self.spec) {
        inline else => |spec| spec.streamer(),
    };
}

pub fn detectPartitionScheme(self: *BlockDevice) !void {
    const scheme = try PartitionScheme.init(self.alloctr, self.streamer());
    log.debug("Partition scheme detected: {any}", .{scheme});
    self.state.partition_scheme = scheme;
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

        pub fn init(s: Streamer, allocator: std.mem.Allocator) Self {
            return .{ .streamer = s, .pos = 0, .alloctr = allocator };
        }

        pub fn read(self: *Self, allocator: std.mem.Allocator, total: usize) anyerror![]T {
            const data = try self.streamer.read(T, self.alloctr, allocator, self.pos, total);
            self.pos += total * @sizeOf(T);
            return data;
        }

        pub fn readAll(self: *Self, buf: []T) anyerror!void {
            // const data = try self.read(self.alloctr, buf.len);
            // defer self.alloctr.free(data);
            // @memcpy(buf, data);
            // We use a fixed buffer to avoid multiple allocations
            var fba = std.heap.FixedBufferAllocator.init(buf);
            _ = try self.read(fba.allocator(), buf.len);
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
