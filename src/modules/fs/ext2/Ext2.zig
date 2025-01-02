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
partition: * Partition, //owning partition
superblock: *Superblock,
block_group_descriptor_table: []BlockGroupDescriptor,
/// Every thread need own inode buffer
inode_buffer: []u8, //TOOD: not thread safe

pub fn init(allocator: std.mem.Allocator, partition: * Partition, superblock: *Superblock, block_group_descriptor_table: []BlockGroupDescriptor) !*Ext2 {
    const self = try allocator.create(Ext2);
    self.* = .{
        .alloctr = allocator,
        .partition = partition,
        .superblock = superblock,
        .block_group_descriptor_table = block_group_descriptor_table,
        .inode_buffer = try allocator.alloc(u8, superblock.inode_size),
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

//---Private functions
inline fn getBlockGroupNumFromInodeNum(self: *const Ext2, inode_num: usize) usize {
    return (inode_num - 1) / self.superblock.inodes_per_group;
}

/// Retrieve inode index inside of a block group
inline fn getInodeIdxInBlockGroup(self: *const Ext2, inode_num: usize) usize {
    return (inode_num - 1) % self.superblock.inodes_per_group;
}

inline fn getRelBlockNumberFromInodeIdx(self: *const Ext2, inode_idx: usize) usize {
    return (inode_idx * self.superblock.inode_size) / self.superblock.getBlockSize();
}

inline fn getInodePosFromInodeNum(self: *const Ext2, inode_num: usize) struct { block_num: usize, offset: usize } {
    const bg_num = getBlockGroupNumFromInodeNum(self, inode_num);
    const inode_idx = getInodeIdxInBlockGroup(self, inode_num);
    const rel_block_num =  getRelBlockNumberFromInodeIdx(self, inode_idx);
    return  .{ 
        .block_num = self.block_group_descriptor_table[bg_num].inode_table_id + rel_block_num,
        .offset = (inode_idx * self.superblock.inode_size) % self.superblock.getBlockSize() 
    };
}

inline fn getOffsetFromBlockNum(block_num: usize) usize {
    return block_size * block_num;
}
//TODO: remove pub qualifier
pub fn readInode(self: *const Ext2, inode_num: usize) !*const Inode {
    const inode_pos = getInodePosFromInodeNum(self, inode_num);
    var stream = BlockDevice.Stream(u8).init(self.partition.block_device.streamer());
    stream.seek(getOffsetFromBlockNum(inode_pos.block_num) + inode_pos.offset, .start);

    _ = try stream.readAll(self.inode_buffer);
    
    const inode: *const Inode = @ptrCast(@alignCast(self.inode_buffer.ptr));

    log.debug("Inode[{d}]: {}", .{ inode_num, inode.* });
    return inode;
} 

