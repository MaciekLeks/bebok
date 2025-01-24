const std = @import("std");
const builtin = @import("builtin");

const BlockDevice = @import("devices").BlockDevice;
const Partition = @import("devices").Partition;
const Filesystem = @import("fs").Filesystem;
const FileDescriptor = @import("fs").FileDescriptor;
const Superblock = @import("types.zig").Superblock;
const BlockGroupDescriptor = @import("types.zig").BlockGroupDescriptor;
const BlockAddressing = @import("types.zig").BlockAddressing;
const Inode = @import("types.zig").Inode;
const LinkedDirectoryEntry = @import("types.zig").LinkedDirectoryEntry;
const File = @import("fs").File;

const pathparser = @import("fs").pathparser;
const pmm = @import("mem").pmm; //block size should be the same as the page size
const heap = @import("mem").heap;
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
    if (builtin.is_test) {
        @memset(buffer, 0);
        return;
    }

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
    curr_block_idx: u32 = 0, //0-11 direct blocks, 12-14 indirect blocks
    stack: [3]struct {
        buffer: ?[]u32,
        idx: u32,
    },

    pub fn init(allocator: std.mem.Allocator, ext2: *const Ext2, inode: *const Inode) Self {
        return .{
            .alloctr = allocator,
            .ext2 = ext2,
            .inode = inode,
            .stack = .{
                .{ .buffer = null, .idx = 0 }, //TODO: can't use array multiplication operator
                .{ .buffer = null, .idx = 0 },
                .{ .buffer = null, .idx = 0 },
            },
        };
    }

    pub fn deinit(self: *InodeBlockIterator) void {
        for (self.stack) |stack| {
            if (stack.buffer != null) {
                self.alloctr.free(stack.buffer);
            }
        }
    }

    pub fn next(self: *Self) !?u32 {
        // Handle direct blocks (0-11)
        if (self.curr_block_idx < 12) {
            defer self.curr_block_idx += 1;
            const res = self.inode.block[self.curr_block_idx];
            return if (res == 0) null else res;
        }

        // Handle indirect blocks (12-14)
        return switch (self.curr_block_idx) {
            12 => try self.processIndirectBlockLevel(0), // single indirect
            13 => try self.processIndirectBlockLevel(1), // double indirect
            14 => try self.processIndirectBlockLevel(2), // triple indirect
            else => null,
        };
    }

    fn processIndirectBlockLevel(self: *Self, comptime level: u8) !?u32 {
        // Initialize the highest level buffer if needed
        if (self.stack[level].buffer == null) {
            self.stack[level].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
            try readBlock(self.ext2, self.inode.block[12 + level], std.mem.sliceAsBytes(self.stack[level].buffer.?));
            self.stack[level].idx = 0;
        }

        // Check if we've exhausted the highest level buffer
        if (self.stack[level].idx >= self.stack[level].buffer.?.len) {
            self.curr_block_idx += 1;
            return null;
        }

        // Process intermediate levels
        comptime var i = 0;
        inline while (i < level) : (i += 1) {
            const curr_level = level - i - 1;

            // Initialize or refresh lower level buffers when needed
            if (self.stack[curr_level].buffer == null or self.stack[curr_level].idx >= self.stack[curr_level].buffer.?.len) {
                if (self.stack[curr_level].buffer == null) {
                    self.stack[curr_level].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
                }
                try readBlock(self.ext2, self.stack[curr_level].buffer.?[self.stack[curr_level].idx], std.mem.sliceAsBytes(self.stack[curr_level].buffer.?));
                self.stack[curr_level].idx = 0;
                self.stack[curr_level + 1].idx += 1;
            }
        }

        // Return the next block number from the lowest level
        defer self.stack[0].idx += 1;
        const res = self.stack[0].buffer.?[self.stack[0].idx];
        return if (res == 0) null else res;
    }

    // pub fn next(self: *Self) !?u32 {
    //     // Direct blocks (0-11)
    //     if (self.curr_block_idx < 12) {
    //         defer self.curr_block_idx += 1;
    //         const res = self.inode.block[self.curr_block_idx];
    //         return if (res == 0) null else res;
    //     }
    //
    //     // Indirect blocks (12-14)
    //     switch (self.curr_block_idx) {
    //         12 => return try self.processIndirectBlock(),
    //         13 => return try self.processDoubleIndirectBlock(),
    //         14 => return try self.processTripleIndirectBlock(),
    //         else => return null,
    //     }
    // }
    //
    // fn processIndirectBlock(self: *Self) !?u32 {
    //     if (self.stack[0].buffer == null) {
    //         self.stack[0].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
    //         try readBlock(self.ext2, self.inode.block[12], std.mem.sliceAsBytes(self.stack[0].buffer.?));
    //         self.stack[0].idx = 0;
    //     }
    //
    //     if (self.stack[0].idx >= self.stack[0].buffer.?.len) {
    //         self.curr_block_idx += 1;
    //         return null;
    //     }
    //
    //     defer self.stack[0].idx += 1;
    //     const res = self.stack[0].buffer.?[self.stack[0].idx];
    //     return if (res == 0) null else res;
    // }
    //
    // fn processDoubleIndirectBlock(self: *Self) !?u32 {
    //     if (self.stack[1].buffer == null) {
    //         self.stack[1].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
    //         try readBlock(self.ext2, self.inode.block[13], std.mem.sliceAsBytes(self.stack[1].buffer.?));
    //         self.stack[1].idx = 0;
    //     }
    //
    //     if (self.stack[1].idx >= self.stack[1].buffer.?.len) {
    //         self.curr_block_idx += 1;
    //         return null;
    //     }
    //
    //     if (self.stack[0].buffer == null or self.stack[0].idx >= self.stack[0].buffer.?.len) {
    //         if (self.stack[0].buffer == null) {
    //             self.stack[0].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
    //         }
    //         try readBlock(self.ext2, self.stack[0].buffer.?[self.stack[0].idx], std.mem.sliceAsBytes(self.stack[0].buffer.?));
    //         self.stack[0].idx = 0;
    //         self.stack[1].idx += 1;
    //     }
    //
    //     defer self.stack[0].idx += 1;
    //     const res = self.stack[0].buffer.?[self.stack[0].idx];
    //     return if (res == 0) null else res;
    // }
    //
    // fn processTripleIndirectBlock(self: *Self) !?u32 {
    //     if (self.stack[2].buffer == null) {
    //         self.stack[2].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
    //         try readBlock(self.ext2, self.inode.block[14], std.mem.sliceAsBytes(self.stack[2].buffer.?));
    //         self.stack[2].idx = 0;
    //     }
    //
    //     if (self.stack[2].idx >= self.stack[2].buffer.?.len) {
    //         self.curr_block_idx += 1;
    //         return null;
    //     }
    //
    //     if (self.stack[1].buffer == null or self.stack[1].idx >= self.stack[1].buffer.?.len) {
    //         if (self.stack[1].buffer == null) {
    //             self.stack[1].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
    //         }
    //         try readBlock(self.ext2, self.stack[1].buffer.?[self.stack[1].idx], std.mem.sliceAsBytes(self.stack[1].buffer.?));
    //         self.stack[1].idx = 0;
    //         self.stack[2].idx += 1;
    //     }
    //
    //     if (self.stack[0].buffer == null or self.stack[0].idx >= self.stack[0].buffer.?.len) {
    //         if (self.stack[0].buffer == null) {
    //             self.stack[0].buffer = try self.alloctr.alloc(u32, self.ext2.superblock.getBlockSize() / 4);
    //         }
    //         try readBlock(self.ext2, self.stack[0].buffer.?[self.stack[0].idx], std.mem.sliceAsBytes(self.stack[0].buffer.?));
    //         self.stack[0].idx = 0;
    //         self.stack[1].idx += 1;
    //     }
    //
    //     defer self.stack[0].idx += 1;
    //     const res = self.stack[0].buffer.?[self.stack[0].idx];
    //     return if (res == 0) null else res;
    // }
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

// test
test "ext2_a" {}
