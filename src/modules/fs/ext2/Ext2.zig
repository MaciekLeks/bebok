const std = @import("std");

const BlockDevice = @import("deps.zig").BlockDevice;
const Partition = @import("deps.zig").Partition;
const Filesystem = @import("deps.zig").Filesystem;
const FileDescriptor = @import("deps.zig").FileDescriptor;
const Superblock = @import("types.zig").Superblock;
const BlockGroupDescriptor = @import("types.zig").BlockGroupDescriptor;
const BlockAddressing = @import("types.zig").BlockAddressing;
const Inode = @import("types.zig").Inode;
const LinkedDirectoryEntry = @import("types.zig").LinkedDirectoryEntry;

const pathparser = @import("deps.zig").pathparser;
const pmm = @import("deps.zig").pmm; //block size should be the same as the page size
const heap = @import("deps.zig").heap;
const block_size = pmm.page_size;

const log = std.log.scoped(.ext2);

const Ext2 = @This();

//Fields
alloctr: std.mem.Allocator,
partition: *Partition, //owning partition
superblock: *Superblock,
block_group_descriptor_table: []BlockGroupDescriptor,
/// Every thread need own inode buffer
//block_buffer: []u8, //TOOD: not thread safe

pub fn init(allocator: std.mem.Allocator, partition: *Partition, superblock: *Superblock, block_group_descriptor_table: []BlockGroupDescriptor) !*Ext2 {
    const self = try allocator.create(Ext2);
    self.* = .{
        .alloctr = allocator,
        .partition = partition,
        .superblock = superblock,
        .block_group_descriptor_table = block_group_descriptor_table,
        //.block_buffer = try allocator.alloc(u8, superblock.getBlockSize()),
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
    const rel_block_num = getRelBlockNumberFromInodeIdx(self, inode_idx);
    return .{ .block_num = self.block_group_descriptor_table[bg_num].inode_table_id + rel_block_num, .offset = (inode_idx * self.superblock.inode_size) % self.superblock.getBlockSize() };
}

inline fn getOffsetFromBlockNum(block_num: usize) usize {
    return block_size * block_num;
}

fn readBlock(self: *const Ext2, block_num: usize, buffer: []u8) !void {
    var stream = BlockDevice.Stream(u8).init(self.partition.block_device.streamer());
    stream.seek(getOffsetFromBlockNum(block_num), .start);
    _ = try stream.readAll(buffer);
}

//TODO: remove pub qualifier
/// Read inode from the disk using existing block_bffer to not alloc memory each time
pub fn readInode(self: *const Ext2, inode_num: u32, block_buffer: []u8) !Inode {
    const inode_pos = getInodePosFromInodeNum(self, inode_num);

    try readBlock(self, inode_pos.block_num, block_buffer);

    const inode: *const Inode = @ptrCast(@alignCast(block_buffer.ptr + inode_pos.offset));

    log.debug("Inode[{d}]: {}", .{ inode_num, inode.* });
    return inode.*;
}

pub fn linkedDirectoryIterator(self: *const Ext2, inode: *const Inode, block_buffer: []u8) LinkedDirectoryIterator {
    return LinkedDirectoryIterator{
        .ext2 = self,
        .inode = inode,
        .block_buffer = block_buffer,
    };
}

//--- Iterators
const LinkedDirectoryIterator = struct {
    const Self = @This();
    inode: *const Inode,
    ext2: *const Ext2,
    block_buffer: []u8,
    dir_pos: usize = 0, //current position in the all direcotry's blocks in bytes
    dir_block: ?usize = null, //current block index [0..14] in the inode.block table

    /// Return next directory entry
    /// name_buffer: at least 255 bytes for the directory entry name
    pub fn next(self: *Self, name_buffer: []u8) !?LinkedDirectoryEntry {
        if (self.inode.flags.index) return error.IndexedDirectoryNotSupported;

        const curr_dir_block = self.dir_pos / self.ext2.superblock.getBlockSize();

        if (self.dir_block == null or curr_dir_block != self.dir_block) {
            self.dir_block = curr_dir_block;
            if (self.inode.block[self.dir_block.?] == 0) return null; //0 means no more data
            switch (self.dir_block.?) {
                0...11 => try readBlock(self.ext2, self.inode.block[self.dir_block.?], self.block_buffer),
                12...14 => return error.Unimplemented, //TODO: implement indirect blocks
                else => return error.Unreachable,
            }
        }

        const block_offset = self.dir_pos % self.ext2.superblock.getBlockSize();
        var fbs = std.io.fixedBufferStream(self.block_buffer[block_offset..]);
        const reader = fbs.reader();

        //Read directory entry
        var entry = try LinkedDirectoryEntry.readFrom(reader, name_buffer);

        //Update position
        self.dir_pos += entry.getRecordLength();

        return entry;
    }
};

// Helper functions
pub fn findInodeByPath(self: *const Ext2, path: []const u8, start_dir_inode: ?u32) !u32 {
    log.debug("findInodeByPath: {s}", .{path});

    var arena = std.heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const alloctr = arena.allocator();

    const path_parts = try pathparser.parse(alloctr, path);

    // Start from root if path is absolute, otherwise use provided start_inode
    var curr_inode_num = if (path_parts.is_absolute and start_dir_inode == null) 2 // root inode
    else if (!path_parts.is_absolute and start_dir_inode != null) start_dir_inode.? else return pathparser.PathError.InvalidPath;

    defer log.debug("findInodeByPath: res={d}", .{curr_inode_num});

    const name_buffer = try alloctr.alloc(u8, 256); //file name buffer
    const block_buffer = try alloctr.alloc(u8, self.superblock.getBlockSize());

    // Walk through the path
    var curr_part = path_parts;

    while (true) {
        // Skip empty parts (like root with null part)
        if (curr_part.part == null) {
            if (curr_part.next) |next| {
                curr_part = next;
                continue;
            }
            break;
        }

        const curr_inode = try self.readInode(curr_inode_num, block_buffer);

        // If this is a directory part, verify the current inode is actually a directory
        if (curr_part.part_type == .Directory and !curr_inode.isDirectory()) {
            return pathparser.PathError.InvalidPath;
        }

        var dir_iter = self.linkedDirectoryIterator(&curr_inode, block_buffer);
        var found = false;

        while (dir_iter.next(name_buffer)) |opt_entry| {
            if (opt_entry) |entry| {
                if (std.mem.eql(u8, entry.getName(), curr_part.part.?)) {
                    curr_inode_num = entry.header.inode;
                    found = true;
                    break;
                }
            } else break;
        } else |err| {
            return err;
        }

        if (!found) {
            return pathparser.PathError.NotFound;
        }

        if (curr_part.next) |next| {
            curr_part = next;
        } else {
            break;
        }
    }

    return curr_inode_num;
}
