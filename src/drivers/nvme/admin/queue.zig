const cmnd = @import("command.zig");
const com = @import("../commons.zig");

pub const IoQueueCommand = packed union {
    create_completion_queue: packed struct(u512) {
        cdw0: cmnd.AdminCDw0, //cdw0
        ignrd_a: u32 = 0, // nsid
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, // cdw4,cdw5
        dptr: com.DataPointer, //cdw6, cdw7, cdw8, cdw9
        qid: u16, //cdw10 - Queue Identifier
        qsize: u16, //cdw10 - Queue Size
        pc: bool, //cdw11 - Physically Contiguous
        ien: bool, //cdw11 - Interrupt Enable
        rsrvd_a: u14 = 0, // cdw11
        iv: u16, //cdw11- Interrupt Vector
        ignrd_f: u32 = 0, //cdw12
        ignrd_g: u32 = 0, //cdw13
        ignrd_h: u32 = 0, //cdw14
        ignrd_i: u32 = 0, //cdw15
    },
    delete_queue: packed struct(u512) {
        cdw0: cmnd.AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //nsid in cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //mptr
        ignrd_f: u128 = 0, //prp1, prp2
        qid: u16, //Queue Identifier
        rsrvd: u16 = 0, //cdw10
        ignrd_h: u32 = 0, //cdw11
        ignrd_i: u32 = 0, //cdw12
        ignrd_j: u32 = 0, //cdw13
        ignrd_k: u32 = 0, //cdw14
        ignrd_l: u32 = 0, //cdw15
    },
    create_submission_queue: packed struct(u512) {
        cdw0: cmnd.AdminCDw0, //cdw0
        ignrd_a: u32 = 0, //nsid - cdw1
        ignrd_b: u32 = 0, //cdw2
        ignrd_c: u32 = 0, //cdw3
        ignrd_e: u64 = 0, //mptr - cdw4,cwd5
        dptr: com.DataPointer, //prp1, prp2 - cdw6, cdw7, cdw8, cdw9
        qid: u16, //cdw10 - Queue Identifier
        qsize: u16, //cdw10 - Queue Size
        // cqid: u16, //cdw11 - Completion Queue Identifier
        pc: bool, //cdw11 - Physically Contiguous
        qprio: enum(u2) {
            urgent = 0b00,
            high = 0b01,
            medium = 0b10,
            low = 0b11,
        }, //cdw11 - Queue Priority
        rsrvd_a: u13 = 0, //cdw11
        cqid: u16, //cdw11 - Completion Queue Identifier
        nvmsetid: u16, //cdw12 - NVM Set Identifier
        rsrvd_b: u16 = 0, //cdw12
        ignrd_f: u32 = 0, //cdw13
        ignrd_h: u32 = 0, //cdw14
        ignrd_i: u32 = 0, //cdw15
    },
};
