const cmd = @import("command.zig");
const com = @import("../commons.zig");

pub const GetSetFeaturesCommand = packed union {
    const FeatureSelect = enum(u3) {
        current = 0b000,
        default = 0b001,
        saved = 0b010,
        supported_capabilities = 0b011,
    };
    get_number_of_queues: packed struct(u512) {
        cdw0: cmd.AdminCDw0, //cdw0,
        ignrd_a: u32 = 0, //cdw1,
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw4, cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x07, //cdw10 - Feature Identifier
        sel: FeatureSelect, //cdw10 - Select
        rsrv_a: u21 = 0, //11-31 in cdw10 - Reserved
        ignrd_g: u32 = 0, //32-63 in cdw11 - I/O Command Set Combination Index
        ignrd_h: u32 = 0, //48-52 in cdw12
        ignrd_i: u32 = 0, //52-55 in cdw13
        ignrd_j: u32 = 0, //56-59 in cdw14
        ignrd_k: u32 = 0, //60-63 in cdw15
    },
    set_number_of_queues: packed struct(u512) {
        cdw0: cmd.AdminCDw0, //cdw0,
        ignrd_a: u32 = 0, //cdw1,
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw4, cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw10
        fid: u8 = 0x07, //cdw10 - Feature Identifier
        rsrvd_a: u24 = 0, //cdw10
        ncqr: u16, //cdw11 - I/O Command Set Combination Index
        nsqr: u16 = 0, // cdw11
        ignrd_g: u32 = 0, //cdw12
        ignrd_h: u32 = 0, //cdw13
        ignrd_i: u32 = 0, //cdw14
        ignrd_j: u32 = 0, //cdw15
    },
    set_io_command_profile: packed struct(u512) {
        cdw0: cmd.AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw5
        dptr: com.DataPointer, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x19, //cdw10 - Feature Identifier
        rsrv_a: u23 = 0, //cdw10
        sv: u1, //cdw10 - Save
        iosci: u9, //cdw11 - I/O Command Set Combination Index
        rsrvd_b: u23 = 0, //cdw11
        ignrd_f: u32 = 0, //cdw12
        ignrd_g: u32 = 0, //cdw13
        uuid: u7 = 0, //cdw14 - UUID
        rsrvd_c: u25 = 0, //cdw14
        ignrd_h: u32 = 0, //cdw15
    },
    get_interrupt_coalescing: packed struct(u512) {
        cdw0: cmd.AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x08, //cdw10 - Feature Identifier
        sel: FeatureSelect, //cdw10 - Select
        rsrv_a: u21 = 0, //cdw10
        ignrd_g: u32 = 0, //cdw11
        ignrd_h: u32 = 0, //cdw12
        ignrd_i: u32 = 0, //cdw13
        ignrd_j: u32 = 0, //cdw14
        ignrd_k: u32 = 0, //cdw15
    },
    SetInterruptCoalescing: packed struct(u512) {
        cdw0: cmd.AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //cdw5
        ignrd_f: u128 = 0, //cdw6, cdw7, cdw8,cdw9
        fid: u8 = 0x08, //cdw10 - Feature Identifier
        rsrv_a: u24 = 0, //cdw10
        thr: u8, //cdw11 - Aggregation Threshold
        time: u8, //cdw11 - Aggregation Time
        rsrv_b: u16 = 0, //cdw11
        ignrd_g: u32 = 0, //cdw12
        ignrd_h: u32 = 0, //cdw13
        ignrd_i: u32 = 0, //cdw14
        ignrd_j: u32 = 0, //cdw15
    },
};
