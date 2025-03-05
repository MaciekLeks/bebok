const std = @import("std");
const lang = @import("lang");
const iface = lang.iface;
const Iterator = lang.iter.Iterator;

const File = @import("File.zig");
const NodeNum = @import("types.zig").NodeNum;
const PageNum = @import("types.zig").PageNum;

const Node = @This();

pub const VTable = struct {
    destroy: iface.Fn(.{}, void),
    //create: iface.Fn(.{}, void),
    readPage: iface.Fn(.{ PageNum, []u8 }, anyerror!void),
    getPageIter: iface.Fn(.{ std.mem.Allocator, Node }, anyerror!Iterator(NodeNum)),
    getFileSize: iface.Fn(.{Node}, ?usize),
};

//Regular Fields
ctx: *anyopaque, //points to the filesystem implementation
vtable: *const VTable,
// Quick access fields
node_num: NodeNum, //For Ext2 is inode number
//Data Fields
data: *anyopaque,

pub fn init(ctx: anytype, node_num: NodeNum, data: *anyopaque) Node {
    return .{
        .ctx = ctx,
        .vtable = iface.gen(@TypeOf(ctx), VTable),
        .node_num = node_num,
        .data = data,
    };
}

pub fn deinit(self: Node) void {
    self.vtable.destroy(self.ctx, .{});
}

// pub fn readIter(self: *const Self, allocator: std.mem.Allocator) !ReadIterator {
//     return self.vtable.readIter(self.ctx, allocator);
// }

pub fn getPageIter(self: Node, allocator: std.mem.Allocator) !Iterator(NodeNum) {
    return self.vtable.getPageIter(self.ctx, .{ allocator, self });
}

pub fn getFileSize(self: Node) ?usize {
    return self.vtable.getFileSize(self.ctx, .{self});
}

pub fn readPage(self: Node, pg_num: PageNum, buf: []u8) anyerror!void {
    return self.vtable.readPage(self.ctx, .{ pg_num, buf });
}
