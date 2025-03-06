const std = @import("std");

const lang = @import("lang");
const iface = lang.iface;
const Iterator = lang.iter.Iterator;

const Node = @import("Node.zig");
const NodeNum = @import("types.zig").NodeNum;
const PageNum = @import("types.zig").PageNum;
const Filesystem = @import("Filesystem.zig");

const heap = @import("mem").heap;

const Self = @This();

pub const Flags = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    rsrvd: u6 = 0,
};

pub const Mode = packed struct(u16) {
    const SingleMode = packed struct(u3) {
        read: bool = false,
        write: bool = false,
        execute: bool = false,
    };
    owner: SingleMode = .{},
    group: SingleMode = .{},
    other: SingleMode = .{},
    rsrvd: u7 = 0, //padding
};

pub const Error = error{
    NotFound,
    MaxFDsReached,
    StillInUse,
    NotRegularFile,
    SeekPastEnd,
};

pub const SeekWhence = enum { set, cur, end };

pub const max_name_len = 256;

//TODO:
//dentry: *const DEntry, //TODO: DEntry needed
alloctr: std.mem.Allocator,
fs: Filesystem, //filesystem instance the file belongs to
offset: usize, //file read/write offset
count: u32, //reference count by subprocesses
flags: Flags,
mode: Mode,
node: Node,

file_size: ?usize = undefined, //null if not a regular file
page_iter: Iterator(NodeNum) = undefined,
page_buffer: []u8 = undefined,
page_buffer_pos: usize = 0,
bytes_read: usize = 0,

pub fn new(allocator: std.mem.Allocator, fs: Filesystem, node: Node, flags: Flags, mode: Mode) !*Self {
    const self = try allocator.create(Self);

    self.* = .{
        .alloctr = allocator,
        .fs = fs,
        .offset = 0,
        .flags = flags,
        .mode = mode,
        .node = node,
        .count = 1,
        //
        .file_size = node.getFileSize(),
        .page_iter = try node.getPageIter(allocator),
        .page_buffer = try allocator.alloc(u8, fs.getPageSize()),
    };

    return self;
}

pub fn destroy(self: *const Self) !void {
    if (self.count > 1) return Error.StillInUse;
    self.alloctr.free(self.page_buffer);
    self.page_iter.deinit();
    self.alloctr.free(self.page_buffer);
    self.alloctr.destroy(self);
}

pub fn incrementRefCount(self: *Self) void {
    self.count += 1;
}

pub fn decrementRefCount(self: *Self) void {
    if (self.count > 0) {
        self.count -= 1;
    }
}

pub fn read(self: *Self, buffer: []u8) !usize {
    if (self.file_size == null) return Error.NotRegularFile;

    // If we've read the entire file, return 0
    if (self.bytes_read >= self.file_size.?) {
        return 0;
    }

    const bytes_to_read = @min(buffer.len, self.file_size.? - self.bytes_read);
    var bytes_read: usize = 0;

    while (bytes_read < bytes_to_read) {
        // If we've consumed the current block buffer, load the next block
        if (self.page_buffer_pos == 0 or self.page_buffer_pos >= self.page_buffer.len) {
            if (try self.page_iter.next()) |pg_num| {
                try self.node.readPage(pg_num, self.page_buffer);
                self.page_buffer_pos = 0;
            } else {
                // No more blocks to read
                break;
            }
        }

        // Calculate how many bytes we can copy from the current block
        const remaining_in_buffer = self.page_buffer.len - self.page_buffer_pos;
        const remaining_to_read = bytes_to_read - bytes_read;
        const copy_size = @min(remaining_in_buffer, remaining_to_read);

        // Copy data from block buffer to output buffer
        @memcpy(buffer[bytes_read..(bytes_read + copy_size)], self.page_buffer[self.page_buffer_pos..(self.page_buffer_pos + copy_size)]);

        // Update positions
        bytes_read += copy_size;
        self.page_buffer_pos += copy_size;
        self.bytes_read += copy_size;

        // If we've read the entire file, break
        if (self.bytes_read >= self.file_size.?) {
            break;
        }
    }

    return bytes_read;
}

/// Seek to a specific position
/// TODO:
/// - upon modified node iterator set offset as a node iterator start offset
fn seek(self: *Self, offset: usize) !void {
    // Reset the iterator if we're seeking from the beginning
    if (offset < self.bytes_read) {
        // Reset and start from the beginning
        self.page_iter.deinit();
        self.page_iter = try self.node.getPageIter(self.alloctr);
        self.bytes_read = 0;
    }

    // Skip ahead to the desired position
    if (offset > self.bytes_read) {
        var arena = std.heap.ArenaAllocator.init(heap.page_allocator);
        defer arena.deinit();
        const alloctr = arena.allocator();

        const skip_buffer = try alloctr.alloc(u8, self.page_buffer.len);
        var remaining = offset - self.bytes_read;

        while (remaining > 0) {
            const to_skip = @min(remaining, skip_buffer.len);
            const skipped = try self.read(skip_buffer[0..to_skip]);
            if (skipped == 0) {
                // Reached end of file before desired position
                return Error.SeekPastEnd;
            }
            remaining -= skipped;
        }
    }
}

pub fn lseek(self: *Self, offset: isize, whence: SeekWhence) !usize {
    var pos = self.offset;
    switch (whence) {
        .set => pos = @intCast(offset),
        .cur => pos += @intCast(offset),
        .end => pos = self.file_size.? + @as(usize, @intCast(offset)),
    }

    try self.seek(pos);

    self.offset = pos;
    return self.offset;
}
