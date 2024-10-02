const std = @import("std");

const log = std.log.scoped(.drivers_nvme);

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
