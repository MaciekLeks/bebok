// TODO: is that the right place for this struct?
pub const DataPointer = packed union {
    prp: packed struct(u128) {
        prp1: u64,
        prp2: u64 = 0,
    },
    sgl: packed struct(u128) {
        sgl1: u128,
    },
};

pub const SQEntry = u512;

pub const CQEntry = packed struct(u128) {
    const StatusField = packed struct(u15) {
        // Staus Code
        sc: u8 = 0, //0-7
        // Status Code Type
        sct: u3 = 0, //8-10
        // Command Retry Delay
        crd: u2 = 0, //11-12
        // More
        m: u1 = 0, //13
        // Do Not Retry
        dnr: u1 = 0, //14

    };
    cmd_res0: u32 = 0,
    cmd_res1: u32 = 0,
    sq_header_pos: u16 = 0, //it's called pointer but it's not a pointer it's an index in fact
    sq_id: u16 = 0,
    cmd_id: u16 = 0,
    phase: u1 = 0,
    status: StatusField = .{},
};

pub fn Queue(EntryType: type) type {
    return switch (EntryType) {
        CQEntry => struct {
            entries: []volatile EntryType = undefined,
            head_pos: u32 = 0,
            head_dbl: *volatile u32 = undefined,
            tail_pos: u32 = 0,
            tail_dbl: *volatile u32 = undefined,
            expected_phase: u1 = 1,
        },
        SQEntry => struct {
            entries: []volatile EntryType = undefined,
            head_pos: u32 = 0,
            head_dbl: *volatile u32 = undefined,
            tail_pos: u32 = 0,
            tail_dbl: *volatile u32 = undefined,
        },
        else => unreachable,
    };
}

pub fn GenNCDw0(OpcodeType: type) type {
    return packed struct(u32) {
        opc: OpcodeType,
        fuse: u2 = 0, //0 for nromal operation
        rsvd: u4 = 0,
        psdt: u2 = 0, //0 for PRP tranfer
        cid: u16,
    };
}

pub const NsId = u32;
