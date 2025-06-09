/// Architecure specific context for x86_64 containing
/// // - L5/L4 aligned physical address of the page table base
/// // - PCID
/// // - CPU registers important in context switching
const Self = @This();

// Fields
l4_aligned_phys: u39, // L4 aligned physical address of the page table base, used for fast access
pcid: pcidmod.Id, // PCID for the current context, used to avoid TLB flushes

cs: u64 = 0, // Code segment selector, initialized to user code segment
ds: u64 = 0, // Data segment selector, initialized to user data segment
rip: u64 = 0, // Instruction pointer, initialized to user virtual start
rsp: u64 = 0, // Stack pointer, initialized to user stack top

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .l4_aligned_phys = try paging.createL4(allocator).aligned_phys,
        .pcid = try pcidmod.reserve(),

        .cs = gdt.segment_selector.user_code, // Set to user code segment
        .ds = gdt.segment_selector.user_data, // Set to user data segment

        .rip = config.user_virt_start, // Set to user virtual start
        .rsp = config.user_stack_start, // Set to user stack top
    };
}

pub fn deinit(self: *Self) void {
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
const config = @import("config");
const gdt = @import("gdt.zig");
