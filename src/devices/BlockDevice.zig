const std = @import("std");
const Device = @import("Device.zig");

const PartitionScheme = @import("block/PartitionScheme.zig");
const Partition = @import("block/Partition.zig");
const Bus = @import("bus").Bus;

const heap = @import("mem").heap; //TODO: tbd
const log = std.log.scoped(.block_device);

const BlockDevice = @This();

//Fields
device: Device, //Device interface implemented as @fieldParentPtr pattern
state: State,
vtable: *const VTable,
kind: Kind = .raw,

//BlockDevice kind (subkind of block kind)
pub const Kind = enum {
    logical, //e.g. partition
    raw, //e.g. whole device
};

pub const VTable = struct {
    //add example function as. someFn(physdev: *PhysDevice ) and then implement fn(*PhysDevice) in the implementator
    streamer: *const fn (ctx: *BlockDevice) Streamer,
};

const State = struct {
    partition_scheme: ?*const PartitionScheme, // null means partitionless device
    slba: u64, // start lba
    nlba: u64, // number of lba
    lbads: u64, // size of lba
};

pub fn deinit(self: *BlockDevice) void {
    if (self.state.partition_scheme) |scheme| {
        scheme.deinit();
    }
}

pub fn fromDevice(dev: *Device) *BlockDevice {
    return @fieldParentPtr("device", dev);
}

pub fn streamer(self: *BlockDevice) Streamer {
    return @call(.auto, self.vtable.streamer, .{self});
}

// Initialize partition scheme and partition devices if any.Helper function for kernel.zig
// Remark: Memory released by bus deinit function
pub fn scanBlockDevices(bus: *Bus, allocator: std.mem.Allocator) !void {
    for (bus.devices.items) |*dev_node| {
        //log.warn("Device: {}", .{dev_node}); //TODO:  prontformat method needed to avoid tripple fault

        if (dev_node.device.kind == Device.Kind.block) {
            const block_dev = BlockDevice.fromDevice(dev_node.device);

            block_dev.initPartitions(allocator, bus, dev_node) catch |err| {
                log.err("Partition initialization error: {}", .{err});
            };
        }
    }
}

fn detectPartitionScheme(self: *BlockDevice, allocator: std.mem.Allocator) !void {
    const scheme = try PartitionScheme.init(allocator, self.streamer(), self.state.lbads);
    log.debug("Partition scheme detected: {any}", .{scheme});
    self.state.partition_scheme = scheme;
}

fn initPartitions(self: *BlockDevice, allocator: std.mem.Allocator, bus: *Bus, parent: *Bus.DeviceNode) !void {
    self.detectPartitionScheme(allocator) catch |err| {
        log.err("Partition scheme detection error: {}", .{err});
    };

    if (self.state.partition_scheme) |scheme| {
        // TODO: the code below is just an example, how to iterate over schemes
        //     switch (scheme.spec) {
        //         .gpt => |gpt| {
        //             log.debug("GPT detected", .{});
        //             log.debug("GPT header: {}", .{gpt.header});
        //             for (gpt.entries) |entry| {
        //                 if (entry.isEmpty()) {
        //                     continue;
        //                 }
        //                 log.debug("GPT entry: {}", .{entry});
        //             }
        //         },
        //     }

        // Iterate over partitions no matter the scheme
        var it = scheme.iterator();
        while (it.next()) |partition_entry_opt| {
            if (partition_entry_opt) |partition_entry| {
                const partition = try Partition.init(allocator, partition_entry, self);

                log.debug("Partition slba={}, nlba={}, type={}, name='{s}'", .{ partition.block_device.state.slba, partition.block_device.state.nlba, partition.partition_type, partition.name });
                _ = try bus.addDevice(&partition.block_device.device, parent);
            } else {
                log.debug("No more partition", .{});
                break;
            }
        } else |err| {
            log.err("Partition iteration error: {}", .{err});
        }
    }
}

pub fn getSize(self: *BlockDevice) u64 {
    return self.state.nlba * self.state.lbads;
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
    vtable: @This().VTable,

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

    pub fn init(ctx: *const anyopaque, vtable: @This().VTable) Streamer {
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

        const SeekMode = enum {
            start,
            current,
            //end,
        };

        streamer: Streamer,
        pos: usize, //in bytes
        alloctr: std.mem.Allocator = heap.page_allocator, //we need to use page aligned allocators

        pub fn init(s: Streamer) Self {
            return .{ .streamer = s, .pos = 0 };
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
            var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(buf)); //TODO: ?
            _ = try self.read(fba.allocator(), buf.len);
        }

        pub fn write(self: *Self, buf: []const T) anyerror!void {
            try self.streamer.write(T, self.alloctr, self.pos, buf);
            self.pos += buf.len * @sizeOf(T);
        }

        pub fn seek(self: *Self, offset: usize, mode: SeekMode) void {
            switch (mode) {
                SeekMode.start => {
                    self.pos = offset;
                },
                SeekMode.current => {
                    self.pos += offset;
                },
            }
        }
    };
}
