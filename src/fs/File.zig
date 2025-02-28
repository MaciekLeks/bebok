const std = @import("std");
const Node = @import("Node.zig");

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
    owner: SingleMode,
    group: SingleMode,
    other: SingleMode,
    rsrvd: u7 = 0, //padding
};

pub const Error = error{
    NotFound,
    MaxFDsReached,
    FileStillInUse,
};
pub const max_name_len = 256;

//TODO:
//dentry: *const DEntry, //TODO: DEntry needed
alloctr: std.mem.Allocator,
offset: usize, //file read/write offset
count: u32, //reference count by subprocesses
flags: Flags,
mode: Mode,
node: Node,

pub fn new(allocator: std.mem.Allocator, node: *const Node, flags: Flags, mode: Mode) !*Self {
    const self = try allocator.create(Self);

    self.* = .{
        .alloctr = allocator,
        .offset = 0,
        .flags = flags,
        .mode = mode,
        .node = node,
        .count = 1,
    };

    return self;
}

pub fn destroy(self: *const Self) !void {
    if (self.count > 1) return error.FileStillInUse;
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
