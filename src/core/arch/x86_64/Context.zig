/// Architecure specific context for x86_64 containing
/// // - L5/L4 aligned physical address of the page table base
/// // - PCID
/// // - CPU registers important in context switching
const Self = @This();

// Fields
l4_aligned_phys: u39, // L4 aligned physical address of the page table base, used for fast access
pcid: pcidmod.Id, // PCID for the current context, used to avoid TLB flushes

rbx: u64, // used for fast access to the page table base

pub fn new(allocator: std.mem.Allocator) !Self {
    return .{
        .l4_aligned_phys = try paging.createTaskL4(allocator).aligned_phys,
        .pcid = try pcidmod.reserve(),
        .rbx = 0,
    };
}

pub fn destroy(self: *Self) void {
    pcidmod.release(self.pcid);
    //TODO: implement paging cleanup if necessary

}

pub fn switchctx(oldctx: *const Self, newctx: *const Self) void {
    _ = oldctx;
    _ = newctx;
}

//Imports
const std = @import("std");
const pcidmod = @import("pcid.zig");
const paging = @import("paging.zig");
