const std = @import("std");
const log = std.log.scoped(.driver);

const Partition = @This();

//Fields
alloctr: std.mem.Allocator,
type_guid: ?[16]u8 = null, //GUID
guid: [16]u8, //GUID
slba: u64, //start lba
elba: u64, //end lba
flags: u64,
name: [72]u8,

pub fn init(allocator: std.mem.Allocator) !*Partition {
    var part = try allocator.create(Partition);
    part.alloctr = allocator;

    return part;
}

pub fn deinit(self: *Partition) void {
    defer self.alloctr.destroy(self);
}
