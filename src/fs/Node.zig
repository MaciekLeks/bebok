const iface = @import("lang").iface;

const Self = @This();

pub const NodeNum = u32;

pub const VTable = struct {
    destroy: iface.Fn(.{}, void),
    //create: iface.Fn(.{}, void),
};

//Regular Fields
ctx: *anyopaque,
vtable: *const VTable,
// Quick access fields
node_num: NodeNum, //For Ext2 is inode number
//Data Fields
data: *anyopaque,

pub fn init(ctx: anytype, node_num: NodeNum, data: *anyopaque) Self {
    return .{
        .ctx = ctx,
        .vtable = iface.gen(@TypeOf(ctx), VTable),
        .node_num = node_num,
        .data = data,
    };
}

pub fn deinit(self: *const Self) void {
    self.vtable.destroy(self.ctx);
}
