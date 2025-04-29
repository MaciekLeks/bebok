const std = @import("std");
const config = @import("config");
const gdt = @import("gdt.zig");

const Tss = @This();

const kernel_stack_size = config.kernel_stack_size;

//Fields
alloctr: std.mem.Allocator,
tss: TaskStateSegment = undefined,
stack: []u8 = undefined,

pub const TaskStateSegment = packed struct(u832) {
    rsrvd_a: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    rsvd_b: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    rsvd_c: u80 = 0,
    iopb_offset: u16 = 0,
};

pub fn new(allocator: std.mem.Allocator) !*Tss {
    const self = try allocator.create(Tss);

    self.alloctr = allocator;
    self.stack = try allocator.alloc(u8, kernel_stack_size);

    self.tss.rsp0 = @intFromPtr(&self.stack[self.stack.len - 1]);
    self.tss.ist1 = @intFromPtr(&self.stack[self.stack.len - 1]);

    return self;
}

pub fn init(self: *const Tss) void {
    gdt.setTss(&self.tss);
}

pub fn destroy(self: *Tss) void {
    self.alloctr.free(self.stack);
    self.alloctr.destroy(self);
}
