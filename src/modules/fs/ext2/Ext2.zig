const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const Filesystem = @import("deps.zig").Filesystem;
const FileDescriptor = @import("deps.zig").FileDescriptor;
const Superblock = @import("types.zig").Superblock;
const BlockGroupDescriptor = @import("types.zig").BlockGroupDescriptor;
const BlockAddressing = @import("types.zig").BlockAddressing;
const Inode = @import("types.zig").Inode;

const pmm = @import("deps.zig").pmm; //block size should be the same as the page size
const block_size = pmm.page_size;

const log = std.log.scoped(.ext2);

const Ext2 = @This();

//Fields
alloctr: std.mem.Allocator,
superblock: *Superblock,
block_group_descriptor_table: []BlockGroupDescriptor,

pub fn init(allocator: std.mem.Allocator, superblock: *Superblock, block_group_descriptor_table: []BlockGroupDescriptor) !*Ext2 {
    const self = try allocator.create(Ext2);
    self.* = .{
        .alloctr = allocator,
        .superblock = superblock,
        .block_group_descriptor_table = block_group_descriptor_table,
    };
    return self;
}

// Should be called by the Parition deinit
pub fn deinit(ctx: *anyopaque) void {
    const self: *Ext2 = @ptrCast(@alignCast(ctx));
    self.alloctr.destroy(self.superblock);
    self.alloctr.free(self.block_group_descriptor_table);
    self.alloctr.destroy(self);
}

pub fn open(ctx: *anyopaque, partition: *Partition) anyerror!Filesystem.Descriptor {
    _ = ctx;
    _ = partition;
    return error.Unimplemented;
}

pub fn filesystem(self: *Ext2) Filesystem {
    const vtable = Filesystem.VTable{
        .deinit = deinit,
        .open = open,
    };
    return Filesystem.init(self, vtable);
}
