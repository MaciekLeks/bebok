const dpl = @import("dpl.zig");

const IdtEntry = packed struct(u128) {
    offset_low: u16,
    segment_selector: u16,
    interrupt_stack_table: u3,
    reserved: u5 = 0,
    gate_type: GateType,
    reserved_b: u1 = 0,
    privilege:  dpl.PrivilegeLevel,
    present: bool,
    offset_high: u48,
    reserved_c: u32 = 0,

    const GateType = enum(u4) {
        interrupt_gate = 0b1110,
        trap_gate = 0b1111,
    };
};