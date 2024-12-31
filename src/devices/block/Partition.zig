const std = @import("std");

const Guid = @import("../deps.zig").Guid;
const Device = @import("../Device.zig");
const BlockDevice = @import("../BlockDevice.zig");
const Streamer = BlockDevice.Streamer;
const Filesystem = @import("../deps.zig").Filesystem;

const log = std.log.scoped("partition");

const Partition = @This();

pub const Type = enum {
    efi_system,
    linux_filesystem,
    linux_swap,
    msft_basic_data,
    unknown,

    const GuidMapping = struct {
        guid: Guid,
        type: Type,
    };

    pub fn fromGuid(guid: Guid) !Type {
        // Statyczna lista mapowań GUID -> Type
        const guid_mappings = [_]GuidMapping{
            .{
                // EFI System Partition
                .guid = Guid{
                    .data1 = 0xC12A7328,
                    .data2 = 0xF81F,
                    .data3 = 0x11D2,
                    .data4 = .{ 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B },
                },
                .type = Type.efi_system,
            },
            .{
                // Linux Filesystem
                .guid = Guid{
                    .data1 = 0x0FC63DAF,
                    .data2 = 0x8483,
                    .data3 = 0x4772,
                    .data4 = .{ 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 },
                },
                .type = Type.linux_filesystem,
            },
            .{
                // Linux Swap
                .guid = Guid{
                    .data1 = 0x0657FD6D,
                    .data2 = 0xA4AB,
                    .data3 = 0x43C4,
                    .data4 = .{ 0x84, 0xE5, 0x09, 0x33, 0xC8, 0x4B, 0x4F, 0x4F },
                },
                .type = Type.linux_swap,
            },
            .{
                // Microsoft Basic Data
                .guid = Guid{
                    .data1 = 0xEBD0A0A2,
                    .data2 = 0xB9E5,
                    .data3 = 0x4433,
                    .data4 = .{ 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 },
                },
                .type = Type.msft_basic_data,
            },
        };

        // Iteracja po mapowaniach w runtime
        for (guid_mappings) |mapping| {
            if (std.mem.eql(u8, std.mem.asBytes(&guid), std.mem.asBytes(&mapping.guid))) {
                return mapping.type;
            }
        }

        return .unknown;
    }
};

pub const Attributes = struct {
    required_to_function: bool,
    type_guid_specific: u32,
};

// Holds basic info about a partition. Use by partion scheme implementations to return partition info.
pub const Entry = struct {
    start_lba: u64,
    end_lba: u64,
    partition_type: Type,
    attributes: Attributes,
    name: [72]u8, //max as for GPT
    name_len: u8, //length of name
};

//Fields
alloctr: std.mem.Allocator,
block_device: BlockDevice,
parent: *BlockDevice, //e.g. NvmeNamespace
partition_type: Type,
attributes: Attributes,
name: []u8,
filesystem: ?*Filesystem,

// Device interface vtable for NvmeController
const device_vtable = Device.VTable{
    .deinit = deinit,
};

const block_device_vtable = BlockDevice.VTable{
    .streamer = streamer,
};

pub fn init(allocator: std.mem.Allocator, entry: Entry, parent: *BlockDevice) !*Partition {
    const self = try allocator.create(Partition);
    errdefer allocator.destroy(self); //if internal dupe signals error
    self.* = .{
        .alloctr = allocator, //we use page allocator internally cause LBA size is at least 512
        .block_device = .{
            .device = .{ .kind = Device.Kind.block, .vtable = &device_vtable },
            .state = .{
                .partition_scheme = null,
                .slba = entry.start_lba,
                .nlba = entry.end_lba - entry.start_lba + 1, //+1 cause end_lba is inclusive
                .lbads = parent.state.lbads,
            },
            .kind = .logical,
            .vtable = &block_device_vtable,
        },
        .parent = parent,
        .partition_type = entry.partition_type,
        .attributes = entry.attributes,
        .name = try allocator.dupeZ(u8, entry.name[0..entry.name_len]),
        .filesystem = null, //if present, will be set by the filesystem driver
    };

    return self;
}

pub fn fromDevice(dev: *Device) *Partition {
    const block_device: *BlockDevice = BlockDevice.fromDevice(dev);
    return @alignCast(@fieldParentPtr("block_device", block_device));
}

pub fn fromBlockDevice(block_device: *BlockDevice) *Partition {
    return @alignCast(@fieldParentPtr("block_device", block_device));
}

pub fn deinit(dev: *Device) void {
    const block_device: *BlockDevice = BlockDevice.fromDevice(dev);
    const self: *Partition = fromBlockDevice(block_device);

    block_device.deinit(); //should be safe here
    self.alloctr.free(self.name);
    self.alloctr.destroy(self);
}

pub fn streamer(bdev: *BlockDevice) Streamer {
    const self = fromBlockDevice(bdev);
    const vtable = Streamer.VTable{
        // user read and write internal implementations from the parent device
        .read = readInternal,
        .write = writeInternal,
        .calculate = calculateInternal,
    };
    return Streamer.init(self, vtable);
}

/// Calculate the LBA from the offset (starting from parent's LBA) and total bytes to read/write
/// offset: offset specified from partition's starting LBA
pub fn calculateInternal(ctx: *const anyopaque, offset: usize, total: usize) !Streamer.LbaPos {
    const self: *const Partition = @ptrCast(@alignCast(ctx));

    const lbads_bytes = self.block_device.state.lbads;
    const parent_slba = self.block_device.state.slba + offset / lbads_bytes; //starts on parent device
    const nlba: u16 = @intCast(try std.math.divCeil(usize, total, lbads_bytes));
    const slba_offset = offset % lbads_bytes;

    return .{ .slba = parent_slba, .nlba = nlba, .slba_offset = slba_offset };
}

/// Read from the parent device
/// @param allocator : User allocator
/// @param slba : Start Logical Block Address
/// @param nlb : Number of Logical Blocks
pub fn readInternal(ctx: *const anyopaque, allocator: std.mem.Allocator, slba: u64, nlba: u16) ![]u8 {
    const self: *const Partition = @ptrCast(@alignCast(ctx));
    const parent_streamer = self.parent.streamer(); //TODO: could be a field
    return try parent_streamer.vtable.read(parent_streamer.ptr, allocator, slba, nlba);
}

/// Write to the parent device
/// @param allocator : Allocator to allocate memory for PRP list
/// @param slba : Start Logical Block Address
/// @param data : Data to write
pub fn writeInternal(ctx: *const anyopaque, allocator: std.mem.Allocator, slba: u64, data: []const u8) !void {
    const self: *const Partition = @ptrCast(@alignCast(ctx));
    const parent_streamer = self.parent.streamer();
    try parent_streamer.vtable.write(parent_streamer.ptr, allocator, slba, data);
}
