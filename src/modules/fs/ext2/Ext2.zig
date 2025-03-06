const std = @import("std");
const builtin = @import("builtin");

const lang = @import("lang");
const Iterator = lang.iter.Iterator;

const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Filesystem = @import("fs").Filesystem;
const FileDescriptor = @import("fs").FileDescriptor;
const BlockNum = @import("types.zig").BlockNum;
const BlockGroupNum = @import("types.zig").BlockGroupNum;
const InodeNum = @import("types.zig").InodeNum;
const InodeIdx = @import("types.zig").InodeIdx;
const Superblock = @import("types.zig").Superblock;
const BlockGroupDescriptor = @import("types.zig").BlockGroupDescriptor;
const BlockAddressing = @import("types.zig").BlockAddressing;
const Inode = @import("types.zig").Inode;
const LinkedDirectoryEntry = @import("types.zig").LinkedDirectoryEntry;

//VFS
const fs = @import("fs");

const pmm = @import("mem").pmm; //block size should be the same as the page size
const heap = @import("mem").heap;
const block_size = pmm.page_size;

const log = std.log.scoped(.ext2);

const Ext2 = @This();

//Fields
alloctr: std.mem.Allocator,
partition: *Partition, //owning partition
sb: *Superblock,
block_group_descriptor_table: []BlockGroupDescriptor,
/// Every thread need own inode buffer
//block_buffer: []u8, //TOOD: not thread safe

pub fn new(allocator: std.mem.Allocator, partition: *Partition, sb: *Superblock, block_group_descriptor_table: []BlockGroupDescriptor) !*Ext2 {
    const self = try allocator.create(Ext2);
    self.* = .{
        .alloctr = allocator,
        .partition = partition,
        .sb = sb,
        .block_group_descriptor_table = block_group_descriptor_table,
        //.block_buffer = try allocator.alloc(u8, superblock.getBlockSize()),
    };
    return self;
}

// Should be called by the Parition deinit
pub fn destroy(ctx: *Ext2) void {
    const self: *Ext2 = @ptrCast(@alignCast(ctx));
    self.alloctr.destroy(self.sb);
    self.alloctr.free(self.block_group_descriptor_table);
    self.alloctr.destroy(self);
}

pub fn filesystem(self: *Ext2) Filesystem {
    return Filesystem.init(self, self.partition);
}

// pub fn superblock(self: *Ext2) VSuperblock {
//     // for now Ext2 implements Superblock functions directly
//     return VSuperblock.init(self);
// }
///////////////////////////////////////////////////////////////////////////////////////////////////
// Interface functions
pub fn lookupNodeNum(self: *Ext2, path: []const u8, start_node_num: ?fs.NodeNum) anyerror!fs.NodeNum {
    return findInodeByPath(self, path, start_node_num);
}

/// readInode using alloctator
/// TODO: allocates memory twice, once for block and the 2nd time for inode
/// Caller needs to destroy Ext2 Inode memory
pub fn readNode(self: *Ext2, allocator: std.mem.Allocator, inode_num: fs.NodeNum) !fs.Node {
    const block_buffer = try allocator.alloc(u8, self.sb.getBlockSize());
    defer allocator.free(block_buffer);

    const inode_pos = getInodePosFromInodeNum(self, inode_num);

    try readBlock(self, inode_pos.block_num, block_buffer);

    const inode = try allocator.create(Inode);

    const offset = inode_pos.offset;
    @memcpy(std.mem.asBytes(inode), block_buffer[offset..(offset + @sizeOf(Inode))]);

    return fs.Node.init(self, inode_num, inode);
}

pub fn getPageIter(self: *Ext2, allocator: std.mem.Allocator, node: fs.Node) !Iterator(fs.PageNum) {
    const ibi = try InodeBlockIterator.new(allocator, self, @ptrCast(@alignCast(node.data)));
    return ibi.iter();
}

/// Get file size of a regular file in bytes
/// Return null if not a regular file
pub fn getFileSize(self: *const Ext2, node: fs.Node) ?usize {
    const inode: *const Inode = @ptrCast(@alignCast(node.data));

    if (inode.mode.format != .regular_file and self.sb.major_rev_level != .dynamic) return null;

    return if (self.sb.major_rev_level == .dynamic)
        (@as(u64, inode.dir_acl) << 32) | inode.size
    else
        inode.size;
}

pub fn readPage(self: *const Ext2, pg_num: fs.PageNum, buf: []u8) !void {
    return try self.readBlock(pg_num, buf);
}

pub fn getPageSize(self: *const Ext2) usize {
    return self.sb.getBlockSize();
}

///////////////////////////////////////////////////////////////////////////////////////////////////

//---Private functions
inline fn getBlockGroupNumFromInodeNum(self: *const Ext2, inode_num: InodeNum) BlockGroupNum {
    return (inode_num - 1) / self.sb.inodes_per_group;
}

/// Retrieve inode index inside of a block group
inline fn getInodeIdxInBlockGroup(self: *const Ext2, inode_num: u32) InodeIdx {
    return (inode_num - 1) % self.sb.inodes_per_group;
}

inline fn getRelBlockNumberFromInodeIdx(self: *const Ext2, inode_idx: InodeIdx) BlockNum {
    return (inode_idx * self.sb.inode_size) / self.sb.getBlockSize();
}

inline fn getInodePosFromInodeNum(self: *const Ext2, inode_num: u32) struct { block_num: BlockNum, offset: u32 } {
    const bg_num = getBlockGroupNumFromInodeNum(self, inode_num);
    const inode_idx = getInodeIdxInBlockGroup(self, inode_num);
    const rel_block_num = getRelBlockNumberFromInodeIdx(self, inode_idx);
    return .{ .block_num = self.block_group_descriptor_table[bg_num].inode_table + rel_block_num, .offset = (inode_idx * self.sb.inode_size) % self.sb.getBlockSize() };
}

inline fn getOffsetFromBlockNum(block_num: usize) usize {
    return block_size * block_num;
}

fn readBlock(self: *const Ext2, block_num: BlockNum, buffer: []u8) !void {
    var stream = BlockDevice.Stream(u8).init(self.partition.block_device.streamer());
    stream.seek(getOffsetFromBlockNum(block_num), .start);
    _ = try stream.readAll(buffer);
}

//TODO: remove pub qualifier
/// Read inode from the disk using existing block_bffer to not alloc memory each time
pub fn readInodeInternal(self: *const Ext2, inode_num: u32, block_buffer: []u8) !Inode {
    const inode_pos = getInodePosFromInodeNum(self, inode_num);

    try readBlock(self, inode_pos.block_num, block_buffer);

    const inode: *const Inode = @ptrCast(@alignCast(block_buffer.ptr + inode_pos.offset));

    log.debug("Inode[{d}]: {}", .{ inode_num, inode.* });
    return inode.*;
}

pub fn linkedDirectoryIterator(self: *Ext2, allocator: std.mem.Allocator, inode: *const Inode) !*LinkedDirectoryIterator {
    return LinkedDirectoryIterator.new(allocator, self, inode);
}

// TODO: refactor using a new Iterator
const LinkedDirectoryIterator = struct {
    const Self = @This();
    alloctr: std.mem.Allocator,
    inode: *const Inode,
    block_iterator: *InodeBlockIterator,
    ext2: *const Ext2,
    block_buffer: []u8 = undefined,
    dir_pos: usize = 0,

    pub fn new(allocator: std.mem.Allocator, ext2: *const Ext2, inode: *const Inode) !*Self {
        if (!inode.isDirectory()) return error.NotDirectory;
        if (inode.flags.index) return error.IndexedDirectoryNotSupported;

        const self = try allocator.create(Self);
        self.* = .{
            .alloctr = allocator,
            .inode = inode,
            .block_iterator = try InodeBlockIterator.new(allocator, ext2, inode),
            .ext2 = ext2,
            .block_buffer = try allocator.alloc(u8, ext2.sb.getBlockSize()),
        };

        return self;
    }

    pub fn destroy(self: *Self) void {
        self.alloctr.free(self.block_buffer);
        self.block_iterator.destroy();
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

/// Iterator for traversing inode blocks
/// TODO:
///- add start offset to fast forward to a specific block (1..16) in Inode blocks
pub const InodeBlockIterator = struct {
    const Self = @This();
    const ReadBlockFn = *const fn (*const Ext2, u32, []u8) anyerror!void;
    alloctr: std.mem.Allocator = undefined, //page heap allocator needed since we alloc page size blocks
    ext2: *const Ext2,
    inode: *const Inode,
    curr_block_idx: u8 = 0, //0-11 direct blocks, 12-14 indirect blocks
    curr_block_level: u8 = 0,
    stack: [3]struct {
        buffer: ?[]BlockNum,
        idx: u32,
        needs_load: bool,
    },
    readBlockFn: ReadBlockFn = &readBlock, //defaults to readBlock

    pub fn new(allocator: std.mem.Allocator, ext2: *const Ext2, inode: *const Inode) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .alloctr = allocator,
            .ext2 = ext2,
            .inode = inode,
            .stack = .{
                .{ .buffer = null, .idx = 0, .needs_load = true }, //TODO: can't use array multiplication operator
                .{ .buffer = null, .idx = 0, .needs_load = true },
                .{ .buffer = null, .idx = 0, .needs_load = true },
            },
        };
        return self;
    }

    pub fn destroy(self: *InodeBlockIterator) void {
        for (self.stack) |stack| {
            if (stack.buffer) |buf_ptr| self.alloctr.free(buf_ptr);
        }
        self.alloctr.destroy(self);
    }

    pub fn iter(self: *Self) Iterator(BlockNum) {
        return Iterator(BlockNum).init(self);
    }

    pub fn next(self: *Self) !?BlockNum {
        // Handle direct blocks (0-11)
        if (self.curr_block_idx < 12) {
            defer self.curr_block_idx += 1;
            const block_num = self.inode.block[self.curr_block_idx];
            if (block_num != 0) return block_num;
        }

        while (self.curr_block_idx <= 14) {
            const block_num = self.inode.block[self.curr_block_idx];
            if (block_num == 0) break;

            var current_level = self.curr_block_idx - 12; //0-12th, 1-13th, 2-14th
            var base_block = block_num;

            while (true) {
                // Allocate buffer if needed
                if (self.stack[current_level].buffer == null) {
                    self.stack[current_level].buffer = try self.alloctr.alloc(BlockNum, self.ext2.sb.getBlockSize() / @sizeOf(BlockNum));
                    self.stack[current_level].needs_load = true;
                    self.stack[current_level].idx = 0;
                }

                // Load data into buffer
                if (self.stack[current_level].needs_load) {
                    try self.readBlockFn(self.ext2, base_block, std.mem.sliceAsBytes(self.stack[current_level].buffer.?));
                    self.stack[current_level].needs_load = false;
                }

                const buffer = self.stack[current_level].buffer.?;
                if (self.stack[current_level].idx >= buffer.len) {
                    self.stack[current_level].idx = 0;
                    if (current_level + 12 == self.curr_block_idx) {
                        self.curr_block_idx += 1;
                        break;
                    } else {
                        current_level += 1;
                        self.stack[current_level].idx += 1;
                        continue;
                    }
                }

                if (current_level == 0) {
                    const result = buffer[self.stack[0].idx];
                    self.stack[0].idx += 1;
                    if (result != 0) {
                        return result;
                    }
                }

                base_block = buffer[self.stack[current_level].idx];
                if (base_block == 0) {
                    self.stack[current_level].idx += 1;
                    continue;
                }

                if (current_level > 0) {
                    current_level -= 1;
                    self.stack[current_level].needs_load = true;
                }
            }
        }
        return null;
    }
};

// Helper functions
pub fn findInodeByPath(self: *Ext2, path: []const u8, start_dir_inode: ?u32) !InodeNum {
    log.debug("findInodeByPath: {s}", .{path});
    var arena = std.heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const alloctr = arena.allocator();

    var parser = fs.PathParser.init(alloctr);
    defer parser.deinit();
    try parser.parse(path);

    // Determine starting inode
    var curr_inode_num = if (parser.isAbsolute() and start_dir_inode == null)
        2 // root inode
    else if (!parser.isAbsolute() and start_dir_inode != null)
        start_dir_inode.?
    else
        return fs.PathParser.PathError.InvalidPath;

    defer log.debug("findInodeByPath: res={d}", .{curr_inode_num});

    const name_buffer = try alloctr.alloc(u8, 256);
    const block_buffer = try alloctr.alloc(u8, self.sb.getBlockSize());

    var it = parser.iterator();
    // Skip root segment if path is absolute
    if (parser.isAbsolute()) _ = it.next();

    // Iterate through path segments
    while (it.next()) |name| {
        const curr_inode = try self.readInodeInternal(curr_inode_num, block_buffer);

        if (!curr_inode.isDirectory()) {
            return fs.PathParser.PathError.NotDirectory;
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
            return fs.File.Error.NotFound;
        }
    }

    return curr_inode_num;
}
