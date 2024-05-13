const std = @import("std");
const dpl = @import("dpl.zig");
const cpu = @import("cpu.zig");
const testing = @import("testing");

const log = std.log.scoped(.idt);

const total_interrupts = 512;

const pic_master_cmd_port = 0x20;
const pic_master_data_port = 0x21;
const pic_slave_cmd_port = 0xA0;
const pic_slave_data_port = 0xA1;

const pic_init_command = 0b0001_0001;
const pic_end_of_init = 0b0000_0001;
const pic_master_irq_start = 0x20; //0-0x1F for the exceptions
const pic_slave_irq_start = 0x28;

fn remapPIC(cmd_port: u16, data_port: u16, irq_start: u8) void {
    cpu.outb(cmd_port, pic_init_command); //send the init command
    cpu.outb(data_port, irq_start); //set start of irq  (0 for the master, 8 for the slave) at irq_start
    cpu.outb(data_port, pic_end_of_init);
}

pub const Exception = struct {
    id: u8,
    mnemonic: []const u8,
    type: Type,
    description: []const u8,

    const Type = enum(u2) {
        fault,
        trap,
        abort,
        };
};

const et = [_]Exception{
    .{.id = 0x0 , .mnemonic = "#DE",  .type = .fault, .description = "Divide Error"},
    .{.id = 0x1 , .mnemonic = "#DB",  .type = .fault, .description = "Debug Exception"},
    .{.id  = 0x3, .mnemonic = "#BP",  .type = .trap, .description = "Breakpoint"},
    .{.id  = 0x4, .mnemonic = "#OF",  .type = .trap, .description = "Overflow"},
    .{.id  = 0x5, .mnemonic = "#BR",  .type = .fault, .description = "Bound Range Exceeded"},
    .{.id  = 0x6, .mnemonic = "#UD",  .type = .fault, .description = "Invalid Opcode"},
    .{.id  = 0x7, .mnemonic = "#NM",  .type = .fault, .description = "Device Not Available"},
    .{.id  = 0x8, .mnemonic = "#DF",  .type = .abort, .description = "Double Fault"},
    .{.id  = 0xA, .mnemonic = "#TS",  .type = .fault, .description = "Invalid TSS"},
    .{.id  = 0xB, .mnemonic = "#NP",  .type = .fault, .description = "Segment Not Present"},
    .{.id  = 0xC, .mnemonic = "#SS",  .type = .fault, .description = "Stack-Segment Fault"},
    .{.id  = 0xD, .mnemonic = "#GP",  .type = .fault, .description = "General Protection"},
    .{.id  = 0xE, .mnemonic = "#PF",  .type = .fault, .description = "Page Fault"},
    .{.id  = 0x10, .mnemonic = "#MF",  .type = .fault, .description = "x87 FPU Floating-Point Error"},
    .{.id  = 0x11, .mnemonic = "#AC",  .type = .fault, .description = "Alignment Check"},
    .{.id  = 0x12, .mnemonic = "#MC",  .type = .abort, .description = "Machine Check"},
    .{.id  = 0x13, .mnemonic = "#XM",  .type = .fault, .description = "SIMD Floating-Point Exception"},
    .{.id  = 0x14, .mnemonic = "#VE",  .type = .fault, .description = "Virtualization Exception"},
    .{.id  = 0x1E, .mnemonic = "#CP",  .type = .fault, .description = "Control Protection Exception"},
    .{.id = 0x1C, .mnemonic = "#HV",  .type = .fault, .description = "Hypervisor Injection Exception"},
    .{.id = 0x1D, .mnemonic = "#VP",  .type = .fault, .description = "VMM Communication Exception"},
    .{.id = 0x1E, .mnemonic = "#SX",  .type = .fault, .description = "Security Exception"},
};

const IdtEntry = packed struct(u128) {
    const Self = @This();
    offset_low: u16,
    segment_selector: u16,
    interrupt_stack_table: u3,
    reserved_a: u5 = 0,
    gate_type: GateType,
    reserved_b: u1 = 0,
    privilege: dpl.PrivilegeLevel,
    present: bool,
    offset_high: u48,
    reserved_c: u32 = 0,

    const GateType = enum(u4) {
        interrupt_gate = 0b1110,
        trap_gate = 0b1111,
    };

    pub fn setOffset(self: *Self, offset: u64) void {
        self.offset_low = @truncate(offset);
        self.offset_high = @truncate(offset >> 16);
    }

    pub fn getOffset(self: *Self) u64 {
        return @as(u64, self.offset_high) << 16 | self.offset_low;
    }

    test "get and set offset" {
        var entry = IdtEntry{};
        entry.setOffset(0x12345678);
        testing.expect(entry.getOffset() == 0x12345678);
    }
};

pub const Idt = [total_interrupts]IdtEntry;

var idt: Idt = [_]IdtEntry{.{
    .offset_low = 0,
    .segment_selector = 0,
    .interrupt_stack_table = 0,
    .gate_type = .interrupt_gate,
    .privilege = .ring0,
    .present = false,
    .offset_high = 0,
}} ** total_interrupts;

pub const Idtd = packed struct(u80) {
    size: u16, //0-15
    offset: u64, //16-80
};

var idtd: Idtd = .{
    .size = @sizeOf(Idt) - 1,
    .offset = undefined,
};

pub fn init() void {
    log.info("Initializing IDT", .{});
    defer log.info("IDT initialized", .{});
    remapPIC(pic_master_cmd_port, pic_master_data_port, pic_master_irq_start); // Remap master PIC (0-7)
    remapPIC(pic_slave_cmd_port, pic_slave_data_port, pic_slave_irq_start); // Remap slave PIC (7-15)

    idtd.offset = @intFromPtr(&idt);

    cpu.lidt(&idtd);
}
