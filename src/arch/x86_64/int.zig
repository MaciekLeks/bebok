const std = @import("std");
const dpl = @import("dpl.zig");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const testing = @import("testing");

const log = std.log.scoped(.init_x86_64);

//pub const VectorIndex = u9;
const total_interrupts = 512;
const total_exceptions = 0x1F;
const total_irqs = 0x10;

const pic_master_cmd_port = 0x20;
const pic_master_data_port = 0x21;
const pic_slave_cmd_port = 0xA0;
const pic_slave_data_port = 0xA1;
const pic_eoi = 0x20;

const pic_init_command = 0b0001_0001;
const pic_end_of_init = 0b0000_0001;
const pic_master_irq_start = 0x20; //0-0x1F for the exceptions
const pic_slave_irq_start = 0x28;

pub const ISRError = error{
    UnknownError,
};

pub const VectorIndex = u9;
const HandleFn = fn () callconv(.Interrupt) void;
const ISRHandleLoopFn = *const fn (vec_no: VectorIndex) ISRError!void;
pub const IH = fn (vec_no: VectorIndex) void;

// fn remapPIC(cmd_port: u16, data_port: u16, irq_start: u8) void {
//     cpu.outb(cmd_port, pic_init_command); //send the init command
//     cpu.outb(data_port, irq_start); //set start of irq  (0 for the master, 8 for the slave) at irq_start
//     cpu.outb(data_port, pic_end_of_init);
// }

// pub fn disablePIC() void {
//     // Mask all interrupts
//     cpu.outb(pic_master_data_port, 0xFF);
//     cpu.outb(pic_slave_data_port, 0xFF);
// }
fn disablePIC() void {
    // Mask all interrupts on Master PIC
    cpu.outb(pic_master_data_port, 0xFF);

    // Mask all interrupts on Slave PIC
    cpu.outb(pic_slave_data_port, 0xFF);

    // ICW1: Initialize PIC
    cpu.outb(pic_master_cmd_port, pic_init_command); // Start initialization sequence for Master PIC
    cpu.outb(pic_slave_cmd_port, pic_init_command); // Start initialization sequence for Slave PIC

    // ICW2: Set vector offset
    cpu.outb(pic_master_data_port, pic_master_irq_start); // Master PIC vector offset
    cpu.outb(pic_slave_data_port, pic_slave_irq_start); // Slave PIC vector offset

    // ICW3: Configure cascading
    cpu.outb(pic_master_data_port, 0x04); // Master PIC has a Slave at IRQ2
    cpu.outb(pic_slave_data_port, 0x02); // Slave PIC ID = 2

    // ICW4: Set additional settings
    cpu.outb(pic_master_data_port, pic_end_of_init); // 8086/88 mode
    cpu.outb(pic_slave_data_port, pic_end_of_init); // 8086/88 mode

    // Mask all interrupts on Master PIC and Slave PIC
    cpu.outb(pic_master_data_port, 0xFF);
    cpu.outb(pic_slave_data_port, 0xFF);
}

pub const Exception = struct {
    vec_no: u5, //0-0x1F
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
    .{ .vec_no = 0x0, .mnemonic = "#DE", .type = .fault, .description = "Division Error" },
    .{ .vec_no = 0x1, .mnemonic = "#DB", .type = .fault, .description = "Debug Exception" },
    .{ .vec_no = 0x3, .mnemonic = "#BP", .type = .trap, .description = "Breakpoint" },
    .{ .vec_no = 0x4, .mnemonic = "#OF", .type = .trap, .description = "Overflow" },
    .{ .vec_no = 0x5, .mnemonic = "#BR", .type = .fault, .description = "Bound Range Exceeded" },
    .{ .vec_no = 0x6, .mnemonic = "#UD", .type = .fault, .description = "Invalid Opcode" },
    .{ .vec_no = 0x7, .mnemonic = "#NM", .type = .fault, .description = "Device Not Available" },
    .{ .vec_no = 0x8, .mnemonic = "#DF", .type = .abort, .description = "Double Fault" },
    .{ .vec_no = 0xA, .mnemonic = "#TS", .type = .fault, .description = "Invalid TSS" },
    .{ .vec_no = 0xB, .mnemonic = "#NP", .type = .fault, .description = "Segment Not Present" },
    .{ .vec_no = 0xC, .mnemonic = "#SS", .type = .fault, .description = "Stack-Segment Fault" },
    .{ .vec_no = 0xD, .mnemonic = "#GP", .type = .fault, .description = "General Protection" },
    .{ .vec_no = 0xE, .mnemonic = "#PF", .type = .fault, .description = "Page Fault" },
    .{ .vec_no = 0x10, .mnemonic = "#MF", .type = .fault, .description = "x87 FPU Floating-Point Error" },
    .{ .vec_no = 0x11, .mnemonic = "#AC", .type = .fault, .description = "Alignment Check" },
    .{ .vec_no = 0x12, .mnemonic = "#MC", .type = .abort, .description = "Machine Check" },
    .{ .vec_no = 0x13, .mnemonic = "#XM", .type = .fault, .description = "SIMD Floating-Point Exception" },
    .{ .vec_no = 0x14, .mnemonic = "#VE", .type = .fault, .description = "Virtualization Exception" },
    .{ .vec_no = 0x1E, .mnemonic = "#CP", .type = .fault, .description = "Control Protection Exception" },
    .{ .vec_no = 0x1C, .mnemonic = "#HV", .type = .fault, .description = "Hypervisor Injection Exception" },
    .{ .vec_no = 0x1D, .mnemonic = "#VP", .type = .fault, .description = "VMM Communication Exception" },
    .{ .vec_no = 0x1E, .mnemonic = "#SX", .type = .fault, .description = "Security Exception" },
};

const IdtEntry = packed struct(u128) {
    const Self = @This();
    offset_low: u16,
    segment_selector: u16,
    interrupt_stack_table: u3,
    reserved_a: u5 = 0,
    gate_type: GateType,
    reserved_b: u1 = 0,
    ///CPU Privilege Level which are allowed to access this interrupt via the INT instruction. Hardware interrupts ignore this mechanism.
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

fn bindExceptionHandler(comptime idx: u5) HandleFn {
    return struct {
        fn handle() callconv(.Interrupt) void {
            log.err(std.fmt.comptimePrint("Exception: vec_no={d}, mnemonic={s}, description={s}", .{ et[idx].vec_no, et[idx].mnemonic, et[idx].description }), .{});
            cpu.halt();
        }
    }.handle;
}

fn bindIRQHandler(comptime _: u5, comptime _: ?ISRHandleLoopFn, comptime _: bool) HandleFn {
    @compileError("Not implemented");
}

fn bindIRQHandlerWithAck(comptime vec_no: VectorIndex, comptime isr_handle_loop_fn: ?ISRHandleLoopFn, comptime logging: bool) HandleFn {
    return struct {
        fn handle() callconv(.Interrupt) void {
            if (logging) log.debug(std.fmt.comptimePrint("Interrupt: IRQ 0x{x}", .{vec_no}), .{});
            if (isr_handle_loop_fn) |isr| isr(vec_no) catch |err| {
                log.err("Error handling interrupt: vec_no=0x{x}, error={}", .{ vec_no, err });
            };
            if (vec_no >= pic_slave_irq_start) cpu.out(u8, pic_slave_cmd_port, pic_eoi) else cpu.out(u8, pic_master_cmd_port, pic_eoi);
        }
    }.handle;
}

fn setIdtEntry(comptime idx: VectorIndex, handle: HandleFn, gate_type: IdtEntry.GateType, privilege: dpl.PrivilegeLevel, present: bool) void {
    idt[idx].setOffset(@intFromPtr(&handle));
    idt[idx].segment_selector = gdt.segment_selectors.kernel_code_x64;
    idt[idx].interrupt_stack_table = 0;
    idt[idx].gate_type = gate_type;
    idt[idx].privilege = privilege;
    idt[idx].present = present;
}

fn setDefaultInterruptEntry(comptime vec_no: VectorIndex, comptime isr_handle_loop_fn: ISRHandleLoopFn, comptime logging: bool) void {
    setIdtEntry(vec_no, bindIRQHandlerWithAck(vec_no, isr_handle_loop_fn, logging), IdtEntry.GateType.interrupt_gate, dpl.PrivilegeLevel.ring0, true);
}

fn setDefaultExceptionEntry(comptime idx: u5, comptime gate_type: IdtEntry.GateType) void {
    setIdtEntry(idx, bindExceptionHandler(idx), gate_type, dpl.PrivilegeLevel.ring0, true);
}

fn setEmptyInterruptEntry(comptime idx: VectorIndex) void {
    setIdtEntry(idx, 0, IdtEntry.GateType.interrupt_gate, dpl.PrivilegeLevel.ring0, false);
}

pub fn init(comptime isr_handle_loop_fn: ISRHandleLoopFn) void {
    log.info("Initializing interrupts handling", .{});
    defer log.info("Interrupts handling initialized", .{});

    // Remap IRQs to 0x20->0x2F
    //remapPIC(pic_master_cmd_port, pic_master_data_port, pic_master_irq_start); // Remap master PIC (0-7)
    //remapPIC(pic_slave_cmd_port, pic_slave_data_port, pic_slave_irq_start); // Remap slave PIC (7-15)
    disablePIC();

    // Update the IDT with the exceptions: 0x0->0x1F
    inline for (0..total_exceptions) |i| {
        switch (i) {
            0x02, 0x09, 0x15, 0x16...0x1B, 0x1F => |ei| {
                setDefaultInterruptEntry(ei, isr_handle_loop_fn, true);
                // idt[ei].setOffset(@intFromPtr(&interruptFnBind(ei)));
                // idt[ei].segment_selector = gdt.segment_selectors.kernel_code_x64;
                // idt[ei].interrupt_stack_table = 0;
                // idt[ei].gate_type = IdtEntry.GateType.interrupt_gate;
                // idt[ei].privilege = dpl.PrivilegeLevel.ring0;
                // idt[ei].present = true;
            },
            else => {},
        }
    }
    inline for (et, 0..) |e, idx| {
        setDefaultExceptionEntry(idx, if (e.type == Exception.Type.fault) IdtEntry.GateType.interrupt_gate else IdtEntry.GateType.trap_gate);

        // idt[e.vec_no].setOffset(@intFromPtr(&exceptionFnBind(i)));
        // idt[e.vec_no].segment_selector = gdt.segment_selectors.kernel_code_x64;
        // idt[e.vec_no].interrupt_stack_table = 0;
        // idt[e.vec_no].gate_type = if (e.type == Exception.Type.fault) IdtEntry.GateType.interrupt_gate else IdtEntry.GateType.trap_gate; //TODO ?
        // idt[e.vec_no].privilege = dpl.PrivilegeLevel.ring0;
        // idt[e.vec_no].present = true;
    }

    // PIC IRQs
    inline for (0..total_irqs) |i| {
        //change code to use set
        setDefaultInterruptEntry(pic_master_irq_start + i, isr_handle_loop_fn, false);

        // idt[pic_master_irq_start + i].segment_selector = gdt.segment_selectors.kernel_code_x64;
        // idt[pic_master_irq_start + i].interrupt_stack_table = 0;
        // idt[pic_master_irq_start + i].gate_type = IdtEntry.GateType.interrupt_gate;
        // idt[pic_master_irq_start + i].privilege = dpl.PrivilegeLevel.ring3;
        // idt[pic_master_irq_start + i].present = true;
        // switch (i) {
        //     1, 0xa => { //TODO: 0xa -> PCI - write function to set handler from outside this file
        //         idt[pic_master_irq_start + i].setOffset(@intFromPtr(&interruptWithAckowledgeFnBind(i, null, true)));
        //     },
        //     else => {
        //         idt[pic_master_irq_start + i].setOffset(@intFromPtr(&interruptWithAckowledgeFnBind(i, null,false)));
        //     },
        // }

        // change above code to use set

        // Softwares interrupts
        //TODO: add

    }

    idtd.offset = @intFromPtr(&idt);
    cpu.lidt(&idtd);
}

//-------------------------------------------- helper functions --------------------------------------------

pub fn isIRQMasked(comptime irq: u8) bool {
    if (irq < 8) {
        return cpu.inb(pic_master_data_port) & (1 << irq) != 0;
    } else {
        return cpu.inb(pic_slave_data_port) & (1 << (irq - 8)) != 0;
    }
}

pub fn triggerInterrupt(comptime vec_no: VectorIndex) void {
    cpu.int(@intCast(vec_no));
}
