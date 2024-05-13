const std = @import("std");
const dpl = @import("dpl.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.idt);

const total_interrupts = 512;

const pic_master_cmd_port = 0x20;
const pic_master_data_port = 0x21;
const pic_slave_cmd_port = 0xA0;
const pic_slave_data_port = 0xA1;

const pic_init_command = 0b0001_0001;
const pic_end_of_init = 0b0000_0001;
const pic_master_irq_start = 0x20;
const pic_slave_irq_start = 0x28;

fn remapPIC(cmd_port: u16, data_port: u16, irq_start: u8) void {
    cpu.outb(cmd_port, pic_init_command); //send the init command
    cpu.outb(data_port, irq_start); //set start of irq  (0 for the master, 8 for the slave) at irq_start
    cpu.outb(data_port, pic_end_of_init);
}

const IdtEntry = packed struct(u128) {
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
