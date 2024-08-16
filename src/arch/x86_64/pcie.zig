const std = @import("std");

const log = std.log.scoped(.pcie_x86_64);

// Intel specific MSI/MSI-X registers

pub const MsiMessageAddressRegister = packed struct(u32) {
    xx: u2 = 0, //0-2 bits
    destination_mode: u1, //3-bit
    redirection_hint: u1, // 4-bit
    rsrvd: u8 = 0, //4-11 bits
    destination_id: u8, //12-19 bits
    base_address: u12 = 0xFEE, //20-32 bits
};

// see Processor's Manual Volume 3A: 10.11.2 MSI Message Data Register
pub const MsiMessageDataRegister = packed struct(u32) {
    pub const DeliveryMode = enum(u3) {
        fixed = 0b000,
        lowest_priority = 0b001,
        smi = 0b010,
        nmi = 0b100,
        init = 0b101,
        ext_int = 0b111,
    };

    pub const TriggerMode = enum(u1) {
        edge = 0b0,
        level = 0x1,
    };

    vec_no: u8, //0-7 bits
    delivery_mode: DeliveryMode, //8-10 bits
    rsrvd_a: u3 = 0, // 11-13 bits reserved
    level: u1, //14-bit
    trigger_mode: TriggerMode, //15 bit
    rsrvd_b: u16 = 0, //16-31 bits
};
