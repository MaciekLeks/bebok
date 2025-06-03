const std = @import("std");
const config = @import("config");
const gdt = @import("gdt.zig");

const Tss = @This();

//Fields
alloctr: std.mem.Allocator,
tss: TaskStateSegment = undefined,
kernel_stack: []u8 = undefined,
double_fault_stack: []u8 = undefined,

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
    self.kernel_stack = try allocator.alloc(u8, config.kernel_stack_size);
    self.double_fault_stack = try allocator.alloc(u8, config.double_fault_stack_size);

    self.tss.rsp0 = @intFromPtr(&self.kernel_stack[self.kernel_stack.len - 1]);
    self.tss.ist1 = @intFromPtr(&self.double_fault_stack[self.double_fault_stack.len - 1]);

    return self;
}

pub fn init(self: *const Tss) void {
    gdt.setTss(&self.tss);
}

pub fn destroy(self: *Tss) void {
    self.alloctr.free(self.kernel_stack);
    self.alloctr.destroy(self);
}
