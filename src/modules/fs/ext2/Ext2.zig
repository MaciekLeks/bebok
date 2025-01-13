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
const File = @import("deps.zig").File;

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

pub fn linkedDirectoryIterator(self: *const Ext2, allocator: std.mem.Allocator, inode: *const Inode) !LinkedDirectoryIterator {
    return LinkedDirectoryIterator.init(allocator, self, inode);
}

//--- Iterators
const LinkedDirectoryIterator = struct {
    const Self = @This();
    alloctr: std.mem.Allocator,
    inode: *const Inode,
    block_iterator: InodeBlockIterator,
    ext2: *const Ext2,
    block_buffer: []u8 = undefined,
    dir_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, ext2: *const Ext2, inode: *const Inode) !Self {
        if (!inode.isDirectory()) return error.NotDirectory;
        if (inode.flags.index) return error.IndexedDirectoryNotSupported;

        return Self{
            .alloctr = allocator,
            .inode = inode,
            .block_iterator = InodeBlockIterator.init(allocator, ext2, inode),
            .ext2 = ext2,
            .block_buffer = try allocator.alloc(u8, ext2.superblock.getBlockSize()),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allopctr.free(self.block_buffer);
        self.block_iterator.deinit();
    }

    /// Return next directory entry
    /// name_buffer: at least 255 bytes for the directory entry name
    pub fn next(self: *Self, name_buffer: []u8) !?LinkedDirectoryEntry {
        // Wczytaj pierwszy blok lub następny gdy przekroczono rozmiar aktualnego
        if (self.dir_pos == 0 or self.dir_pos >= self.block_buffer.len) {
            if (try self.block_iterator.next()) |block_num| {
                _ = try readBlock(self.ext2, block_num, self.block_buffer);
                self.dir_pos = 0;
            } else {
                return null;
            }
        }

        var fbs = std.io.fixedBufferStream(self.block_buffer[self.dir_pos..]);
        const reader = fbs.reader();

        // Read directory entry
        var entry = try LinkedDirectoryEntry.readFrom(reader, name_buffer);

        // Update position
        self.dir_pos += entry.getRecordLength();
        return entry;
    }
};

const InodeBlockIterator = struct {
    const Self = @This();
    alloctr: std.mem.Allocator,
    ext2: *const Ext2,
    inode: *const Inode,
    current_block: u32 = 0,
    stack: [3]struct {
        buffer: ?[]u32,
        idx: u32,
    } = undefined,
    depth: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, ext2: *const Ext2, inode: *const Inode) Self {
        return .{
            .alloctr = allocator,
            .ext2 = ext2,
            .inode = inode,
        };
    }

    pub fn deinit(self: *InodeBlockIterator) void {
        for (self.stack) |stack| {
            if (stack.buffer != null) {
                self.alloctr.free(stack.buffer);
            }
        }
    }

    fn processIndirectBlock(self: *Self, block_num: u32, level: u32) !?u32 {
        const curr_level = level - 1;

        if (self.stack[curr_level].idx == 0) {
            if (self.stack[curr_level].buffer == null) {
                self.stack[curr_level].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
            }
            const u8slice = std.mem.sliceAsBytes(self.stack[curr_level].buffer.?);
            _ = try readBlock(self.ext2, block_num, u8slice);
        }

        const buffer = self.stack[curr_level].buffer.?;
        defer self.stack[curr_level].idx += 1;

        if (self.stack[curr_level].idx >= buffer.len) return null;

        if (curr_level == 0) {
            return buffer[self.stack[curr_level].idx];
        }

        self.stack[curr_level - 1].idx = 0;
        return self.processIndirectBlock(buffer[self.stack[curr_level].idx], curr_level);
    }

    pub fn next(self: *Self) !?u32 {
        // Direct blocks (0-11)
        if (self.current_block < 12) {
            defer self.current_block += 1;
            const block_num = self.inode.block[self.current_block];
            return if (block_num == 0) null else block_num;
        }

        // Indirect blocks (12-14)
        const indirect_blocks = [_]struct {
            index: u32,
            level: u32,
        }{
            .{ .index = 12, .level = 1 }, // singly indirect
            .{ .index = 13, .level = 2 }, // doubly indirect
            .{ .index = 14, .level = 3 }, // triply indirect
        };

        if (self.depth == 0) {
            self.depth = 1;
            self.current_block = 12;
        }

        for (indirect_blocks) |block| {
            if (self.current_block == block.index) {
                if (try self.processIndirectBlock(self.inode.block[block.index], block.level)) |result| {
                    return result;
                } else {
                    self.current_block += 1;
                    self.depth = block.level + 1;
                    for (0..3) |lvl| self.stack[lvl].idx = 0;
                }
            }
        }

        return null;
    }
};

// Helper functions
pub fn findInodeByPath(self: *const Ext2, path: []const u8, start_dir_inode: ?u32) !u32 {
    log.debug("findInodeByPath: {s}", .{path});
    var arena = std.heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const alloctr = arena.allocator();

    var parser = pathparser.PathParser.init(alloctr);
    defer parser.deinit();
    try parser.parse(path);

    // Determine starting inode
    var curr_inode_num = if (parser.isAbsolute() and start_dir_inode == null)
        2 // root inode
    else if (!parser.isAbsolute() and start_dir_inode != null)
        start_dir_inode.?
    else
        return pathparser.PathError.InvalidPath;

    defer log.debug("findInodeByPath: res={d}", .{curr_inode_num});

    const name_buffer = try alloctr.alloc(u8, 256);
    const block_buffer = try alloctr.alloc(u8, self.superblock.getBlockSize());

    var it = parser.iterator();
    // Skip root segment if path is absolute
    if (parser.isAbsolute()) _ = it.next();

    // Iterate through path segments
    while (it.next()) |name| {
        const curr_inode = try self.readInode(curr_inode_num, block_buffer);

        if (!curr_inode.isDirectory()) {
            return pathparser.PathError.NotDirectory;
        }

        var dir_iter = try self.linkedDirectoryIterator(alloctr, &curr_inode);
        var found = false;

        while (dir_iter.next(name_buffer)) |opt_entry| {
            if (opt_entry) |entry| {
                if (std.mem.eql(u8, entry.getName(), name)) {
                    curr_inode_num = entry.header.inode;
                    found = true;
                    break;
                }
            } else break;
        } else |err| return err;

        if (!found) {
            return File.Error.NotFound;
        }
    }

    return curr_inode_num;
}
